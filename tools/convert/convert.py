"""BAAI/bge-m3 を Core ML に変換する（開発用。アプリの実行には使わない）。

メモリを抑えるため、モデルを 2 つに分ける。
  - 単語の埋め込み表（250002 x 1024）: Core ML に入れず、int8＋行ごとの尺度で embed_int8.bin に書き出す。
    アプリは mmap して使う行だけ読むので、表の大部分はメモリ（footprint）に乗らない。
  - 本体（位置埋め込み〜24 層〜CLS）: Core ML。重みを fp16 / int8 / 4bit などに量子化して比べる。

  HF_HOME=/Volumes/SSD/hf uv run python convert.py --out /Volumes/SSD/raiden-models [--variants fp16,int8,pal4,int4] [--batches 1,8,16,32]

入力の形は（件数 B, 長さ L, 1024）。B と L は EnumeratedShapes の組（B は --batches、L は SHAPES）。
B > 1 はファイルの説明文をまとめてベクトル化する用（BGEEmbedder.embedBatch）。B = 1 は入力 1 文。
"""
import argparse
import json
import os
import shutil

import coremltools as ct
import coremltools.optimize.coreml as cto
import numpy as np
import torch
from transformers import AutoModel, AutoTokenizer

MODEL = "BAAI/bge-m3"
SHAPES = [16, 32, 64, 128]  # 入力は短い（アプリ説明・入力文）ので最大 128 トークン


class Body(torch.nn.Module):
    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, inputs_embeds, attention_mask):
        # fp16 では HF の (1 - mask) * finfo(float32).min が -inf * 0 = NaN になるので、加算マスクを自前で作る
        ext = (1.0 - attention_mask[:, None, None, :].to(inputs_embeds.dtype)) * -1e4
        self.m.get_extended_attention_mask = lambda *a, **k: ext
        try:
            out = self.m(inputs_embeds=inputs_embeds, attention_mask=attention_mask).last_hidden_state
        finally:
            del self.m.get_extended_attention_mask
        cls = out[:, 0]
        return cls / torch.linalg.norm(cls, dim=-1, keepdim=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--variants", default="fp16,int8,pal4,int4")
    ap.add_argument("--batches", default="1,8,16,32")
    args = ap.parse_args()
    batches = sorted({int(b) for b in args.batches.split(",")} | {1})
    os.makedirs(args.out, exist_ok=True)

    tok = AutoTokenizer.from_pretrained(MODEL)
    model = AutoModel.from_pretrained(MODEL, torch_dtype=torch.float32, attn_implementation="eager").eval()

    # 1) 埋め込み表を int8 で書き出す（行ごとの対称量子化）
    emb = model.embeddings.word_embeddings.weight.detach().numpy().astype(np.float32)
    scale = np.abs(emb).max(axis=1) / 127.0
    scale[scale == 0] = 1.0
    q = np.clip(np.round(emb / scale[:, None]), -127, 127).astype(np.int8)
    q.tofile(os.path.join(args.out, "embed_int8.bin"))
    scale.astype(np.float32).tofile(os.path.join(args.out, "embed_scale.bin"))
    json.dump({"vocab": int(emb.shape[0]), "dim": int(emb.shape[1]), "shapes": SHAPES, "batches": batches, "model": MODEL},
              open(os.path.join(args.out, "meta.json"), "w"))
    # トークナイザ（swift-transformers が読む形）
    tok.save_pretrained(os.path.join(args.out, "tokenizer"))
    print("embed table written", q.shape, flush=True)

    # 2) 本体を変換
    body = Body(model).eval()
    L = 32
    ex = (torch.randn(1, L, emb.shape[1]), torch.ones(1, L, dtype=torch.int32))
    with torch.no_grad():
        traced = torch.jit.trace(body, ex, strict=False)
    shapes_e = ct.EnumeratedShapes(shapes=[(b, s, emb.shape[1]) for b in batches for s in SHAPES], default=(1, 32, emb.shape[1]))
    shapes_m = ct.EnumeratedShapes(shapes=[(b, s) for b in batches for s in SHAPES], default=(1, 32))
    base = ct.convert(
        traced,
        inputs=[ct.TensorType(name="inputs_embeds", shape=shapes_e, dtype=np.float16),
                ct.TensorType(name="attention_mask", shape=shapes_m, dtype=np.int32)],
        outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS15,
        convert_to="mlprogram",
    )
    variants = args.variants.split(",")
    for v in variants:
        if v == "fp16":
            m = base
        elif v == "int8":
            m = cto.linear_quantize_weights(base, cto.OptimizationConfig(
                global_config=cto.OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8",
                                                          granularity="per_channel", weight_threshold=2048)))
        elif v == "pal4":
            m = cto.palettize_weights(base, cto.OptimizationConfig(
                global_config=cto.OpPalettizerConfig(nbits=4, mode="kmeans", granularity="per_grouped_channel",
                                                     group_size=16, weight_threshold=2048)))
        elif v == "int4":
            m = cto.linear_quantize_weights(base, cto.OptimizationConfig(
                global_config=cto.OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int4",
                                                          granularity="per_block", block_size=32,
                                                          weight_threshold=2048)))
        else:
            raise SystemExit(f"unknown variant {v}")
        path = os.path.join(args.out, f"body_{v}.mlpackage")
        if os.path.exists(path):
            shutil.rmtree(path)
        m.save(path)
        print("saved", path, flush=True)

    # 3) 確かめ用：PyTorch の答え（Swift 側と突き合わせる）
    texts = ["PDFを見るやつ", "黒い画面でコマンド打つやつ", "プレビュー Preview"]
    with torch.no_grad():
        enc = tok(texts, padding=True, return_tensors="pt")
        ref = model(**enc).last_hidden_state[:, 0]
        ref = (ref / ref.norm(dim=-1, keepdim=True)).numpy()
    json.dump({"texts": texts, "ids": enc["input_ids"].tolist(), "vec_head": ref[:, :8].tolist(),
               "cos01": float(ref[0] @ ref[1]), "cos02": float(ref[0] @ ref[2])},
              open(os.path.join(args.out, "reference.json"), "w"), ensure_ascii=False)
    print("done")


if __name__ == "__main__":
    main()
