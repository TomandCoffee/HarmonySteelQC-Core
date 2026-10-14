"""
NEU-DET 模型评估脚本

用途
----
加载训练好的权重，在验证集上算完整指标，并按类别拆分。

为什么单独写这个而不是直接用 ultralytics 的 val()
--------------------------------------------------
1) 需要【按类别】的 mAP —— 类别不平衡时，只看总体 mAP 会掩盖
   pitted_surface 这类稀有类别的低分。
2) 结果要落成 JSON，方便写结题报告时直接引用。
3) 输出「端侧部署可行性」判断（模型大小、参数量的粗略估算）。

用法
----
    python src/evaluate.py
    python src/evaluate.py --weights runs/detect/neu_det_yolov8n/weights/best.pt
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
TRAINING_ROOT = HERE.parent
DATA_YAML = TRAINING_ROOT / "dataset_yolo" / "data.yaml"

CLASSES_CN = {
    "crazing": "裂纹",
    "inclusion": "夹杂物",
    "patches": "斑块",
    "pitted_surface": "麻点",
    "rolled-in_scale": "氧化铁皮压入",
    "scratches": "划痕",
}


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="评估 NEU-DET 检测模型")
    p.add_argument("--weights", default=None,
                   help="权重路径，默认取 runs/detect/neu_det_yolov8n/weights/best.pt")
    p.add_argument("--imgsz", type=int, default=320)
    p.add_argument("--batch", type=int, default=16)
    p.add_argument("--device", default="0")
    p.add_argument("--conf", type=float, default=0.001,
                   help="评估用置信度阈值，评估时应取很低以算完整 PR 曲线")
    p.add_argument("--out", default=None, help="结果 JSON 输出路径")
    return p.parse_args()


def main() -> None:
    args = parse_args()

    weights = Path(args.weights) if args.weights else (
        TRAINING_ROOT / "runs" / "detect" / "neu_det_yolov8n" / "weights" / "best.pt"
    )
    if not weights.exists():
        raise SystemExit(f"❌ 找不到权重文件: {weights}\n   请先训练: python src/train.py")
    if not DATA_YAML.exists():
        raise SystemExit(f"❌ 找不到数据集配置: {DATA_YAML}")

    print("=" * 70)
    print("  NEU-DET 模型评估")
    print("=" * 70)
    print(f"  权重     : {weights}")
    print(f"  数据集   : {DATA_YAML}")
    print(f"  输入尺寸 : {args.imgsz}")

    from ultralytics import YOLO

    model = YOLO(str(weights))
    metrics = model.val(
        data=str(DATA_YAML),
        imgsz=args.imgsz,
        batch=args.batch,
        device=args.device,
        conf=args.conf,
        plots=True,
        verbose=False,
    )

    # ---------------------------------------------------------- 总体指标
    overall = {
        "mAP50": float(metrics.box.map50),
        "mAP50_95": float(metrics.box.map),
        "precision": float(metrics.box.mp),
        "recall": float(metrics.box.mr),
    }

    print("\n" + "=" * 70)
    print("  总体指标")
    print("=" * 70)
    print(f"  mAP@0.5       : {overall['mAP50']:.4f}")
    print(f"  mAP@0.5:0.95  : {overall['mAP50_95']:.4f}")
    print(f"  平均精确率     : {overall['precision']:.4f}")
    print(f"  平均召回率     : {overall['recall']:.4f}")

    # ---------------------------------------------------------- 按类别
    per_class: dict[str, dict[str, float]] = {}
    names = metrics.names  # {id: name}
    try:
        ap50_per_class = metrics.box.ap50
        ap_per_class = metrics.box.ap
        p_per_class = metrics.box.p
        r_per_class = metrics.box.r

        print("\n" + "=" * 70)
        print("  按类别指标（类别不平衡的影响会在这里显现）")
        print("=" * 70)
        print(f"  {'类别':<20}{'中文':<14}{'mAP@0.5':>10}{'mAP@.5:.95':>12}{'P':>9}{'R':>9}")
        print("  " + "-" * 72)

        for i, cid in enumerate(sorted(names)):
            name = names[cid]
            entry = {
                "name_cn": CLASSES_CN.get(name, ""),
                "mAP50": float(ap50_per_class[i]),
                "mAP50_95": float(ap_per_class[i]),
                "precision": float(p_per_class[i]),
                "recall": float(r_per_class[i]),
            }
            per_class[name] = entry
            print(f"  {name:<20}{entry['name_cn']:<14}"
                  f"{entry['mAP50']:>10.4f}{entry['mAP50_95']:>12.4f}"
                  f"{entry['precision']:>9.4f}{entry['recall']:>9.4f}")

        # 找出最差/最好的类别
        if per_class:
            worst = min(per_class.items(), key=lambda kv: kv[1]["mAP50"])
            best = max(per_class.items(), key=lambda kv: kv[1]["mAP50"])
            print("\n  " + "-" * 72)
            print(f"  最佳类别: {best[0]:<20} mAP@0.5 = {best[1]['mAP50']:.4f}")
            print(f"  最差类别: {worst[0]:<20} mAP@0.5 = {worst[1]['mAP50']:.4f}")
            gap = best[1]["mAP50"] - worst[1]["mAP50"]
            if gap > 0.15:
                print(f"  ⚠️ 类别间差距 {gap:.4f} 偏大，符合数据集类别不平衡的预期")
    except Exception as e:  # noqa: BLE001
        print(f"\n  ⚠️ 按类别指标解析失败: {e}")

    # ---------------------------------------------------------- 端侧可行性
    size_mb = weights.stat().st_size / 1024**2
    print("\n" + "=" * 70)
    print("  端侧部署可行性")
    print("=" * 70)
    print(f"  PyTorch 权重体积 : {size_mb:.2f} MB")
    # 量化后的粗略估算：FP32 -> INT8 约压缩到 1/4
    print(f"  量化后粗略估算   : {size_mb / 4:.2f} MB（INT8 量化，实际以转换结果为准）")
    if size_mb < 30:
        print("  ✅ 体积适合端侧部署（NPU 友好的量级）")
    else:
        print("  ⚠️ 体积偏大，端侧部署前建议做剪枝或换更小的模型")

    # ---------------------------------------------------------- 落盘
    result = {
        "weights": str(weights),
        "imgsz": args.imgsz,
        "dataset": str(DATA_YAML),
        "overall": overall,
        "per_class": per_class,
        "weights_size_mb": round(size_mb, 3),
    }
    out_path = Path(args.out) if args.out else weights.parent.parent / "eval_result.json"
    out_path.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\n  结果已保存: {out_path}")
    print("  下一步    : python src/export_onnx.py")


if __name__ == "__main__":
    main()
