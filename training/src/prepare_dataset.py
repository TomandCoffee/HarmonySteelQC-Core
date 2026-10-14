"""
NEU-DET 数据集转换：Pascal VOC (XML) -> YOLO (TXT)

背景
----
NEU-DET 官方发布的是 Pascal VOC 格式：
    ANNOTATIONS/*.xml   每个 XML 描述一张图里的所有缺陷框
    IMAGES/*.jpg        对应图片

YOLO 训练需要的是每张图一个 .txt，每行一个框：
    <class_id> <cx> <cy> <w> <h>
其中 cx/cy/w/h 都是【相对图片尺寸归一化】到 0~1 的值。

类别顺序（固定，训练和推理必须一致）
------------------------------------
    0 crazing           裂纹
    1 inclusion         夹杂物
    2 patches           斑块
    3 pitted_surface    麻点
    4 rolled-in_scale   氧化铁皮压入
    5 scratches         划痕

用法
----
    python -m src.prepare_dataset
    或
    python src/prepare_dataset.py
"""

from __future__ import annotations

import random
import shutil
import xml.etree.ElementTree as ET
from pathlib import Path

# ---------------------------------------------------------------- 配置

# 类别顺序不可随意改动：它同时被训练、评估和端侧推理代码引用
CLASSES: list[str] = [
    "crazing",
    "inclusion",
    "patches",
    "pitted_surface",
    "rolled-in_scale",
    "scratches",
]
CLASS_TO_ID: dict[str, int] = {name: i for i, name in enumerate(CLASSES)}

# 数据集文件名前缀 -> 类别名
# 注意 "rolled-in_scale_1.jpg" 的前缀含连字符，不能用下划线简单切分
PREFIX_TO_CLASS: dict[str, str] = {
    "crazing": "crazing",
    "inclusion": "inclusion",
    "patches": "patches",
    "pitted_surface": "pitted_surface",
    "rolled-in_scale": "rolled-in_scale",
    "scratches": "scratches",
}

RANDOM_SEED = 42
TRAIN_RATIO = 0.8      # 80% 训练，20% 验证
VAL_RATIO = 0.2

# 目录（相对本文件所在目录的上一级，即 training/）
HERE = Path(__file__).resolve().parent
DATASET_SRC = HERE.parent / "dataset" / "NEU-DET"
OUTPUT_DIR = HERE.parent / "dataset_yolo"


def image_class(stem: str) -> str | None:
    """从文件名推断类别，如 'rolled-in_scale_123' -> 'rolled-in_scale'"""
    # 从长到短匹配，避免 'inclusion' 误匹配到别的
    for prefix in sorted(PREFIX_TO_CLASS, key=len, reverse=True):
        if stem.startswith(prefix + "_") or stem == prefix:
            return PREFIX_TO_CLASS[prefix]
    return None


def parse_voc_xml(xml_path: Path) -> tuple[int, int, list[tuple[str, float, float, float, float]]]:
    """
    解析一个 VOC XML。

    返回 (图片宽, 图片高, [(类别名, xmin, ymin, xmax, ymax), ...])
    """
    root = ET.parse(xml_path).getroot()

    size = root.find("size")
    if size is None:
        raise ValueError(f"{xml_path} 缺少 <size> 节点")
    img_w = int(size.findtext("width", "0"))
    img_h = int(size.findtext("height", "0"))
    if img_w <= 0 or img_h <= 0:
        raise ValueError(f"{xml_path} 的宽高非法: {img_w}x{img_h}")

    boxes: list[tuple[str, float, float, float, float]] = []
    for obj in root.findall("object"):
        name = (obj.findtext("name") or "").strip()
        if name not in CLASS_TO_ID:
            # 数据集里偶尔会有拼写差异，这里直接报出来而不是静默丢弃
            raise ValueError(f"{xml_path} 出现未知类别: {name!r}")
        bnd = obj.find("bndbox")
        if bnd is None:
            continue
        xmin = float(bnd.findtext("xmin", "0"))
        ymin = float(bnd.findtext("ymin", "0"))
        xmax = float(bnd.findtext("xmax", "0"))
        ymax = float(bnd.findtext("ymax", "0"))
        boxes.append((name, xmin, ymin, xmax, ymax))

    return img_w, img_h, boxes


def to_yolo_lines(
    img_w: int,
    img_h: int,
    boxes: list[tuple[str, float, float, float, float]],
) -> list[str]:
    """把 VOC 的绝对坐标转成 YOLO 的归一化 cx cy w h"""
    lines: list[str] = []
    for name, xmin, ymin, xmax, ymax in boxes:
        # 裁剪到图片范围内，避免个别标注越界导致训练时报错
        xmin = max(0.0, min(xmin, img_w))
        xmax = max(0.0, min(xmax, img_w))
        ymin = max(0.0, min(ymin, img_h))
        ymax = max(0.0, min(ymax, img_h))

        w = xmax - xmin
        h = ymax - ymin
        if w <= 1 or h <= 1:
            # 退化框（宽或高不足 1 像素）直接跳过
            continue

        cx = (xmin + xmax) / 2.0 / img_w
        cy = (ymin + ymax) / 2.0 / img_h
        nw = w / img_w
        nh = h / img_h

        cls_id = CLASS_TO_ID[name]
        lines.append(f"{cls_id} {cx:.6f} {cy:.6f} {nw:.6f} {nh:.6f}")
    return lines


