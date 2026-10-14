/**
 * 缺陷检测器接口
 *
 * 【设计意图】
 * 现在用 MockDetector（假数据）把「拍照 → 检测 → 显示结果」的完整链路跑通，
 * 等 YOLO 模型训练完成并转成 .ms 格式后，只需实现一个 MindSporeLiteDetector，
 * 在 Index.ets 里改一行 new XXX() 即可切换到真实推理，界面代码完全不用动。
 */
import { Detection, DetectionResult } from './DefectType';

export interface Detector {
  /** 后端名称，显示在界面上 */
  readonly backendName: string;

  /**
   * 初始化（加载模型等）
   * @returns 是否成功
   */
  init(): Promise<boolean>;

  /**
   * 对一张图片执行检测
   * @param uri 图片 URI
   * @returns 检测结果
   */
  detect(uri: string): Promise<DetectionResult>;

  /** 释放资源 */
  release(): Promise<void>;
}
