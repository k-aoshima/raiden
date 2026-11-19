"""bge-m3（XLM-RoBERTa）の Unigram 語彙を、Swift が mmap して二分探索できる vocab.bin に書き出す。
あわせて、Swift のトークナイザの答え合わせ用に、渡した文の正解トークン列を作る。

  uv run python export_tokenizer.py --out /Volumes/SSD/raiden-models
  uv run python export_tokenizer.py --check texts.txt ids.json   # 1 行 1 文 → 正解の id 列

vocab.bin（リトルエンディアン）:
  "RVOC" u32 件数 n, u32 unk_id, f32 最小スコア,
  u32 offset[n+1]（文字列の位置）, i32 id[n], f32 score[n], 文字列（UTF-8 のバイト順に並べたもの）
"""
import argparse
import json
import os
import struct

TOKJSON = os.path.expandvars(
    "$HF_HOME/hub/models--BAAI--bge-m3/snapshots/5617a9f61b028005a4858fdac845db406aefb181/tokenizer.json")


def export(out):
    t = json.load(open(TOKJSON))
    vocab = t["model"]["vocab"]
    unk = t["model"]["unk_id"]
    special = {a["content"] for a in t["added_tokens"]}
    entries = [(p.encode("utf-8"), i, s) for i, (p, s) in enumerate(vocab) if p not in special]
    entries.sort(key=lambda e: e[0])
    min_score = min(s for _, _, s in entries)
    blob = bytearray()
    offs = []
    for b, _, _ in entries:
        offs.append(len(blob))
        blob += b
    offs.append(len(blob))
    with open(os.path.join(out, "vocab.bin"), "wb") as f:
        f.write(b"RVOC" + struct.pack("<IIf", len(entries), unk, min_score))
        f.write(struct.pack(f"<{len(offs)}I", *offs))
        f.write(struct.pack(f"<{len(entries)}i", *[i for _, i, _ in entries]))
        f.write(struct.pack(f"<{len(entries)}f", *[s for _, _, s in entries]))
        f.write(blob)
    print("vocab.bin", len(entries), "pieces", os.path.getsize(os.path.join(out, "vocab.bin")), "bytes")


def check(texts_path, out_path):
    from transformers import AutoTokenizer
    tok = AutoTokenizer.from_pretrained("BAAI/bge-m3")
    texts = [l.rstrip("\n") for l in open(texts_path, encoding="utf-8")]
    json.dump([tok(x)["input_ids"] for x in texts], open(out_path, "w"))
    print("wrote", len(texts))


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--out")
    ap.add_argument("--check", nargs=2)
    a = ap.parse_args()
    if a.check:
        check(*a.check)
    else:
        export(a.out)