def main() -> None:
    print("=" * 66)
    print("  NEU-DET -> YOLO 格式转换")
    print("=" * 66)

    ann_dir = DATASET_SRC / "ANNOTATIONS"
    img_dir = DATASET_SRC / "IMAGES"
    if not ann_dir.is_dir() or not img_dir.is_dir():
        raise SystemExit(
            f"数据集目录不完整，请确认存在:\n  {ann_dir}\n  {img_dir}"
        )

    xml_files = sorted(ann_dir.glob("*.xml"))
    print(f"\n发现标注文件: {len(xml_files)} 个")

    # ---------------------------------------------------------- 划分数据集
    # 按类别分层抽样，保证训练集和验证集都覆盖全部 6 类
    by_class: dict[str, list[Path]] = {name: [] for name in CLASSES}
    skipped: list[str] = []
    for xml in xml_files:
        cls = image_class(xml.stem)
        if cls is None:
            skipped.append(xml.name)
            continue
        by_class[cls].append(xml)

    if skipped:
        print(f"⚠ 无法识别类别的文件 {len(skipped)} 个（已跳过）: {skipped[:5]}")

    rng = random.Random(RANDOM_SEED)
    train_set: list[Path] = []
    val_set: list[Path] = []
    for cls, files in by_class.items():
        files = sorted(files)
        rng.shuffle(files)
        n_train = int(len(files) * TRAIN_RATIO)
        train_set.extend(files[:n_train])
        val_set.extend(files[n_train:])
        print(f"  {cls:<18} 共 {len(files):>4}  ->  训练 {n_train:>4} / 验证 {len(files) - n_train:>4}")

    # ---------------------------------------------------------- 输出目录
    if OUTPUT_DIR.exists():
        shutil.rmtree(OUTPUT_DIR)
    for split in ("train", "val"):
        (OUTPUT_DIR / "images" / split).mkdir(parents=True, exist_ok=True)
        (OUTPUT_DIR / "labels" / split).mkdir(parents=True, exist_ok=True)

    # ---------------------------------------------------------- 写文件
    stats = {"train": {"images": 0, "boxes": 0}, "val": {"images": 0, "boxes": 0}}
    class_counter = {name: 0 for name in CLASSES}

    for split, items in (("train", train_set), ("val", val_set)):
        for xml in items:
            img_w, img_h, boxes = parse_voc_xml(xml)
            lines = to_yolo_lines(img_w, img_h, boxes)

            stem = xml.stem
            src_img = img_dir / f"{stem}.jpg"
            if not src_img.exists():
                print(f"⚠ 缺少图片: {src_img.name}，跳过")
                continue

            shutil.copy2(src_img, OUTPUT_DIR / "images" / split / f"{stem}.jpg")
            (OUTPUT_DIR / "labels" / split / f"{stem}.txt").write_text(
                "\n".join(lines) + ("\n" if lines else ""), encoding="utf-8"
            )

            stats[split]["images"] += 1
            stats[split]["boxes"] += len(lines)
            for name, *_ in boxes:
                class_counter[name] += 1

    # ---------------------------------------------------------- 写 data.yaml
    yaml_path = OUTPUT_DIR / "data.yaml"
    names_block = "\n".join(f"  {i}: {name}" for i, name in enumerate(CLASSES))
    yaml_path.write_text(
        "# NEU-DET 钢材表面缺陷检测数据集（由 src/prepare_dataset.py 自动生成）\n"
        f"path: {OUTPUT_DIR.as_posix()}\n"
        "train: images/train\n"
        "val: images/val\n"
        "\n"
        f"nc: {len(CLASSES)}\n"
        "names:\n"
        f"{names_block}\n",
        encoding="utf-8",
    )

    # ---------------------------------------------------------- 汇总
    print("\n" + "=" * 66)
    print("  转换完成")
    print("=" * 66)
    print(f"  训练集: {stats['train']['images']:>5} 张, {stats['train']['boxes']:>6} 个框")
    print(f"  验证集: {stats['val']['images']:>5} 张, {stats['val']['boxes']:>6} 个框")
    print(f"  标注框总计: {sum(stats[s]['boxes'] for s in stats)} 个")
    print(f"\n  各类别框数:")
    for name in CLASSES:
        print(f"    {CLASS_TO_ID[name]} {name:<18} {class_counter[name]:>5}")
    print(f"\n  输出目录: {OUTPUT_DIR}")
    print(f"  配置文件: {yaml_path}")
    print("\n  下一步: python src/train.py")


if __name__ == "__main__":
    main()
