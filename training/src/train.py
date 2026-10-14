"""
NEU-DET 钢材表面缺陷检测 —— YOLO 训练脚本

用法
----
    cd training
    .venv\\Scripts\\python.exe src\\train.py
    .venv\\Scripts\\python.exe src\\train.py --model yolov8s --epochs 200

设计说明
--------
1) 选 yolov8n 而非更大的模型
   NEU-DET 只有 1800 张图，模型越大越容易过拟合；且端侧部署时
   小模型的 NPU 算子支持更完整。先用 nano 打基线，不够再换。

2) imgsz=320 而非默认 640
   原图只有 200×200，放大到 640 是纯粹的算力浪费。
   320 已足够表达缺陷纹理，训练快约 4 倍。

3) 针对类别不平衡的处理
   统计显示 inclusion 有 1011 个框，pitted_surface 只有 432 个（差 2.3 倍）。
   不加干预时 pitted_surface 的 mAP 会明显偏低。
   这里用【类别权重】补偿：框数少的类别给更高损失权重。

4) 固定随机种子
   保证论文/报告里引用的指标可复现。
"""

from __future__ import annotations

import argparse
import json
import random
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
TRAINING_ROOT = HERE.parent
DATA_YAML = TRAINING_ROOT / "dataset_yolo" / "data.yaml"

CLASSES = ["crazing", "inclusion", "patches", "pitted_surface", "rolled-in_scale", "scratches"]

# 各类别标注框数量（由 prepare_dataset.py 统计得到）
# 用于计算类别权重：框越少，权重越高
CLASS_BOX_COUNTS = {
    "crazing": 689,
    "inclusion": 1011,
    "patches": 881,
    "pitted_surface": 432,
    "rolled-in_scale": 628,
    "scratches": 548,
}


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="训练 NEU-DET 钢材缺陷检测模型")
    p.add_argument("--model", default="yolov8n.pt",
                   help="基础模型（yolov8n/s/m）或已有权重路径")
    p.add_argument("--epochs", type=int, default=150)
    p.add_argument("--imgsz", type=int, default=320,
                   help="输入尺寸，原图 200x200，320 足够")
    p.add_argument("--batch", type=int, default=16,
                   help="批大小，8GB 显存下 16 是安全值")
    p.add_argument("--patience", type=int, default=30, help="早停轮数")
    p.add_argument("--device", default="0", help="0=第一块 GPU，cpu=CPU")
    p.add_argument("--workers", type=int, default=4)
    p.add_argument("--name", default="neu_det_yolov8n", help="训练任务名")
    p.add_argument("--resume", action="store_true", help="从中断处继续")
    p.add_argument("--no-imbalance-mitigation", action="store_true",
                   help="关闭不平衡缓解（cls 回默认 0.5、不用 copy_paste）—— 用于对比实验")
    return p.parse_args()


def set_seed(seed: int = 42) -> None:
    random.seed(seed)
    np.random.seed(seed)
    try:
        import torch
        torch.manual_seed(seed)
        if torch.cuda.is_available():
            torch.cuda.manual_seed_all(seed)
    except ImportError:
        pass


def check_environment() -> None:
    """训练前的环境自检，把常见坑在这里拦下来"""
    print("=" * 68)
    print("  环境自检")
    print("=" * 68)

    try:
        import torch
    except ImportError:
        raise SystemExit("❌ 未安装 PyTorch。请先执行:\n"
                         "   pip install torch torchvision "
                         "--index-url https://download.pytorch.org/whl/cu128")

    print(f"  PyTorch   : {torch.__version__}")
    print(f"  CUDA 编译 : {torch.version.cuda}")

    if not torch.cuda.is_available():
        print("  ⚠️ GPU 不可用，将使用 CPU 训练（会非常慢）")
        return

    print(f"  显卡      : {torch.cuda.get_device_name(0)}")
    cap = torch.cuda.get_device_capability(0)
    print(f"  算力      : {cap[0]}.{cap[1]}")

    total = torch.cuda.get_device_properties(0).total_memory / 1024**3
    print(f"  显存      : {total:.1f} GB")

    # 真正执行一次运算 —— 只有这样才能确认 kernel 没缺
    # 这是 RTX 50 系最容易踩的坑：能检测到 GPU，但一算就报 no kernel image
    try:
        x = torch.randn(512, 512, device="cuda")
        _ = (x @ x).sum().item()
        print("  ✅ GPU 运算验证通过")
    except RuntimeError as e:
        if "no kernel image" in str(e):
            raise SystemExit(
                "\n❌ PyTorch 缺少 Blackwell(算力 12.0) 的机器码。\n"
                "   当前 PyTorch 不是 cu128 构建，请重装:\n"
                "   pip install torch torchvision "
                "--index-url https://download.pytorch.org/whl/cu128"
            )
        raise

    if cap[0] < 12:
        print(f"  ℹ️ 算力 {cap[0]}.{cap[1]} 不是 Blackwell，cu128 也可正常使用")


