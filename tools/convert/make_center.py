"""2 値のベクトルの中心（center.bin、1024 次元の float32）を作る（開発用）。

bge-m3 のベクトルは次元ごとに平均が 0 から大きくずれている（平均の絶対値 0.017、値そのものの絶対値 0.024）。
そのまま符号で 2 値にすると、ほとんどの文書で同じビットが立って区別がつきにくい。平均を引いてから符号を取ると、
入力の上位 10 件が float32 の時と重なる割合が 0.51 → 0.61 に上がった（手元のファイル 1,066 件・例 16 個）。

アプリは center.bin を BinVec.center として読み、文書は sign(v - center)、近さは
  cos ≈ a × (q・sign(v - center)) / 32 + (q・center) + b
で付ける（q・center は入力ごとに一定なので並び順には効かず、点数の目盛りを cos に合わせるだけ）。
center.bin を変えると、保存済みの 2 値のベクトルは全部作り直しになる。

  uv run python make_center.py --db <float32 のベクトルが入った raiden.sqlite のコピー> --out /Volumes/SSD/raiden-models/center.bin
"""
import argparse
import sqlite3

import numpy as np


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    db = sqlite3.connect(args.db)
    rows = db.execute("SELECT vector FROM nodes WHERE kind IN ('file','folder','app') AND length(vector) = 4096").fetchall()
    X = np.stack([np.frombuffer(r[0], dtype=np.float32) for r in rows]).astype(np.float64)
    mu = X.mean(0).astype(np.float32)
    mu.tofile(args.out)
    print(f"{len(rows)} 件の平均 → {args.out}（平均の絶対値 {np.abs(mu).mean():.4f}）")


if __name__ == "__main__":
    main()
