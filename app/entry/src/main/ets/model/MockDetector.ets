/**
 * 模拟检测器 —— 用于打通界面链路
 *
 * 【重要】本类不产生真实检测结果，仅用于：
 *   1. 验证「拍照 → 检测 → 显示框 → 列结果」的完整业务流程
 *   2. 固定数据契约，使真实模型接入时界面代码零改动
 *
 * 所有输出字段（类型/置信度/坐标/耗时/图片尺寸）都与真实模型保持一致，
 * 唯一区别是数值由伪随机数生成。
 *
 * TODO(下一步): 实现 MindSporeLiteDetector，加载 NEU-DET 训练的 .ms 模型
 */
import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { Detector } from './Detector';
import { Detection, DetectionResult, DefectType, DEFECT_META } from './DefectType';

/** 确定性伪随机数发生器（避免每次结果跳变过大，便于截图对比） */
class Rng {
  private seed: number;

  constructor(seed: number) {
    this.seed = seed;
  }

  /** 返回 [0, 1) */
  next(): number {
    // 线性同余，保证结果可复现
    this.seed = (this.seed * 1103515245 + 12345) % 2147483648;
    return this.seed / 2147483648;
  }

  /** 返回 [min, max) */
  range(min: number, max: number): number {
    return min + this.next() * (max - min);
  }

  /** 返回 [min, max] 的整数 */
  int(min: number, max: number): number {
    return Math.floor(this.range(min, max + 1));
  }
}

export class MockDetector implements Detector {
  readonly backendName: string = 'Mock（模拟数据）';

  private rng: Rng = new Rng(20261013);
  private ready: boolean = false;

  async init(): Promise<boolean> {
    // 真实实现里这里会加载模型文件
    this.ready = true;
    return true;
  }

  async detect(uri: string): Promise<DetectionResult> {
    const start: number = Date.now();

    // 读取图片真实尺寸（真实模型也需要这一步做 letterbox 预处理）
    const size = await this.readImageSize(uri);

    // 模拟模型推理耗时：平板 NPU 上 YOLOv8n 量级大约 20~60ms
    await this.sleep(25 + this.rng.int(0, 35));

    // 生成 1~3 个缺陷框
    const count: number = this.rng.int(1, 3);
    const types: string[] = [
      DefectType.SCRATCHES,
      DefectType.CRACK,
      DefectType.INCLUSION,
      DefectType.PATCHES,
      DefectType.PITTED_SURFACE,
      DefectType.ROLLED_IN_SCALE
    ];

    const boxes: Detection[] = [];
    for (let i = 0; i < count; i++) {
      const type: string = types[this.rng.int(0, types.length - 1)];
      const meta = DEFECT_META[type];

      // 归一化坐标：保证框落在图片范围内
      const w: number = this.rng.range(0.12, 0.32);
      const h: number = this.rng.range(0.12, 0.32);
      const x: number = this.rng.range(0.04, 0.96 - w);
      const y: number = this.rng.range(0.04, 0.96 - h);

      boxes.push({
        type: type,
        typeCn: meta.cn,
        confidence: this.rng.range(0.62, 0.96),
        x: x,
        y: y,
        w: w,
        h: h
      });
    }

    // 按置信度从高到低排序，界面展示更合理
    boxes.sort((a: Detection, b: Detection) => b.confidence - a.confidence);

    return {
      boxes: boxes,
      costMs: Date.now() - start,
      inferMs: 0,
      imageWidth: size.width,
      imageHeight: size.height,
      backend: this.backendName
    };
  }

  async release(): Promise<void> {
    this.ready = false;
  }

  /** 读取图片真实像素尺寸 */
  private async readImageSize(uri: string): Promise<Size> {
    let src: image.ImageSource | undefined = undefined;
    let file: fileIo.File | undefined = undefined;
    try {
      file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      src = image.createImageSource(file.fd);
      const info: image.ImageInfo = await src.getImageInfo();
      return { width: info.size.width, height: info.size.height };
    } catch (e) {
      // 读不到尺寸不影响流程，返回 0 由界面自行处理
      return { width: 0, height: 0 };
    } finally {
      if (src !== undefined) {
        try {
          await src.release();
        } catch (e) {
          // 忽略释放异常
        }
      }
      if (file !== undefined) {
        try {
          fileIo.closeSync(file);
        } catch (e) {
          // 忽略关闭异常
        }
      }
    }
  }

  private sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }
}

/** 图片尺寸 */
interface Size {
  width: number;
  height: number;
}
