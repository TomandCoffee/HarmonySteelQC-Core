# NEU-DET 钢材表面缺陷检测 —— 训练说明

本目录负责「数据 → 模型 → 端侧部署格式」的完整链路。

```
training/
├── dataset/NEU-DET/          NEU-DET 原始数据集（Pascal VOC 格式，27 MB，已入库）
│   ├── ANNOTATIONS/*.xml     1800 个标注
│   └── IMAGES/*.jpg          1800 张图片（200×200 灰度）
├── dataset_yolo/             转换后的 YOLO 格式（自动生成，不入库）
├── src/
│   ├── prepare_dataset.py    VOC → YOLO 转换 + 训练/验证划分
│   ├── train.py              YOLO 训练
│   ├── evaluate.py           精度评估
│   └── export_onnx.py        导出 ONNX（供端侧转换）
└── requirements.txt
```

---

## 一、环境准备

### ⚠️ 关键约束：RTX 50 系必须用 CUDA 12.8 版 PyTorch

开发机显卡是 **RTX 5060 Laptop（Blackwell 架构，算力 12.0）**。
PyTorch 官方从 **2.7 版本**起才提供 `cu128` 构建，**装旧版会直接报错**：

```
CUDA error: no kernel image is available for execution on the device
```

这个错误具有迷惑性——它看起来像驱动问题，实际是 PyTorch 没编译进 Blackwell 的机器码。

### 创建虚拟环境并安装

```powershell
$py = "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe"
$venv = "D:\HarmonyProjects\HarmonySteelQC\training\.venv"

# 1. 建虚拟环境（不要装进系统 Python，避免污染其他项目）
& $py -m venv $venv

# 2. 装 PyTorch —— 必须指定 cu128 索引
& "$venv\Scripts\python.exe" -m pip install torch torchvision `
    --index-url https://download.pytorch.org/whl/cu128

# 3. 装其余依赖（走国内镜像，快很多）
& "$venv\Scripts\python.exe" -m pip install -r requirements.txt `
    -i https://mirrors.aliyun.com/pypi/simple/
```

### 验证 GPU 可用

```powershell
& "$venv\Scripts\python.exe" -c @"
import torch
print('PyTorch   :', torch.__version__)
print('CUDA 版本 :', torch.version.cuda)
print('GPU 可用  :', torch.cuda.is_available())
if torch.cuda.is_available():
    print('显卡      :', torch.cuda.get_device_name(0))
    print('算力      :', torch.cuda.get_device_capability(0))
    # 真正跑一次矩阵乘法，确认 kernel 没缺
    x = torch.randn(1000, 1000, device='cuda')
    print('矩阵乘法  :', (x @ x).sum().item())
"@
```

**预期输出**：`GPU 可用: True`、`算力: (12, 0)`、矩阵乘法有数值。
**如果矩阵乘法报 `no kernel image`** → PyTorch 版本不对，重装 cu128。

---

## 二、数据准备

```powershell
cd D:\HarmonyProjects\HarmonySteelQC\training
& ".venv\Scripts\python.exe" "src\prepare_dataset.py"
```

脚本会：
1. 解析 1800 个 VOC XML
2. 按类别**分层抽样**划分 80% 训练 / 20% 验证（随机种子固定为 42，可复现）
3. 把绝对坐标转成归一化的 `class cx cy w h`
4. 生成 `dataset_yolo/data.yaml`

**类别顺序（固定，推理端必须一致）**：

| ID | 名称 | 中文 | 图片数 | 标注框数 |
|---|---|---|---|---|
| 0 | crazing | 裂纹 | 300 | 689 |
| 1 | inclusion | 夹杂物 | 300 | 1011 |
| 2 | patches | 斑块 | 300 | 881 |
| 3 | pitted_surface | 麻点 | 300 | 432 |
| 4 | rolled-in_scale | 氧化铁皮压入 | 300 | 628 |
| 5 | scratches | 划痕 | 300 | 548 |

> ⚠️ 注意第 4 类文件名含连字符（`rolled-in_scale_1.jpg`），
> 解析时不能简单地按 `_` 切分取第一段——脚本里用「从长到短匹配前缀」处理。

---

## 三、训练

```powershell
& ".venv\Scripts\python.exe" "src\train.py"
```

