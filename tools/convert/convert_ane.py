"""bge-m3 の本体を Apple Neural Engine（ANE）向けに Core ML へ変換する（開発用）。

Apple の「Deploying Transformers on the Apple Neural Engine」（apple/ml-ane-transformers）の書き方に合わせる。
  - nn.Linear を 1x1 の nn.Conv2d に置き換え、テンソルは (B, C, 1, S) で通す
  - 注意は頭ごとに分けて einsum と softmax（split_softmax）
  - 形は固定。長さ S と件数 B の組ごとに関数を作り、1 つの .mlpackage にまとめる（multifunction。重みは共有）
    関数名は "b{B}_s{S}"。可変の形（EnumeratedShapes）は形を計算する演算が CPU に落ち、ANE に載らない
  - 位置埋め込みは右詰めのパディング前提で 2..S+1 の定数（HF の create_position_ids_from_inputs_embeds と同じ）
  M6 / macOS 27 では、効いたのは形の固定。nn.Linear のままでも固定の形なら同じ速さで ANE に載った（README「ANE で動かす」）。
  EnumeratedShapes の 1 モデルにまとめる形も ANE に載るが、読み込みのたびに 7〜8 分のコンパイルが走るので採らない。

入出力: inputs_embeds (B, S, 1024) fp16, attention_mask (B, S) fp16 → embedding (B, 1024) fp32（長さ 1）。
マスクは今の body（int32）と違い fp16。int32 だと型変換（cast）が CPU にしか載らず、頭の数演算が CPU に引きずられる。

  HF_HOME=/Volumes/SSD/hf uv run python convert_ane.py --out /Volumes/SSD/raiden-models-ane \
      [--quant fp16,int8,pal8,pal6] [--batches 1,8] [--seqs 16,32,64,128] [--ln scaled|fused]
"""
import argparse
import json
import os
import shutil
import tempfile

import coremltools as ct
import coremltools.optimize.coreml as cto
import numpy as np
import torch
import torch.nn as nn
from transformers import AutoModel, AutoTokenizer

MODEL = "BAAI/bge-m3"
EPS = 1e-5


def conv(lin):
    c = nn.Conv2d(lin.in_features, lin.out_features, 1)
    c.weight.data = lin.weight.data[:, :, None, None].clone()
    c.bias.data = lin.bias.data.clone()
    return c


class LayerNormANE(nn.Module):
    """チャンネル（dim=1）で正規化する LayerNorm。

    scaled: 残差の値は 24 層の中ほどで 1000 近くになり、fp16 で 2 乗すると溢れる（65504 を超える）。
    1/k に縮めてから分散を取る（LayerNorm は倍率によらないので、eps だけ k² で割る）。
    fused: 縮めずに書き、coremltools の layer_norm への融合に任せる。
    """

    def __init__(self, ln, mode="scaled", k=64.0):
        super().__init__()
        self.weight = nn.Parameter(ln.weight.data.clone())
        self.bias = nn.Parameter(ln.bias.data.clone())
        self.mode = mode
        self.k = k

    def forward(self, x):
        mean = x.mean(dim=1, keepdim=True)
        zm = x - mean
        if self.mode == "scaled":
            z = zm * (1.0 / self.k)
            var = (z * z).mean(dim=1, keepdim=True)
            out = z * torch.rsqrt(var + EPS / (self.k * self.k))
        else:
            var = (zm * zm).mean(dim=1, keepdim=True)
            out = zm * torch.rsqrt(var + EPS)
        return out * self.weight.view(1, -1, 1, 1) + self.bias.view(1, -1, 1, 1)


class Layer(nn.Module):
    def __init__(self, l, heads, ln_mode):
        super().__init__()
        a = l.attention
        self.q, self.k, self.v = conv(a.self.query), conv(a.self.key), conv(a.self.value)
        self.o = conv(a.output.dense)
        self.ln1 = LayerNormANE(a.output.LayerNorm, ln_mode)
        self.ff1 = conv(l.intermediate.dense)
        self.ff2 = conv(l.output.dense)
        self.ln2 = LayerNormANE(l.output.LayerNorm, ln_mode)
        self.heads = heads

    def forward(self, x, bias):
        # x: (B, C, 1, S)  bias: (B, S, 1, 1)（キー側の加算マスク）
        C = x.shape[1]
        d = C // self.heads
        scale = d ** -0.5
        q = self.q(x) * scale
        k = self.k(x)
        v = self.v(x)
        outs = []
        qs = q.split(d, dim=1)                      # (B, d, 1, Sq)
        ks = k.transpose(1, 3).split(d, dim=3)      # (B, Sk, 1, d)
        vs = v.split(d, dim=1)                      # (B, d, 1, Sk)
        for qi, ki, vi in zip(qs, ks, vs):
            w = torch.einsum("bchq,bkhc->bkhq", qi, ki) + bias   # (B, Sk, 1, Sq)
            w = w.softmax(dim=1)
            outs.append(torch.einsum("bkhq,bchk->bchq", w, vi))  # (B, d, 1, Sq)
        h = torch.cat(outs, dim=1)
        x = self.ln1(x + self.o(h))
        f = self.ff2(torch.nn.functional.gelu(self.ff1(x)))
        return self.ln2(x + f)