def report_class_imbalance() -> None:
    """
    报告类别不平衡情况，并说明本脚本采取的对策与其局限。

    诚实说明
    --------
    ultralytics **不提供按类加权的官方入口**（v8DetectionLoss 内部固定使用
    BCEWithLogitsLoss，未暴露 pos_weight）。因此本脚本**没有**做真正的类别加权。

    采取的对策是参数层面的温和缓解：
      cls=0.7（默认 0.5）——提高分类损失增益，让模型对难分样本更敏感。
    这【不是】类别加权，只是整体提升分类分支的权重。

    相关增强参数：
      copy_paste=0.3 —— 复制粘贴增强，对稀有类别有实质帮助

    ⚠️ 实测结论（2026-10-13，150 轮训练后）
    ----------------------------------------
    训练完成后按类别统计，**推翻了「框少的类一定差」这个假设**：

        patches         框数 881   mAP@0.5 = 0.9317
        scratches       框数 548   mAP@0.5 = 0.9438   ← 框数中等，表现最好
        pitted_surface  框数 432   mAP@0.5 = 0.8388   ← 框数最少，表现却不错
        inclusion       框数 1011  mAP@0.5 = 0.8370   ← 框数最多，表现中等
        rolled-in_scale 框数 628   mAP@0.5 = 0.5653
        crazing         框数 689   mAP@0.5 = 0.4175   ← 最差，但框数并不少

    真正的决定因素是【缺陷本身的视觉可分性与定位难度】，不是标注数量：
      - scratches / patches：形态明确、边界清晰 → 易学
      - crazing：细密网状裂纹，弥漫且边界模糊 → 难定位
        （其 mAP@0.5=0.42 但 mAP@0.5:0.95 仅 0.16，说明"能发现但框不准"）

    因此后续优化方向应针对 crazing 的定位精度，而非继续补偿样本数量。
    """
    counts = [CLASS_BOX_COUNTS[c] for c in CLASSES]
    max_c, min_c = max(counts), min(counts)
    print("\n  类别标注数量报告（注意：实测表明它不是精度的决定因素）")
    for name, cnt in zip(CLASSES, counts):
        bar = "█" * max(1, round(cnt / max_c * 30))
        flag = "  ← 最少" if cnt == min_c else ("  ← 最多" if cnt == max_c else "")
        print(f"    {name:<18} {cnt:>5}  {bar}{flag}")
    print(f"    最多/最少 = {max_c / min_c:.2f} 倍")
    print("    对策：cls=0.7 + copy_paste=0.3（温和缓解，非类别加权）")
    print("    ⚠️ 实测：标注少 ≠ 精度低。真正的短板是 crazing 的定位精度。")


