"""
仓库事实核验脚本 —— 核对"仓库里写了、但从未被验证过"的那些声明。

设计原则
--------
1) **独立实现**：不复用被验代码的函数（例如类别前缀匹配、指标汇总都自己写一遍），
   避免"用被测代码验证被测代码"。
2) **只读**：不改动数据集与产物；唯一例外是 --run-prepare 时调用 prepare_dataset.py
   生成 dataset_yolo/（该目录已被 .gitignore 排除，属可再生中间物）。
3) 每条结论都打印 OK / FAIL，可作 CI 或人工复核用。

覆盖范围
--------
A. NEU-DET 数据集：图片/标注数量、每类图片数、每类标注框数、图文配对、XML 合法性
B. 训练侧硬编码常量 CLASS_BOX_COUNTS 是否与数据集实测一致
C. results.csv ↔ train_summary.json：最佳轮次与四项指标是否自洽
D. best.onnx ↔ export_meta.json：opset 版本、输入/输出形状（手写 protobuf 解析，不依赖 onnx 包）
E. requirements.txt 是否覆盖代码实际 import 的第三方库

用法
----
    python training/tools/verify_claims.py
    python training/tools/verify_claims.py --run-prepare   # 额外跑一次划分并核对 1440/360
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TRAINING = ROOT / "training"
SRC = TRAINING / "src"
DATASET = TRAINING / "dataset" / "NEU-DET"
EXPORT = TRAINING / "export"
RESULTS = TRAINING / "results"

CLASSES = ["crazing", "inclusion", "patches", "pitted_surface", "rolled-in_scale", "scratches"]

failures: list[str] = []


def check(label: str, ok: bool, detail: str = "") -> bool:
    mark = "OK  " if ok else "FAIL"
    print(f"[{mark}] {label}" + (f"   {detail}" if detail else ""))
    if not ok:
        failures.append(label)
    return ok


# ─────────────────────────── A. 数据集 ───────────────────────────

def class_of(stem: str) -> str | None:
    """独立实现：从文件名判断类别（从长到短匹配前缀，处理 rolled-in_scale 的连字符）"""
    for name in sorted(CLASSES, key=len, reverse=True):
        if stem == name or stem.startswith(name + "_"):
            return name
    return None


def parse_boxes(xml_path: Path) -> tuple[str, list[tuple[str, float, float, float, float]]]:
    root = ET.parse(xml_path).getroot()
    size = root.find("size")
    if size is None:
        raise ValueError("缺少 <size>")
    w = int(size.findtext("width"))
    h = int(size.findtext("height"))
    boxes = []
    for obj in root.findall("object"):
        name = (obj.findtext("name") or "").strip()
        bb = obj.find("bndbox")
        x1 = float(bb.findtext("xmin")); y1 = float(bb.findtext("ymin"))
        x2 = float(bb.findtext("xmax")); y2 = float(bb.findtext("ymax"))
        boxes.append((name, x1, y1, x2, y2))
    return f"{w}x{h}", boxes


def verify_dataset() -> tuple[Counter, Counter, dict[str, str]]:
    print("\n=== A. NEU-DET 数据集 ===")
    imgs = sorted((DATASET / "IMAGES").glob("*.jpg"))
    xmls = sorted((DATASET / "ANNOTATIONS").glob("*.xml"))
    check("图片数量 == 1800", len(imgs) == 1800, f"实测 {len(imgs)}")
    check("标注数量 == 1800", len(xmls) == 1800, f"实测 {len(xmls)}")

    img_stems = {p.stem for p in imgs}
    xml_stems = {p.stem for p in xmls}
    check("图文一一配对", img_stems == xml_stems,
          f"仅在图片: {len(img_stems - xml_stems)}，仅在标注: {len(xml_stems - img_stems)}")

    per_class_img: Counter = Counter()
    unknown: list[str] = []
    for stem in img_stems:
        c = class_of(stem)
        if c is None:
            unknown.append(stem)
        else:
            per_class_img[c] += 1
    check("每张图都能判定类别（无未知前缀）", not unknown, f"未知 {unknown[:5]}")

    per_class_box: Counter = Counter()
    bad_xml: list[str] = []
    sizes: Counter = Counter()
    for xp in xmls:
        try:
            size, boxes = parse_boxes(xp)
            sizes[size] += 1
            if not boxes:
                bad_xml.append(f"{xp.name}: 无 object")
            for name, x1, y1, x2, y2 in boxes:
                if name not in CLASSES:
                    bad_xml.append(f"{xp.name}: 未知类别 {name}")
                    continue
                per_class_box[name] += 1
                if not (0 <= x1 < x2 and 0 <= y1 < y2):
                    bad_xml.append(f"{xp.name}: 坐标非法 {x1},{y1},{x2},{y2}")
        except Exception as exc:  # noqa: BLE001
            bad_xml.append(f"{xp.name}: {exc}")
    check("每个 XML 均可解析且坐标/类别合法", not bad_xml, f"异常 {bad_xml[:3]}")

    print(f"       图片尺寸分布: {dict(sizes)}")

    for c in CLASSES:
        check(f"类别 {c} 图片数 == 300", per_class_img[c] == 300, f"实测 {per_class_img[c]}")

    expected_boxes = {
        "crazing": 689, "inclusion": 1011, "patches": 881,
        "pitted_surface": 432, "rolled-in_scale": 628, "scratches": 548,
    }
    for c in CLASSES:
        ok = per_class_box[c] == expected_boxes[c]
        check(f"类别 {c} 标注框数 == {expected_boxes[c]}", ok, f"实测 {per_class_box[c]}")
    check("标注框总数 == 4189", sum(per_class_box.values()) == 4189, f"实测 {sum(per_class_box.values())}")
    return per_class_img, per_class_box, dict(sizes)


# ─────────────────── B. train.py 里的硬编码常量 ───────────────────

def verify_hardcoded_counts(per_class_box: Counter) -> None:
    print("\n=== B. train.py 的 CLASS_BOX_COUNTS 是否与数据集一致 ===")
    text = (SRC / "train.py").read_text(encoding="utf-8")
    block = re.search(r"CLASS_BOX_COUNTS\s*=\s*\{(.*?)\}", text, re.S)
    if not check("能在 train.py 里找到 CLASS_BOX_COUNTS", block is not None):
        return
    hard: dict[str, int] = {}
    for line in block.group(1).splitlines():
        m = re.search(r'"([\w\-]+)"\s*:\s*(\d+)', line)
        if m:
            hard[m.group(1)] = int(m.group(2))
    for c in CLASSES:
        check(f"{c}: train.py={hard.get(c)} vs 数据集={per_class_box[c]}",
              hard.get(c) == per_class_box[c])


# ─────────────────── C. results.csv ↔ train_summary.json ───────────────────

def verify_results() -> None:
    print("\n=== C. results.csv 与 train_summary.json 是否自洽 ===")
    csv_path = RESULTS / "results.csv"
    summary_path = RESULTS / "train_summary.json"
    if not check("两个文件都存在", csv_path.exists() and summary_path.exists()):
        return

    rows = list(csv.DictReader(csv_path.read_text(encoding="utf-8").splitlines()))
    summary = json.loads(summary_path.read_text(encoding="utf-8"))
    check("results.csv 行数 == 150（训练轮数）", len(rows) == 150, f"实测 {len(rows)}")

    key = "metrics/mAP50(B)"
    best = max(rows, key=lambda r: float(r[key]))
    best_epoch = int(float(best["epoch"]))
    check(f"csv 里 mAP50 最大的轮次 == summary.best_epoch({summary['best_epoch']})",
          best_epoch == summary["best_epoch"], f"csv 最佳轮次 {best_epoch}")

    for csv_key, sum_key, tol in [
        ("metrics/mAP50(B)", "mAP50", 1e-4),
        ("metrics/mAP50-95(B)", "mAP50_95", 1e-4),
        ("metrics/precision(B)", "precision", 1e-4),
        ("metrics/recall(B)", "recall", 1e-4),
    ]:
        a = float(best[csv_key]); b = float(summary[sum_key])
        check(f"{sum_key}: csv={a:.5f} vs summary={b:.5f}", abs(a - b) <= tol)

    ev = RESULTS / "eval_result.json"
    if ev.exists():
        e = json.loads(ev.read_text(encoding="utf-8"))
        print(f"       附：eval_result.json 的总体 mAP50 = {e['overall']['mAP50']:.4f}"
              f"（与 train_summary 的 {summary['mAP50']:.4f} 不同属正常："
              f"前者是独立评估脚本复测，后者取自训练过程的最优轮）")
        print(f"       附：eval_result.json 记录的权重路径 = {e['weights']}")


# ─────────────────── D. ONNX 元数据（手写 protobuf 解析）───────────────────

def read_varint(buf: bytes, i: int) -> tuple[int, int]:
    val = 0
    shift = 0
    while True:
        b = buf[i]
        i += 1
        val |= (b & 0x7F) << shift
        if not (b & 0x80):
            return val, i
        shift += 7


def iter_fields(buf: bytes):
    i = 0
    while i < len(buf):
        key, i = read_varint(buf, i)
        fn, wt = key >> 3, key & 7
        if wt == 0:
            v, i = read_varint(buf, i)
            yield fn, wt, v
        elif wt == 2:
            ln, i = read_varint(buf, i)
            yield fn, wt, buf[i:i + ln]
            i += ln
        elif wt == 5:
            yield fn, wt, buf[i:i + 4]
            i += 4
        elif wt == 1:
            yield fn, wt, buf[i:i + 8]
            i += 8
        else:
            raise ValueError(f"不支持的 wire type {wt}")


def _fields_dict(buf: bytes) -> dict[int, list]:
    out: dict[int, list] = defaultdict(list)
    for fn, wt, v in iter_fields(buf):
        out[fn].append((wt, v))
    return out


def tensor_shape(type_proto: bytes) -> list:
    """TypeProto -> Tensor -> shape -> dims"""
    tf = _fields_dict(type_proto)
    if 1 not in tf:  # tensor_type
        return []
    tensor = _fields_dict(tf[1][0][1])
    if 2 not in tensor:  # shape
        return []
    shape = _fields_dict(tensor[2][0][1])
    dims = []
    for _, dim_bytes in shape.get(1, []):  # Dimension
        d = _fields_dict(dim_bytes)
        if 1 in d:      # dim_value
            dims.append(d[1][0][1])
        elif 2 in d:    # dim_param（动态轴）
            dims.append(d[2][0][1].decode("utf-8", "replace"))
        else:
            dims.append(None)
    return dims


def verify_onnx() -> None:
    print("\n=== D. best.onnx 的元数据 vs export_meta.json ===")
    onnx_path = EXPORT / "neu_det_yolov8n.onnx"
    meta_path = EXPORT / "export_meta.json"
    if not check("两个文件都存在", onnx_path.exists() and meta_path.exists()):
        return
    meta = json.loads(meta_path.read_text(encoding="utf-8"))
    raw = onnx_path.read_bytes()
    check("文件大小与 meta.size_mb 一致（±0.05 MB）",
          abs(len(raw) / 1024 ** 2 - meta["size_mb"]) < 0.05,
          f"实测 {len(raw)/1024**2:.3f} MB vs meta {meta['size_mb']}")

    top = _fields_dict(raw)
    # opset_import（field 8，repeated OperatorSetIdProto：1=domain, 2=version）
    opsets = []
    for _, os_bytes in top.get(8, []):
        d = _fields_dict(os_bytes)
        ver = d[2][0][1] if 2 in d else None
        dom = d[1][0][1].decode() if 1 in d else ""
        opsets.append((dom, ver))
    check(f"opset == meta.opset({meta['opset']})", any(v == meta["opset"] for _, v in opsets),
          f"实测 {opsets}")

    # graph（field 7）
    graph = _fields_dict(top[7][0][1])
    ins = []
    for _, vi in graph.get(11, []):
        d = _fields_dict(vi)
        name = d[1][0][1].decode()
        ins.append((name, tensor_shape(d[2][0][1])))
    outs = []
    for _, vi in graph.get(12, []):
        d = _fields_dict(vi)
        name = d[1][0][1].decode()
        outs.append((name, tensor_shape(d[2][0][1])))
    check(f"输入名 == meta.input_name({meta['input_name']})",
          any(n == meta["input_name"] for n, _ in ins), f"实测 {ins}")
    check("输入形状 == [1,3,320,320]（与训练 imgsz 一致）",
          any(s == [1, 3, 320, 320] for _, s in ins), f"实测 {ins}")
    check("输出形状 == [1,10,2100]（4 框参数 + 6 类，2100 候选）",
          any(s == [1, 10, 2100] for _, s in outs), f"实测 {outs}")
    check("无动态轴（meta.dynamic == false）",
          not meta["dynamic"] and all(isinstance(x, int) for _, s in outs for x in s))
    check("meta.verified == true 且 max_abs_diff 小于 1e-3",
          bool(meta["verified"]) and meta["max_abs_diff"] < 1e-3,
          f"max_abs_diff={meta['max_abs_diff']}")


# ─────────────────── E. requirements.txt 覆盖检查 ───────────────────

def verify_requirements() -> None:
    print("\n=== E. requirements.txt 是否覆盖代码里 import 的第三方库 ===")
    req = TRAINING / "requirements.txt"
    if not check("requirements.txt 存在", req.exists()):
        return
    lines = [l.strip() for l in req.read_text(encoding="utf-8").splitlines()
             if l.strip() and not l.strip().startswith("#")]
    declared = {re.split(r"[=<>!\[]", l)[0].strip().lower() for l in lines}
    print(f"       声明了 {len(declared)} 个包: {sorted(declared)}")

    imported: set[str] = set()
    for py in SRC.glob("*.py"):
        for m in re.finditer(r"^\s*(?:import|from)\s+([A-Za-z_][\w]*)", py.read_text(encoding="utf-8"), re.M):
            imported.add(m.group(1).lower())
    stdlib = {"argparse", "csv", "json", "math", "os", "pathlib", "random", "re", "shutil",
              "subprocess", "sys", "time", "typing", "xml", "collections", "dataclasses",
              "functools", "itertools", "glob", "warnings", "__future__"}
    third = sorted(imported - stdlib)
    print(f"       代码里 import 的第三方库: {third}")

    # torch 是**有意**不写进 requirements.txt 的：它必须用 cu128 专用索引单独安装
    # （见 training/README.md 的「RTX 50 系必须用 CUDA 12.8 版 PyTorch」一节）。
    # 所以这里改为核对"这条声明是否有文档依据"，而不是简单判缺失。
    readme = (TRAINING / "README.md").read_text(encoding="utf-8")
    documented = ("cu128" in readme) and ("pip install torch torchvision" in readme)
    check("torch 未列入 requirements.txt，但 README 有单独安装说明", documented,
          "README 含 cu128 专用索引的安装命令" if documented else "README 未找到该说明")

    missing = [m for m in third if m not in declared and m not in ("torch", "torchvision")]
    check("其余第三方依赖均已声明", not missing, f"缺失 {missing}")


# ─────────────────── G. 类别顺序跨文件一致性 ───────────────────

def verify_class_order() -> None:
    """四处类别顺序必须完全一致：数据准备 / 训练 / 端侧类别名 / 端侧类型定义。

    顺序错一位就是「框的位置对、类别名错」，而且**不会报任何错** —— 必须机器核对。
    """
    print("\n=== G. 类别顺序跨文件一致性 ===")
    train_py = (SRC / "train.py").read_text(encoding="utf-8")
    prep_py = (SRC / "prepare_dataset.py").read_text(encoding="utf-8")
    det_ets = (ROOT / "app/entry/src/main/ets/model/MindSporeLiteDetector.ets").read_text(encoding="utf-8")
    type_ets = (ROOT / "app/entry/src/main/ets/model/DefectType.ets").read_text(encoding="utf-8")

    def grab(pattern: str, text: str) -> list[str]:
        m = re.search(pattern, text, re.S)
        if not m:
            return []
        return re.findall(r"['\"]([^'\"]+)['\"]", m.group(1))

    prep_order = grab(r"CLASSES:\s*list\[str\]\s*=\s*\[(.*?)\]", prep_py)
    train_order = grab(r"CLASSES\s*=\s*\[(.*?)\]", train_py)
    npu_order = grab(r"const CLASS_NAMES: string\[\] = \[(.*?)\]", det_ets)
    npu_cn = grab(r"const CLASS_NAMES_CN: string\[\] = \[(.*?)\]", det_ets)
    meta_en = re.findall(r"'([\w\-]+)':\s*\{\s*cn:", type_ets)
    meta_cn = re.findall(r"cn:\s*'([^']+)'", type_ets)

    for name, order in [("prepare_dataset.py CLASSES", prep_order),
                        ("train.py CLASSES", train_order),
                        ("MindSporeLiteDetector.CLASS_NAMES", npu_order),
                        ("DefectType.DEFECT_META 键", meta_en)]:
        check(f"{name} 与端侧基准顺序一致", order == CLASSES, f"实测 {order}")

    check("端侧英文名与中文名各 6 项", len(npu_cn) == 6 and len(meta_cn) == 6,
          f"CN={npu_cn} META_CN={meta_cn}")
    check("两处中文名顺序一致（DefectType vs Detector）", meta_cn == npu_cn,
          f"DefectType={meta_cn} / Detector={npu_cn}")


# ─────────────────── F. 可选：跑一次数据划分 ───────────────────

def run_prepare() -> None:
    print("\n=== F. 实跑 prepare_dataset.py，核对 80/20 分层划分 ===")
    script = SRC / "prepare_dataset.py"
    proc = subprocess.run([sys.executable, str(script)], capture_output=True, text=True,
                          encoding="utf-8", errors="replace")
    if not check("脚本退出码为 0", proc.returncode == 0, f"stderr: {proc.stderr[-400:]}"):
        return
    out = TRAINING / "dataset_yolo"
    for split, expect in (("train", 1440), ("val", 360)):
        imgs = list((out / "images" / split).glob("*.jpg"))
        lbls = list((out / "labels" / split).glob("*.txt"))
        check(f"{split} 图片数 == {expect}", len(imgs) == expect, f"实测 {len(imgs)}")
        check(f"{split} 标签数 == 图片数", len(lbls) == len(imgs), f"标签 {len(lbls)}")
        per = Counter(class_of(p.stem) for p in imgs)
        for c in CLASSES:
            want = 240 if split == "train" else 60
            check(f"  {split} 的 {c} == {want}", per[c] == want, f"实测 {per[c]}")
    yaml_path = out / "data.yaml"
    if yaml_path.exists():
        text = yaml_path.read_text(encoding="utf-8")
        check("data.yaml 里 nc=6 且列出 6 类", "nc: 6" in text and all(c in text for c in CLASSES))
        print("       data.yaml 内容摘要:\n" + "\n".join("         " + l for l in text.splitlines()[:12]))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--run-prepare", action="store_true", help="额外实跑 prepare_dataset.py 核对划分")
    args = ap.parse_args()

    print("仓库事实核验（independently implemented checks）")
    print(f"仓库根: {ROOT}")
    _, per_class_box, _ = verify_dataset()
    verify_hardcoded_counts(per_class_box)
    verify_results()
    verify_onnx()
    verify_requirements()
    verify_class_order()
    if args.run_prepare:
        run_prepare()

    print("\n" + "=" * 60)
    if failures:
        print(f"结论：{len(failures)} 项未通过")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("结论：全部核对项通过")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