class BodyANE(nn.Module):
    def __init__(self, m, S, ln_mode="scaled"):
        super().__init__()
        e = m.embeddings
        pad = e.padding_idx
        pos = e.position_embeddings.weight.data[pad + 1: pad + 1 + S]      # (S, C)
        tt = e.token_type_embeddings.weight.data[0]                       # (C,)
        self.register_buffer("posb", (pos + tt[None, :]).T[None, :, None, :].clone())  # (1, C, 1, S)
        self.ln0 = LayerNormANE(e.LayerNorm, ln_mode)
        heads = m.config.num_attention_heads
        self.layers = nn.ModuleList([Layer(l, heads, ln_mode) for l in m.encoder.layer])

    def forward(self, inputs_embeds, attention_mask):
        x = inputs_embeds.permute(0, 2, 1).unsqueeze(2)                    # (B, C, 1, S)
        x = self.ln0(x + self.posb)
        bias = ((1.0 - attention_mask.to(x.dtype)) * -1e4)[:, :, None, None]  # (B, S, 1, 1)
        for l in self.layers:
            x = l(x, bias)
        cls = x[:, :, 0, 0]
        return cls / torch.sqrt((cls * cls).sum(dim=-1, keepdim=True))


def quantize(m, q):
    if q == "fp16":
        return m
    if q == "int8":
        return cto.linear_quantize_weights(m, cto.OptimizationConfig(global_config=cto.OpLinearQuantizerConfig(
            mode="linear_symmetric", dtype="int8", granularity="per_channel", weight_threshold=2048)))
    if q.startswith("pal"):
        nbits = int(q[3:].split("g")[0])
        gs = int(q.split("g")[1]) if "g" in q else 0
        cfg = cto.OpPalettizerConfig(nbits=nbits, mode="kmeans", weight_threshold=2048,
                                     granularity="per_grouped_channel" if gs else "per_tensor", group_size=gs or 32)
        return cto.palettize_weights(m, cto.OptimizationConfig(global_config=cfg))
    if q == "int4":
        return cto.linear_quantize_weights(m, cto.OptimizationConfig(global_config=cto.OpLinearQuantizerConfig(
            mode="linear_symmetric", dtype="int4", granularity="per_block", block_size=32, weight_threshold=2048)))
    raise SystemExit(f"unknown quant {q}")


def convert_one(model, B, S, ln_mode, C):
    body = BodyANE(model, S, ln_mode).eval()
    ex = (torch.randn(B, S, C), torch.ones(B, S))
    with torch.no_grad():
        traced = torch.jit.trace(body, ex, strict=False)
    se, sm = (B, S, C), (B, S)
    return ct.convert(
        traced,
        inputs=[ct.TensorType(name="inputs_embeds", shape=se, dtype=np.float16),
                ct.TensorType(name="attention_mask", shape=sm, dtype=np.float16)],
        outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS15,
        convert_to="mlprogram",
        # 変換の後に読み込むと ANE 向けのコンパイルが走り、件数 16 以上・長さ 128 では 1 つ 10 分を超える
        skip_model_load=True,
    )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--quant", default="fp16")
    ap.add_argument("--batches", default="1,8")
    ap.add_argument("--seqs", default="16,32,64,128")
    ap.add_argument("--ln", default="scaled")
    ap.add_argument("--name", default="body_ane")
    ap.add_argument("--check", action="store_true", help="PyTorch の元の模型と cos を比べて終わる（変換しない）")
    args = ap.parse_args()
    batches = [int(b) for b in args.batches.split(",")]
    seqs = [int(s) for s in args.seqs.split(",")]
    os.makedirs(args.out, exist_ok=True)

    tok = AutoTokenizer.from_pretrained(MODEL)
    model = AutoModel.from_pretrained(MODEL, torch_dtype=torch.float32, attn_implementation="eager").eval()
    C = model.config.hidden_size

    if args.check:
        # 書き直した模型（fp32）が HF の模型と同じ答えを出すか
        texts = ["PDFを見るやつ", "黒い画面でコマンド打つやつ", "プレビュー Preview"]
        enc = tok(texts, padding="max_length", max_length=32, return_tensors="pt")
        with torch.no_grad():
            ref = model(**enc).last_hidden_state[:, 0]
            ref = ref / ref.norm(dim=-1, keepdim=True)
            emb = model.embeddings.word_embeddings(enc["input_ids"])
            mine = BodyANE(model, 32, args.ln).eval()(emb, enc["attention_mask"].int())
        print("cos(HF, ANE 版 fp32):", (ref * mine).sum(-1).tolist())
        return

    tmp = tempfile.mkdtemp(dir=args.out)
    try:
        for q in args.quant.split(","):
            desc = ct.utils.MultiFunctionDescriptor()
            parts = []
            for B in batches:
                for S in seqs:
                    m = quantize(convert_one(model, B, S, args.ln, C), q)
                    p = os.path.join(tmp, f"{q}_b{B}_s{S}.mlpackage")
                    m.save(p)
                    parts.append(p)
                    desc.add_function(p, src_function_name="main", target_function_name=f"b{B}_s{S}")
                    print("converted", q, B, S, flush=True)
            desc.default_function_name = f"b1_s{seqs[min(1, len(seqs) - 1)]}"
            path = os.path.join(args.out, f"{args.name}_{q}.mlpackage")
            if os.path.exists(path):
                shutil.rmtree(path)
            ct.utils.save_multifunction(desc, path)
            for p in parts:
                shutil.rmtree(p)
            print("saved", path, flush=True)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    meta = {"vocab": int(model.config.vocab_size), "dim": C, "shapes": seqs, "batches": batches, "model": MODEL,
            "functions": [f"b{B}_s{S}" for B in batches for S in seqs], "units": "ane"}
    json.dump(meta, open(os.path.join(args.out, "meta.json"), "w"))
    print("done")


if __name__ == "__main__":
    main()
