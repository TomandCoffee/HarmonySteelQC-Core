"""
导出 ONNX —— 端侧部署链路的第一步

为什么导出的是 ONNX
--------------------
各家端侧推理框架都不直接吃 PyTorch 权重，而是以 ONNX 作为中间格式：

    PyTorch(.pt) ──本脚本──> ONNX ──> MindSpore Lite(.ms) ──> 鸿蒙应用
                                     └─ RKNN(.rknn)      ──> 香橙派
                                     └─ TensorRT(.engine) ─> NVIDIA

所以「导出 ONNX」是所有端侧路线共同的起点。

关键注意事项
------------
1) opset 版本
   opset 太高，老版本转换工具不认；太低，某些算子表达不出来。
   端侧工具链（尤其 RKNN / MindSpore Lite）对 opset 11~12 支持最好。
   默认用 12，可通过 --opset 调整。

2) 输入尺寸必须固定
   端侧 NPU 一般要求静态 shape。这里固定为训练时的 imgsz。

3) 输出节点
   YOLOv8 的 ONNX 输出是 (batch, 4+nc, num_anchors) 格式，
   端侧后处理需要自己做 NMS —— 这一点在写 ArkTS 推理代码时要注意。

4) 导出后必须验证
   ONNXRuntime 与 PyTorch 的输出差异应小于 1e-3，否则说明导出有问题。

用法
----
    python src/export_onnx.py
    python src/export_onnx.py --imgsz 320 --opset 12
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
TRAINING_ROOT = HERE.parent


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="导出 NEU-DET 模型为 ONNX")
    p.add_argument("--weights", default=None,
                   help="权重路径，默认 runs/detect/neu_det_yolov8n/weights/best.pt")
    p.add_argument("--imgsz", type=int, default=320)
    p.add_argument("--opset", type=int, default=12,
                   help="ONNX opset，端侧工具链建议 11~12")
    p.add_argument("--simplify", action="store_true", default=True,
                   help="简化计算图（去掉冗余算子，利于端侧转换）")
    p.add_argument("--dynamic", action="store_true", default=False,
                   help="动态 batch。端侧 NPU 通常要求静态，默认关闭")
    return p.parse_args()


def main() -> None:
    args = parse_args()

    weights = Path(args.weights) if args.weights else (
        TRAINING_ROOT / "runs" / "detect" / "neu_det_yolov8n" / "weights" / "best.pt"
    )
    if not weights.exists():
        raise SystemExit(f"❌ 找不到权重: {weights}\n   请先训练: python src/train.py")

    export_dir = TRAINING_ROOT / "export"
    export_dir.mkdir(parents=True, exist_ok=True)

    print("=" * 70)
    print("  导出 ONNX")
    print("=" * 70)
    print(f"  权重    : {weights}")
    print(f"  输入尺寸: {args.imgsz}x{args.imgsz}")
    print(f"  opset   : {args.opset}")
    print(f"  简化    : {args.simplify}")
    print(f"  动态轴  : {args.dynamic}")

    from ultralytics import YOLO

    model = YOLO(str(weights))
    onnx_path = model.export(
        format="onnx",
        imgsz=args.imgsz,
        opset=args.opset,
        simplify=args.simplify,
        dynamic=args.dynamic,
        half=False,      # 不导 FP16：多数端侧工具自己会做量化
        int8=False,      # 量化在端侧工具里做，那里有针对目标芯片的校准
    )

    onnx_path = Path(onnx_path)
    if not onnx_path.exists():
        raise SystemExit("❌ 导出失败，未生成 ONNX 文件")

    size_mb = onnx_path.stat().st_size / 1024**2
    print(f"\n  ✅ 已导出: {onnx_path}  ({size_mb:.2f} MB)")

    # ================================================================
    # 验证：ONNX 与 PyTorch 输出是否一致
    # ================================================================
    print("\n" + "=" * 70)
    print("  导出正确性验证（ONNX vs PyTorch）")
    print("=" * 70)
    verify_ok = False
    max_diff = None
    try:
        import numpy as np
        import onnxruntime as ort
        import torch

        # PyTorch 参考输出
        torch_model = YOLO(str(weights))
        net = torch_model.model.fuse().eval()
        dummy = torch.randn(1, 3, args.imgsz, args.imgsz)
        with torch.no_grad():
            torch_out = net(dummy)
        if isinstance(torch_out, (list, tuple)):
            torch_out = torch_out[0]
        torch_out = torch_out.cpu().numpy()

        # ONNX 输出
        sess = ort.InferenceSession(str(onnx_path), providers=["CPUExecutionProvider"])
        input_name = sess.get_inputs()[0].name
        onnx_out = sess.run(None, {input_name: dummy.numpy()})[0]

        print(f"  PyTorch 输出形状 : {torch_out.shape}")
        print(f"  ONNX    输出形状 : {onnx_out.shape}")

        if torch_out.shape == onnx_out.shape:
            max_diff = float(np.max(np.abs(torch_out - onnx_out)))
            print(f"  最大绝对误差     : {max_diff:.6e}")
            if max_diff < 1e-3:
                print("  ✅ 输出一致，导出正确")
                verify_ok = True
            else:
                print("  ⚠️ 误差偏大，请检查 opset 或 simplify 设置")
        else:
            print("  ⚠️ 形状不一致，可能是输出节点解析方式不同（YOLOv8 常见）")
            print("     这不一定是错误，但端侧后处理需按 ONNX 的实际输出形状来写")
    except ImportError as e:
        print(f"  ⚠️ 缺少验证依赖，跳过: {e}")
        print("     安装: pip install onnxruntime")
    except Exception as e:  # noqa: BLE001
        print(f"  ⚠️ 验证过程出错: {e}")

    # ================================================================
    # 端侧转换提示
    # ================================================================
    print("\n" + "=" * 70)
    print("  下一步：转成端侧格式")
    print("=" * 70)
    print(f"  ONNX 文件: {onnx_path}")
    print()
    print("  【华为鸿蒙平板】MindSpore Lite 转换工具")
    print("     pip install mindspore-lite 或使用 MindSpore Lite 官方转换工具")
    print("     产物: .ms 模型，应用侧用 @ohos.ai.mindSporeLite 加载")
    print("     目标设备: 华为 MatePad 11.5''S (TGR-W10)")
    print()
    print("  【香橙派 RK3566/3588】RKNN-Toolkit2")
    print("     产物: .rknn 模型")
    print()
    print("  ⚠️ 重要：转换后必须实测单帧推理耗时")
    print("     若超过 200 ms，说明有算子不被 NPU 支持、回退到 CPU 了。")
    print("     此时需要用 Netron 查看计算图，找出不支持的算子并替换。")

    # 落盘元信息
    meta = {
        "weights": str(weights),
        "onnx": str(onnx_path),
        "imgsz": args.imgsz,
        "opset": args.opset,
        "dynamic": args.dynamic,
        "size_mb": round(size_mb, 3),
        "verified": verify_ok,
        "max_abs_diff": max_diff,
        "input_name": "images",
        "note": (
            "YOLOv8 ONNX 输出形状为 (batch, 4+nc, num_anchors)，"
            "端侧需自行实现 NMS 后处理"
        ),
    }
    meta_path = export_dir / "export_meta.json"
    meta_path.write_text(json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\n  导出信息: {meta_path}")


if __name__ == "__main__":
    main()