### 选型说明

| 模型 | 参数量 | 权重体积 | 预期 mAP@0.5 | 端侧可行性 |
|---|---|---|---|---|
| **yolov8n** | 3.2 M | ~6 MB | 0.70~0.78 | ⭐ 推荐，最容易上 NPU |
| yolov8s | 11.2 M | ~22 MB | 0.75~0.82 | 可以，但慢 |
| yolov8m | 25.9 M | ~50 MB | 0.78~0.85 | 端侧偏重 |

**本项目选 `yolov8n`**：NEU-DET 只有 1800 张图，大模型容易过拟合；
且端侧部署时模型越小，NPU 算子支持越完整、推理越快。

### 训练参数

| 参数 | 值 | 理由 |
|---|---|---|
| `imgsz` | 320 | 原图仅 200×200，320 足够；再大只是白烧算力 |
| `epochs` | 150 | 数据集小，需要足够轮次收敛 |
| `batch` | 16 | 8 GB 显存下的安全值 |
| `patience` | 30 | 30 轮无提升则早停 |

**显存预期**：yolov8n + imgsz320 + batch16 约占 2~3 GB，
开发机 8 GB 显存**绰绰有余**，训练时还能同时开浏览器。

### 训练产物

```
training/runs/detect/neu_det_yolov8n/
├── weights/
│   ├── best.pt      最佳权重（用这个做后续导出）
│   └── last.pt      最后一轮
├── results.csv      每轮指标
├── confusion_matrix.png
└── val_batch*.jpg   验证集预测可视化
```

---

## 四、评估

```powershell
& ".venv\Scripts\python.exe" "src\evaluate.py"
```

输出每类的 mAP@0.5、mAP@0.5:0.95、精确率、召回率，
结果同时写成 `eval_result.json` 便于引用。

---

## 五、实测结果（2026-10-13 完成）

### 训练配置

| 参数 | 值 |
|---|---|
| 模型 | YOLOv8n（3,133,922 参数，8.6 GFLOPs） |
| 输入尺寸 | 320×320 |
| 批大小 | 16 |
| 轮数 | 150（未触发早停） |
| 数据集 | 1440 训练 / 360 验证 |
| 训练耗时 | **16 分钟**（RTX 5060 Laptop 8 GB） |

### 总体指标

| 指标 | 值 |
|---|---|
| **mAP@0.5** | **0.7660**（第 115 轮最佳） |
| mAP@0.5:0.95 | 0.4289 |
| 精确率 | 0.6988 |
| 召回率 | 0.7378 |
| 推理速度 | 1.3 ms/张（PyTorch，GPU） |

> 参考：NEU-DET 上 YOLOv8n 的公开报告区间约 0.70~0.78，本结果处于中上水平。

### 按类别指标 —— ⚠️ 推翻了原假设

| 类别 | 中文 | mAP@0.5 | mAP@.5:.95 | P | R | 标注框数 |
|---|---|---|---|---|---|---|
| **scratches** | 划痕 | **0.9438** | 0.5926 | 0.7765 | 0.9167 | 548 |
| **patches** | 斑块 | **0.9317** | 0.6029 | 0.8385 | 0.9227 | 881 |
| pitted_surface | 麻点 | 0.8388 | 0.5467 | 0.7693 | 0.8333 | **432**（最少） |
| inclusion | 夹杂物 | 0.8370 | 0.4513 | 0.7389 | 0.8117 | **1011**（最多） |
| rolled-in_scale | 氧化铁皮压入 | 0.5653 | 0.2355 | 0.5800 | 0.5845 | 628 |
| **crazing** | 裂纹 | **0.4175** | 0.1649 | 0.5209 | 0.4219 | 689 |

### 关键发现：类别不平衡不是主因

**训练前的假设**：`pitted_surface` 标注框最少（432），预期它的 mAP 会最低。

**实测结果**：假设**错误**。
- `pitted_surface` 拿到 0.8388，表现中上
- `inclusion` 标注最多（1011），表现也只是中等（0.8370）
- 真正最差的是 `crazing`（0.4175），而它的框数（689）并不算少

**真正的决定因素是缺陷的视觉可分性与定位难度**：

