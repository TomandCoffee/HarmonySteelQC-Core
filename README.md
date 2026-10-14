# HarmonySteelQC · 基于鸿蒙平板的工业质量检测软件

> 南京理工大学紫金学院 ZJSRTP 创新训练项目

## 研究目的

**训练本地模型开发华为 6.0 及以上版本平板端工业质量检测软件，并进行 NPU 优化。**

## 实现了什么

```
NEU-DET 数据集 ──► 本地训练 YOLOv8n ──► 导出/转换 ──► 鸿蒙平板端侧推理（NPU 加速）
```

| 环节 | 实现 |
|---|---|
| **模型** | 本地训练 YOLOv8n（mAP@0.5 = **0.766**），PyTorch → ONNX → MindSpore Lite `.ms` |
| **应用** | HarmonyOS 平板应用（ArkTS）：拍照 / 相册 / 文件 / 内置图库（NEU-DET 全量 1800 张随包分发）四种取图方式、批量识别、6 类缺陷框可视化与合格判定，完全离线 |
| **NPU** | 现有 `.ms` 模型**直接跑 `nnrt` 后端，无需 OMG / `.om`**；同设备对照实测：端到端快约 **1.8 倍**、纯推理快 **7.3 倍**，且跨多次复测稳定 |
| **目标设备** | HUAWEI MatePad Pro Max 悦享（`GEM-W40` / Kirin T93 / HarmonyOS 7.0）；应用兼容 **华为 6.0 及以上平板**（`compatibleSdkVersion 6.1.1(24)`） |

## 关键数据（均来自 `GEM-W40` 同设备对照实测）

| 项 | 值 |
|---|---|
| 模型精度 | mAP@0.5 = 0.7660（6 类钢材缺陷） |
| **端到端检测** | `cpu` 86 ms → **`nnrt(NPU)` 49 ms（约 1.8 倍）** |
| **纯推理** | `cpu` 29 ms → **`nnrt(NPU)` 4 ms（7.3 倍）** |
| 批量吞吐 | 50 张混合尺寸共 1.77 s，平均 35 ms/张 |
| 冷启动开销 | +4 ms，无需预热 |

## 目录结构

```
HarmonySteelQC/
├── app/            HarmonyOS 应用（ArkTS）
│   └── entry/src/main/
│       ├── ets/
│       │   ├── entryability/   应用入口
│       │   ├── model/          6 类缺陷定义、检测器接口、真实/模拟检测器
│       │   └── pages/          主界面（取图、检测、结果可视化）
│       └── resources/rawfile/
│           ├── neu_det_yolov8n.ms     端侧模型
│           └── neuimg/                NEU-DET 1800 张测试图（内置图库）
└── training/       模型训练管线
    ├── src/        数据转换 / 训练 / 评估 / 导出 ONNX
    ├── dataset/NEU-DET/   原始数据集（VOC）
    ├── export/     训练产物（.pt / .onnx / .ms）
    └── README.md   训练详解
```

## 快速开始

### 训练模型

```powershell
cd training
& "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe" -m venv .venv
& ".venv\Scripts\python.exe" -m pip install torch torchvision --index-url https://download.pytorch.org/whl/cu128
& ".venv\Scripts\python.exe" -m pip install -r requirements.txt -i https://mirrors.aliyun.com/pypi/simple/
& ".venv\Scripts\python.exe" src\prepare_dataset.py
& ".venv\Scripts\python.exe" src\train.py
& ".venv\Scripts\python.exe" src\evaluate.py
& ".venv\Scripts\python.exe" src\export_onnx.py
```

详见 [training/README.md](training/README.md)

### 构建应用

```powershell
cd app
# 首次需在 DevEco Studio 中配置签名（文件 → 项目结构 → 签名配置 → 自动生成签名）
$env:DEVECO_SDK_HOME = "D:\DevEco Studio\sdk"
& "D:\DevEco Studio\tools\node\node.exe" `
  "D:\DevEco Studio\tools\hvigor\bin\hvigorw.js" `
  --mode module -p product=default -p module=entry@default assembleHap --no-daemon
```

详见 [app/README.md](app/README.md)

## 相关仓库

| 仓库 | 内容 |
|---|---|
| 本仓库 | 核心代码交付版（应用 + 训练管线） |
| [HarmonySteelQC（研究过程仓库）](https://github.com/TomandCoffee/HarmonySteelQC) / [Gitee 镜像](https://gitee.com/njyzxt/HarmonySteelQC) | 完整研究过程：实验记录、NPU 论证证据链、错误与修正记录 |