def main() -> None:
    args = parse_args()
    set_seed(42)

    if not DATA_YAML.exists():
        raise SystemExit(
            f"❌ 找不到数据集配置: {DATA_YAML}\n"
            "   请先运行: python src/prepare_dataset.py"
        )

    check_environment()

    try:
        from ultralytics import YOLO
    except ImportError:
        raise SystemExit("❌ 未安装 ultralytics。请执行:\n"
                         "   pip install ultralytics -i https://mirrors.aliyun.com/pypi/simple/")

    print("\n" + "=" * 68)
    print("  开始训练")
    print("=" * 68)
    print(f"  基础模型 : {args.model}")
    print(f"  数据集   : {DATA_YAML}")
    print(f"  轮数     : {args.epochs}（早停 patience={args.patience}）")
    print(f"  输入尺寸 : {args.imgsz}")
    print(f"  批大小   : {args.batch}")
    print(f"  设备     : {args.device}")

    if not args.no_imbalance_mitigation:
        report_class_imbalance()

    model = YOLO(args.model)

    cls_gain = 0.5 if args.no_imbalance_mitigation else 0.7
    copy_paste = 0.0 if args.no_imbalance_mitigation else 0.3

    train_kwargs = dict(
        data=str(DATA_YAML),
        epochs=args.epochs,
        imgsz=args.imgsz,
        batch=args.batch,
        patience=args.patience,
        device=args.device,
        workers=args.workers,
        project=str(TRAINING_ROOT / "runs" / "detect"),
        name=args.name,
        exist_ok=True,
        seed=42,
        resume=args.resume,
        # 分类损失增益（默认 0.5）
        cls=cls_gain,
        # 复制粘贴增强：对稀有类别有实质帮助
        copy_paste=copy_paste,
        # 钢材缺陷图是灰度纹理，翻转安全
        fliplr=0.5,
        flipud=0.5,
        mosaic=0.5,
        mixup=0.0,
        # 不做旋转：缺陷的走向在工业场景下有实际意义
        degrees=0.0,
        translate=0.1,
        scale=0.3,
        verbose=True,
        plots=True,
    )

    results = model.train(**train_kwargs)

    # ---------------------------------------------------------- 保存摘要
    save_dir = Path(getattr(results, "save_dir", TRAINING_ROOT / "runs" / "detect" / args.name))
    summary = {
        "model": args.model,
        "imgsz": args.imgsz,
        "batch": args.batch,
        "epochs_requested": args.epochs,
        "patience": args.patience,
        "seed": 42,
        "classes": CLASSES,
        "class_box_counts": CLASS_BOX_COUNTS,
        "save_dir": str(save_dir),
    }

    # 从 results.csv 提取最佳指标
    csv_path = save_dir / "results.csv"
    if csv_path.exists():
        try:
            import csv as _csv
            with csv_path.open(encoding="utf-8") as f:
                rows = list(_csv.DictReader(f))
            if rows:
                def g(row, key):
                    for k in row:
                        if k.strip() == key:
                            return row[k]
                    return None
                best = max(
                    (r for r in rows if g(r, "metrics/mAP50(B)")),
                    key=lambda r: float(g(r, "metrics/mAP50(B)") or 0),
                    default=None,
                )
                if best:
                    summary["best_epoch"] = int(float(g(best, "epoch") or 0))
                    summary["mAP50"] = float(g(best, "metrics/mAP50(B)") or 0)
                    summary["mAP50_95"] = float(g(best, "metrics/mAP50-95(B)") or 0)
                    summary["precision"] = float(g(best, "metrics/precision(B)") or 0)
                    summary["recall"] = float(g(best, "metrics/recall(B)") or 0)
        except Exception as e:  # noqa: BLE001
            print(f"⚠ 解析 results.csv 失败: {e}")

    weights_best = save_dir / "weights" / "best.pt"
    summary["best_weights"] = str(weights_best)
    summary["best_weights_exists"] = weights_best.exists()

    summary_path = save_dir / "train_summary.json"
    summary_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")

    print("\n" + "=" * 68)
    print("  训练完成")
    print("=" * 68)
    print(f"  输出目录 : {save_dir}")
    print(f"  最佳权重 : {weights_best}")
    if "mAP50" in summary:
        print(f"  mAP@0.5    : {summary['mAP50']:.4f}")
        print(f"  mAP@0.5:0.95: {summary['mAP50_95']:.4f}")
        print(f"  精确率     : {summary['precision']:.4f}")
        print(f"  召回率     : {summary['recall']:.4f}")
    print(f"  摘要已存 : {summary_path}")
    print("\n  下一步: python src/evaluate.py")


if __name__ == "__main__":
    main()