| 缺陷 | 形态特征 | 学习难度 |
|---|---|---|
| scratches / patches | 形态明确、边界清晰 | 易 |
| inclusion / pitted_surface | 局部团块或点状，边界较清楚 | 中 |
| rolled-in_scale | 与背景对比度低 | 较难 |
| **crazing** | **细密网状裂纹，弥漫分布、边界模糊** | **最难** |

**`crazing` 的指标特征很能说明问题**：
- mAP@0.5 = 0.4175（能发现）
- mAP@0.5:0.95 = **0.1649**（但框不准）

**0.42 → 0.16 的跌幅**表明：模型能定位到裂纹的大致区域，
但**难以给出精确边界框** —— 这是弥散型缺陷的固有难点，不是样本数量问题。

### 由此得出的优化方向

按优先级：

1. **针对 crazing 改进定位**（而非继续补偿样本数量）
   - 提高输入分辨率（320 → 640）—— 裂纹纹理细，高分辨率可能显著改善
   - 调整该类的框回归损失权重
2. **尝试更大的模型**（yolov8s）看定位精度是否随之提升
3. ~~对稀有类别做过采样~~ —— 实测证明这不是瓶颈

### 端侧部署可行性

| 项目 | 值 |
|---|---|
| PyTorch 权重 | 6.18 MB |
| ONNX 模型 | 12.07 MB |
| INT8 量化后估算 | ~1.5 MB |

**体积完全适合端侧部署**，且 YOLOv8n 结构简单，NPU 算子支持预期良好。

---

## 六、导出 ONNX（端侧部署的第一步）

```powershell
& ".venv\Scripts\python.exe" "src\export_onnx.py"
```

**实测导出结果**：

```
ONNX export success, saved as best.onnx (12.1 MB)
PyTorch 输出形状 : (1, 10, 2100)
ONNX    输出形状 : (1, 10, 2100)
最大绝对误差     : 1.525879e-04     ← 远小于 1e-3 阈值
✅ 输出一致，导出正确
```

**输出形状解读** `(1, 10, 2100)`：

- `1` = batch
- `10` = 4 个框坐标（cx, cy, w, h）+ **6 个类别分数**
- `2100` = 三个检测尺度的候选框总数（320/8、320/16、320/32 的网格）

> ⚠️ **端侧后处理必须自己实现 NMS**。
> YOLOv8 的 ONNX 输出是原始的候选框张量，不含 NMS，
> 写 ArkTS 推理代码时需要自己实现（或改用带 NMS 的导出方式）。

之后：

```
ONNX ──[MindSpore Lite 转换工具]──> .ms 模型 ──> 鸿蒙应用加载
```

> 关键风险是**算子支持**——转完必须实测单帧耗时，
> 若超过 200 ms 说明有算子掉回 CPU 了（NPU 没吃满）。

### 实测转换结果（2026-10-13）

```
CONVERT RESULT SUCCESS:0       耗时 1.4 秒
neu_det_yolov8n.onnx  12.07 MB  →  neu_det_yolov8n.ms  12.05 MB
```

**推理验证**（用 MindSpore Lite 自带的 benchmark 工具，CPU 模式）：

```
Run Benchmark ... Success.
PrepareTime = 24.535 ms
AvgRunTime  = 13.382 ms          ← 单帧 13.4 ms
```

> ⚠️ **Windows 上搭建转换工具链有坑**：
> 官方 Windows 包缺 MinGW 运行库，补上后还会遇到 libstdc++ ABI 版本不匹配。
> 完整解决过程见 [../docs/MindSporeLite-Windows环境搭建.md](../docs/TGR-W10-前期验证/MindSporeLite-Windows环境搭建.md)。

---

## 七、常见问题

| 现象 | 原因 | 解决 |
|---|---|---|
| `no kernel image is available` | PyTorch 不是 cu128 版 | 按上文重装 |
| `CUDA out of memory` | batch 太大 | 改 `batch=8` |
| 训练 mAP 一直是 0 | data.yaml 路径错 | 检查 `path` 字段是否为绝对路径 |
| 某类 mAP 特别低 | 类别样本不平衡 | 看 `confusion_matrix.png` 判断是否被误判成近似的类 |
| 导出 ONNX 报算子不支持 | opset 版本问题 | 降 opset 到 12 或 11 |
