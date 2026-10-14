/**
 * NEU-DET 钢材表面缺陷数据集 —— 6 类缺陷定义
 *
 * 这是东北大学（Northeastern University）发布的钢材表面缺陷检测标准数据集，
 * 也是本项目训练模型所用的数据集。
 *
 * 参考：NEU-DET, 6 classes, 1800 images, 200x200
 */

export enum DefectType {
  /** 裂纹 */
  CRACK = 'crazing',
  /** 夹杂物 */
  INCLUSION = 'inclusion',
  /** 斑块 */
  PATCHES = 'patches',
  /** 麻点 */
  PITTED_SURFACE = 'pitted_surface',
  /** 氧化铁皮压入 */
  ROLLED_IN_SCALE = 'rolled-in_scale',
  /** 划痕 */
  SCRATCHES = 'scratches'
}

/** 缺陷类型的中文名 + 显示颜色 */
export interface DefectMeta {
  /** 中文名称 */
  cn: string;
  /** 英文原名（数据集标签） */
  en: string;
  /** 检测框颜色 */
  color: string;
}

export const DEFECT_META: Record<string, DefectMeta> = {
  'crazing': { cn: '裂纹', en: 'crazing', color: '#FF4D4F' },
  'inclusion': { cn: '夹杂物', en: 'inclusion', color: '#FAAD14' },
  'patches': { cn: '斑块', en: 'patches', color: '#52C41A' },
  'pitted_surface': { cn: '麻点', en: 'pitted_surface', color: '#13C2C2' },
  'rolled-in_scale': { cn: '氧化铁皮压入', en: 'rolled-in_scale', color: '#722ED1' },
  'scratches': { cn: '划痕', en: 'scratches', color: '#EB2F96' }
};

/** 全部缺陷类型列表（用于界面展示） */
export const ALL_DEFECT_TYPES: DefectMeta[] = [
  DEFECT_META['crazing'],
  DEFECT_META['inclusion'],
  DEFECT_META['patches'],
  DEFECT_META['pitted_surface'],
  DEFECT_META['rolled-in_scale'],
  DEFECT_META['scratches']
];

/**
 * 单条检测结果
 *
 * 坐标采用【归一化比例】(0~1)，与图片实际像素尺寸无关，
 * 这样界面适配时无需关心原图分辨率。
 */
export interface Detection {
  /** 缺陷类型（对应 NEU-DET 标签） */
  type: string;
  /** 中文名 */
  typeCn: string;
  /** 置信度 0~1 */
  confidence: number;
  /** 左上角 x（比例 0~1） */
  x: number;
  /** 左上角 y（比例 0~1） */
  y: number;
  /** 宽（比例 0~1） */
  w: number;
  /** 高（比例 0~1） */
  h: number;
}

/** 批量检测中的单项结果 */
export interface BatchItem {
  /** 图片 URI */
  uri: string;
  /** 序号（从 1 开始，用于界面显示） */
  index: number;
  /** 图片原始宽高 */
  imageWidth: number;
  imageHeight: number;
  /** 该图检出的缺陷框 */
  boxes: Detection[];
  /** 该项总耗时（ms） */
  costMs: number;
  /** 是否合格：未检出任何缺陷即为合格 */
  ok: boolean;
  /** 失败时的错误信息，正常为空串 */
  error: string;
}

/** 一次完整检测的输出 */
export interface DetectionResult {
  /** 检出框列表 */
  boxes: Detection[];
  /** 全流程耗时（毫秒）：解码 + 缩放 + 转 NCHW + 推理 + NMS */
  costMs: number;
  /** 纯推理耗时（毫秒）：仅 model.predict() 那一段；Mock 检测器为 0 */
  inferMs: number;
  /** 图片原始宽高（像素），未知时为 0 */
  imageWidth: number;
  imageHeight: number;
  /** 本次推理使用的后端，如 Mock / MindSporeLite-NPU */
  backend: string;
}
