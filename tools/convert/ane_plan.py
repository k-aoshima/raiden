"""Core ML の MLComputePlan で、どの演算がどの装置（CPU / GPU / ANE）に載るかを数える（開発用）。

  uv run python ane_plan.py <model.mlpackage|.mlmodelc> [--units ane|all|cpu] [--function main] [--list]

演算の数と、推定の重さ（estimated cost）で重みづけした割合を出す。ANE に載らなかった演算は名前ごとに数える。
.mlpackage は一時フォルダにコンパイルしてから見る。
"""
import argparse
import collections
import os
import shutil
import tempfile

import coremltools as ct
from coremltools.models.compute_plan import MLComputePlan
from coremltools.models.compute_device import MLCPUComputeDevice, MLGPUComputeDevice, MLNeuralEngineComputeDevice

UNITS = {"ane": ct.ComputeUnit.CPU_AND_NE, "all": ct.ComputeUnit.ALL, "cpu": ct.ComputeUnit.CPU_ONLY,
         "gpu": ct.ComputeUnit.CPU_AND_GPU}
SKIP = {"const", "constexpr_lut_to_dense", "constexpr_affine_dequantize", "constexpr_blockwise_shift_scale"}


def dev_name(d):
    if isinstance(d, MLNeuralEngineComputeDevice):
        return "ANE"
    if isinstance(d, MLGPUComputeDevice):
        return "GPU"
    if isinstance(d, MLCPUComputeDevice):
        return "CPU"
    return "?"


def compiled_path(path):
    if path.endswith(".mlmodelc"):
        return path, None
    tmp = tempfile.mkdtemp()
    out = ct.utils.compile_model(path, os.path.join(tmp, "m.mlmodelc"))
    return str(out), tmp


def plan(path, units="ane", function=None, list_ops=False):
    cpath, tmp = compiled_path(path)
    try:
        p = MLComputePlan.load_from_path(cpath, compute_units=UNITS[units])
        prog = p.model_structure.program
        res = {}
        for fname, fn in prog.functions.items():
            if function and fname != function:
                continue
            count = collections.Counter()
            cost = collections.Counter()
            off = collections.Counter()
            ops = []

            def walk(block):
                for op in block.operations:
                    for b in op.blocks:
                        walk(b)
                    if "constexpr" in op.operator_name or op.operator_name in SKIP:
                        continue
                    u = p.get_compute_device_usage_for_mlprogram_operation(op)
                    c = p.get_estimated_cost_for_mlprogram_operation(op)
                    d = dev_name(u.preferred_compute_device) if u else "none"
                    w = c.weight if c else 0.0
                    count[d] += 1
                    cost[d] += w
                    if d != "ANE":
                        off[op.operator_name] += 1
                    ops.append((op.operator_name, d, w, [dev_name(x) for x in (u.supported_compute_devices if u else [])]))

            walk(fn.block)
            n = sum(count.values())
            wsum = sum(cost.values()) or 1.0
            res[fname] = dict(ops=n, count=dict(count), ane_ops=count["ANE"] / max(n, 1),
                              ane_cost=cost["ANE"] / wsum, off=dict(off))
            print(f"[{fname}] 演算 {n}  ANE {count['ANE']}（{100*count['ANE']/max(n,1):.1f}%）  "
                  f"推定の重さで ANE {100*cost['ANE']/wsum:.1f}%  内訳 {dict(count)}")
            if off:
                print("   ANE 以外:", dict(off.most_common()))
            if list_ops:
                for o in ops:
                    print("   ", o)
        return res
    finally:
        if tmp:
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("model")
    ap.add_argument("--units", default="ane")
    ap.add_argument("--function")
    ap.add_argument("--list", action="store_true")
    a = ap.parse_args()
    plan(a.model, a.units, a.function, a.list)
