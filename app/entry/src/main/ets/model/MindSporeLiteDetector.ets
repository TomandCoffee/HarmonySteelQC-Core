/**
 * 基于 MindSpore Lite 的真实缺陷检测器
 *
 * 替换 MockDetector 后，应用即运行真实的 YOLOv8n 模型。
 * 模型文件：resources/rawfile/neu_det_yolov8n.ms
 *
 * ────────────────────────────────────────────────────────────────────
 * 前处理必须与训练一致（关键）
 * ────────────────────────────────────────────────────────────────────
 * 训练时 ultralytics 使用 imgsz=320，配合 translate=0.1 / scale=0.3 增强，
 * 即【直接缩放到 320×320】，不做 letterbox 补边。
 *
 * 因此推理时也必须直接缩放，否则前处理分布与训练不一致，精度会下降。
 * 代价是非正方形图片会有形变——但模型正是在这种形变下训练的，对它无影响。
 *
 * ────────────────────────────────────────────────────────────────────
 * 模型输入输出规格
 * ────────────────────────────────────────────────────────────────────
 *   输入:  images  float32[1, 3, 320, 320]   NCHW, 值域 0~1
 *   输出:  float32[1, 10, 2100]
 *            - 前 4 行: 框坐标 cx, cy, w, h（单位：320 尺度下的像素）
 *            - 后 6 行: 6 个类别的分数（已过 sigmoid）
 *            - 2100 列: 三个检测尺度的候选框之和（40²+20²+10² = 2100）
 *
 * 注意：ONNX/.ms 输出为【原始候选框】，不含 NMS，后处理需自行实现。
 */
import mindSporeLite from '@ohos.ai.mindSporeLite';
import { image } from '@kit.ImageKit';
import { resourceManager } from '@kit.LocalizationKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError, systemDateTime } from '@kit.BasicServicesKit';
import { Detector } from './Detector';
import { Detection, DetectionResult } from './DefectType';

const DOMAIN: number = 0x0000;
const TAG: string = 'MSSpLiteDetector';

/** 模型输入尺寸，必须与训练时的 imgsz 一致 */
const MODEL_SIZE: number = 320;

/** 类别数（NEU-DET 6 类） */
const NUM_CLASSES: number = 6;

/** 候选框总数：40²+20²+10² = 2100 */
const NUM_ANCHORS: number = 2100;

/** 每列的长度：4 个框参数 + 类别数 */
const NUM_COLS: number = 4 + NUM_CLASSES;

/** 置信度阈值：低于此值的候选框丢弃 */
const CONF_THRESHOLD: number = 0.25;

/** NMS 的 IoU 阈值 */
const IOU_THRESHOLD: number = 0.45;

/** 最多保留的检测框数 */
const MAX_DETECTIONS: number = 30;

/** 模型文件名（放在 resources/rawfile/ 下） */
const MODEL_FILE: string = 'neu_det_yolov8n.ms';

/**
 * 后端构建结果
 *
 * 用三态而不是 boolean，是为了区分「真的构建失败」和
 * 「构建成功、但 NPU 后端取不到输入张量」——后者必须回退 CPU，
 * 否则会在推理时崩溃。
 */
enum BuildResult {
  /** 构建失败（或没有可用加速器） */
  FAIL = 0,
  /** 构建成功且输入张量正常 */
  OK = 1,
  /** 构建成功，但 getInputs() 返回 undefined（NPU 后端的已知问题） */
  NO_INPUTS = 2
}

/** NMS 用的中间结构 */
interface Candidate {
  cls: number;
  score: number;
  /** 归一化坐标 0~1 */
  x: number;
  y: number;
  w: number;
  h: number;
}

/** 前处理结果：输入张量 + 两段耗时（供性能剖析与变体对比） */
interface ConvertResult {
  input: ArrayBuffer;
  /** 像素回读耗时（ms） */
  readbackMs: number;
  /** 逐像素循环耗时（ms） */
  loopMs: number;
}

export class MindSporeLiteDetector implements Detector {
  readonly backendName: string = 'MindSporeLite';

  private model: mindSporeLite.Model | undefined = undefined;
  private mgr: resourceManager.ResourceManager | undefined = undefined;
  private ready: boolean = false;
  /** 实际使用的推理后端，实测后回填（'nnrt' 表示走 NPU） */
  private actualTarget: string = 'cpu';

  /** CPU 后端线程数（默认 4；基准测试会扫 2/4/8 做敏感性对比） */
  private cpuThreads: number = 4;

  /** 基准测试用的固定输入张量：解码一次后复用，避免把解码/转换混进纯推理计时 */
  private benchInput: ArrayBuffer | undefined = undefined;

  /** 前处理实现变体（0 = 原实现；基准测试用于同机对比，默认不影响业务） */
  private convertVariant: number = 0;

  /** 256 项归一化查表（变体 2 用；静态只建一次） */
  private static readonly LUT: Float32Array = MindSporeLiteDetector.buildLut();

  private static buildLut(): Float32Array {
    const t = new Float32Array(256);
    for (let i = 0; i < 256; i++) {
      t[i] = i / 255.0;
    }
    return t;
  }

  /**
   * 高精度时钟（毫秒，带小数）。
   *
   * 为什么不用 Date.now()：它只有 1 ms 粒度，而我们测的是 4 ms 级的量 ——
   * 单次测量的量化误差高达 ±25%。systemDateTime.getTime(true) 返回纳秒，
   * 换算成毫秒能把这项误差降到可忽略。取不到时退回 Date.now()。
   */
  private nowMs(): number {
    try {
      return systemDateTime.getTime(true) / 1000000;
    } catch (e) {
      return Date.now();
    }
  }

  /**
   * 强制指定后端（对照实验用）；undefined = 默认行为（先 nnrt 后 cpu 回退）
   *
   * ⚠️ 强制 'nnrt' 时**不做 CPU 回退** —— 否则对照实验的两条腿都可能落到 CPU，
   *    结果失去意义。构建失败就如实返回 false。
   */
  private forceTarget: string | undefined = undefined;

  /** 传入 resourceManager 以便从 rawfile 读取模型 */
  constructor(mgr: resourceManager.ResourceManager, forceTarget?: string) {
    this.mgr = mgr;
    this.forceTarget = forceTarget;
  }

  /** 设置 CPU 后端线程数（只影响 cpu 后端，须在 init() 之前调用） */
  setCpuThreads(n: number): void {
    this.cpuThreads = n;
  }

  /** 设置前处理实现变体（0/1/2；基准测试用） */
  setConvertVariant(v: number): void {
    this.convertVariant = v;
  }

  // ────────────────────────────────────────────────────────────────
  // 初始化
  // ────────────────────────────────────────────────────────────────

  async init(): Promise<boolean> {
    if (this.mgr === undefined) {
      hilog.error(DOMAIN, TAG, 'resourceManager 为空，无法加载模型');
      return false;
    }

    try {
      // 1. 从 rawfile 读取模型字节
      const bytes: Uint8Array = await this.mgr.getRawFileContent(MODEL_FILE);
      hilog.info(DOMAIN, TAG, '模型已读取: %{public}d 字节', bytes.byteLength);

      // 1.5 对照实验模式：只试被指定的那一个后端，不回退
      if (this.forceTarget !== undefined) {
        const forced: BuildResult = await this.buildWithTarget(this.forceTarget);
        if (forced !== BuildResult.OK) {
          hilog.error(DOMAIN, TAG, '强制后端 %{public}s 构建失败（结果 %{public}d），不回退',
            this.forceTarget, forced);
          return false;
        }
        this.actualTarget = (this.forceTarget === 'nnrt') ? 'nnrt(NPU)' : this.forceTarget;
        hilog.info(DOMAIN, TAG, '已按指定后端加载：%{public}s', this.actualTarget);
        this.ready = true;
        return true;
      }

      // 2. 优先尝试 NPU（nnrt）
      const npu: BuildResult = await this.buildWithTarget('nnrt');

      if (npu === BuildResult.OK) {
        this.actualTarget = 'nnrt(NPU)';
        hilog.info(DOMAIN, TAG, '模型加载成功，后端 = NPU');
        this.ready = true;
        return true;
      }

      // NPU 构建成功但拿不到输入张量 —— 这是 NPU 后端的已知问题，
      // 若继续用会在推理时崩溃，因此必须先释放再回退 CPU。
      if (npu === BuildResult.NO_INPUTS) {
        hilog.warn(DOMAIN, TAG, 'NPU 后端无法获取输入张量，释放后改用 CPU');
        this.model = undefined;
      }

      // 3. 回退 CPU
      const cpu: BuildResult = await this.buildWithTarget('cpu');
      if (cpu !== BuildResult.OK) {
        hilog.error(DOMAIN, TAG, 'CPU 后端也加载失败');
        return false;
      }
      this.actualTarget = 'cpu';
      hilog.warn(DOMAIN, TAG, '已回退 CPU（后端结果: %{public}d）', npu);

      this.ready = true;
      return true;
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'init 失败: %{public}s', e.message);
      return false;
    }
  }

  /**
   * 枚举设备上的 NNRT 加速器
   *
   * NNRT（Neural Network Runtime）是鸿蒙的 AI 推理抽象层，
   * 它把底层 NPU 暴露成设备列表。必须先枚举拿到 deviceID 才能用，
   * 直接传空的 nnrt 对象会导致原生层解析失败。
   */
  private findAccelerator(): bigint | undefined {
    try {
      const devices: mindSporeLite.NNRTDeviceDescription[] =
        mindSporeLite.getAllNNRTDeviceDescriptions();

      hilog.info(DOMAIN, TAG, 'NNRT 设备数: %{public}d', devices.length);
      let accelId: bigint | undefined = undefined;
      // NPU 设备（名字以 NPU 开头）优先。理由见下方注释。
      let npuId: bigint | undefined = undefined;
      let npuName: string = '';

      for (let i = 0; i < devices.length; i++) {
        const d = devices[i];
        const dtype: mindSporeLite.NNRTDeviceType = d.deviceType();
        const dname: string = d.deviceName();
        const did: bigint = d.deviceID();

        hilog.info(DOMAIN, TAG, '  设备[%{public}d] type=%{public}d name=%{public}s',
          i, dtype, dname);

        // 只认专用硬件加速器；CPU/GPU 不算
        if (dtype === mindSporeLite.NNRTDeviceType.NNRTDEVICE_ACCELERATOR) {
          accelId = did;
          // ⚠️ 关键：设备列表里可能同时存在「真 NPU」与「通用入口」两种加速器。
          // 实测（MatePad Pro Max 悦享 / Kirin T93）：
          //   设备[0] NPU_ohos.boot.hardware.KirinT93_v2_0   ← 真 NPU
          //   设备[1] HIAI_F                                  ← 通用入口
          // MindSpore Lite 的 NPU 委托按【设备名前缀】校验
          // （本机日志：CheckNPUPrefix# strncmp failed, device_name: HIAI_F），
          // 传 HIAI_F 会被拒。因此优先选名字以 NPU 开头的那个设备。
          if (dname.startsWith('NPU')) {
            npuId = did;
            npuName = dname;
          }
        }
      }

      const chosen: bigint | undefined = (npuId !== undefined) ? npuId : accelId;
      if (chosen !== undefined) {
        hilog.info(DOMAIN, TAG, '选用加速器: id=%{public}s%s',
          String(chosen),
          (npuId !== undefined) ? `（NPU 设备 ${npuName}）` : '（兜底：最后一个加速器）');
      } else {
        hilog.warn(DOMAIN, TAG, '未发现 NNRT 加速器设备');
      }
      return chosen;
    } catch (err) {
      const e = err as BusinessError;
      hilog.warn(DOMAIN, TAG, '枚举 NNRT 设备失败: %{public}s', e.message);
      return undefined;
    }
  }

  /** 按指定后端构建模型；不抛异常，用 BuildResult 表达三态结果 */
  private async buildWithTarget(target: string): Promise<BuildResult> {
    try {
      const ctx: mindSporeLite.Context = { target: [target] };

      if (target === 'cpu') {
        ctx.cpu = {
          threadNum: this.cpuThreads,
          threadAffinityMode: mindSporeLite.ThreadAffinityMode.NO_AFFINITIES,
          precisionMode: 'preferred_fp16'
        };
      } else {
        // NPU：必须先枚举到真实设备的 deviceID
        const accelId: bigint | undefined = this.findAccelerator();
        if (accelId === undefined) {
          hilog.warn(DOMAIN, TAG, '无可用 NPU 加速器，跳过 nnrt 后端');
          return BuildResult.FAIL;
        }
        ctx.nnrt = {
          deviceID: accelId,
          performanceMode: mindSporeLite.PerformanceMode.PERFORMANCE_HIGH,
          priority: mindSporeLite.Priority.PRIORITY_HIGH
        };
      }

      const bytes: Uint8Array = await this.mgr!.getRawFileContent(MODEL_FILE);
      const model = await mindSporeLite.loadModelFromBuffer(bytes.buffer as ArrayBuffer, ctx);

      if (model === undefined) {
        return BuildResult.FAIL;
      }
      this.model = model;

      // 打印输入规格，便于核对前处理是否正确。
      //
      // 注意 getInputs() 在 NPU（nnrt）后端下有已知问题：可能返回 undefined，
      // 直接读 .length 会抛 "Cannot read property length of undefined"。
      // 这个异常会被下面的 catch 捕获，导致**本来构建成功的模型被误判为构建失败**，
      // 于是静默回退到 CPU —— 看起来像"NPU 不可用"，实际是这里崩了。
      // 因此必须判空，并如实区分这两种情况。
      const inputs: mindSporeLite.MSTensor[] | undefined = model.getInputs();
      if (inputs === undefined) {
        hilog.warn(DOMAIN, TAG, 'getInputs() 返回 undefined（%{public}s 后端）', target);
        return BuildResult.NO_INPUTS;
      }
      if (inputs.length > 0) {
        const t = inputs[0];
        hilog.info(DOMAIN, TAG, '输入张量: name=%{public}s shape=%{public}s dtype=%{public}d',
          t.name, JSON.stringify(t.shape), t.dtype);
      }
      return BuildResult.OK;
    } catch (err) {
      const e = err as BusinessError;
      // 区分两种失败，否则日志会把"构建成功但随后崩了"误报成"构建失败"
      if (this.model !== undefined) {
        hilog.error(DOMAIN, TAG, '后端 %{public}s 构建成功但后续步骤异常: %{public}s',
          target, e.message);
      } else {
        hilog.warn(DOMAIN, TAG, '后端 %{public}s 构建失败: %{public}s', target, e.message);
      }
      return BuildResult.FAIL;
    }
  }

  // ────────────────────────────────────────────────────────────────
  // 检测主流程
  // ────────────────────────────────────────────────────────────────

  async detect(uri: string): Promise<DetectionResult> {
    const start: number = Date.now();

    if (this.model === undefined) {
      throw new Error('模型未初始化');
    }

    let src: image.ImageSource | undefined = undefined;
    let pm: image.PixelMap | undefined = undefined;
    let file: fileIo.File | undefined = undefined;
    // 分段打点（供性能剖析：定位瓶颈到底在解码/转换/推理/后处理哪一段）
    let decodeMs: number = 0;
    let convertMs: number = 0;
    let readbackMs: number = 0;
    let loopMs: number = 0;
    let nmsMs: number = 0;

    try {
      // 1. 打开并解码图片（decodeMs 覆盖：打开 + 读图信息 + 解码并按 desiredSize 缩放）
      const tDecode: number = this.nowMs();
      file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      src = image.createImageSource(file.fd);

      const info = await src.getImageInfo();
      const srcW: number = info.size.width;
      const srcH: number = info.size.height;

      // 2. 解码时直接缩放到模型输入尺寸（与训练时的直接缩放一致）
      const opts: image.DecodingOptions = {
        desiredSize: { width: MODEL_SIZE, height: MODEL_SIZE },
        editable: false,
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888
      };
      pm = await src.createPixelMap(opts);
      decodeMs = this.nowMs() - tDecode;

      // 3. 读像素 → NCHW float32 [0,1]（分两段计时：像素回读 / 逐像素循环）
      const conv: ConvertResult = await this.toModelInputTimed(pm);
      const inputBuf: ArrayBuffer = conv.input;
      readbackMs = conv.readbackMs;
      loopMs = conv.loopMs;
      convertMs = readbackMs + loopMs;

      // 4. 推理
      // getInputs() 必须判空：NPU 后端下它可能返回 undefined
      // （init 阶段已做过判定并会回退 CPU，这里是第二道防线）
      const inputs: mindSporeLite.MSTensor[] | undefined = this.model.getInputs();
      if (inputs === undefined || inputs.length === 0) {
        throw new Error(`无法获取模型输入张量（后端 ${this.actualTarget}）`);
      }
      inputs[0].setData(inputBuf);
      const tInfer: number = this.nowMs();
      const outputs: mindSporeLite.MSTensor[] = await this.model.predict(inputs);
      const inferMs: number = this.nowMs() - tInfer;

      // 5. 后处理：解码 + NMS
      if (outputs === undefined || outputs.length === 0) {
        throw new Error('模型推理未返回输出张量');
      }
      const raw = new Float32Array(outputs[0].getData());
      const tNms: number = this.nowMs();
      const boxes: Detection[] = this.postprocess(raw, srcW, srcH);
      nmsMs = this.nowMs() - tNms;

      hilog.info(DOMAIN, TAG, '推理 %{public}d ms, 检出 %{public}d 个, 原图 %{public}dx%{public}d',
        Math.round(inferMs), boxes.length, srcW, srcH);

      return {
        boxes: boxes,
        costMs: this.nowMs() - start,
        inferMs: Math.round(inferMs),
        imageWidth: srcW,
        imageHeight: srcH,
        backend: `${this.backendName}-${this.actualTarget}`,
        decodeMs: Math.round(decodeMs),
        convertMs: Math.round(convertMs),
        readbackMs: Math.round(readbackMs),
        loopMs: Math.round(loopMs),
        nmsMs: Math.round(nmsMs)
      };
    } finally {
      if (pm !== undefined) {
        try {
          await pm.release();
        } catch (e) {
          // 忽略
        }
      }
      if (src !== undefined) {
        try {
          await src.release();
        } catch (e) {
          // 忽略
        }
      }
      if (file !== undefined) {
        try {
          fileIo.closeSync(file);
        } catch (e) {
          // 忽略
        }
      }
    }
  }

  // ────────────────────────────────────────────────────────────────
  // 前处理：PixelMap → float32 NCHW [0,1]
  // ────────────────────────────────────────────────────────────────

  private async toModelInput(pm: image.PixelMap): Promise<ArrayBuffer> {
    return (await this.toModelInputTimed(pm)).input;
  }

  /**
   * RGBA→NCHW 转换（带分段计时）
   *
   * ⚠️ 为什么必须拆成两段计时：
   *   原来只报一个 convertMs，但那个数字里混了两件完全不同的事 ——
   *   ① readPixelsToBuffer：把解码后的像素**回读**到内存（可能含解码/GPU 回读等待）
   *   ② ArkTS 逐像素循环：102,400 次写 Float32Array
   *   不区分就无从判断"该优化循环还是该换回读路径"，属于没定位到行就动刀。
   *
   * 变体（由 convertVariant 选择，基准测试用于同机对比）：
   *   0 = 当前实现：Uint8 逐像素 + 三次 `/255.0` 除法
   *   1 = Uint32 一次读 4 字节 + 位运算取通道 + 预先算好的乘法（避免除法）
   *   2 = 查表法：预计算 256 项归一化浮点表，循环里只做查表与写入
   */
  private async toModelInputTimed(pm: image.PixelMap): Promise<ConvertResult> {
    const byteCount: number = MODEL_SIZE * MODEL_SIZE * 4;
    const rgba = new ArrayBuffer(byteCount);
    const tRead: number = this.nowMs();
    await pm.readPixelsToBuffer(rgba);
    const readbackMs: number = this.nowMs() - tRead;

    const tLoop: number = this.nowMs();
    const plane: number = MODEL_SIZE * MODEL_SIZE;
    const out = new Float32Array(3 * plane);
    const px = new Uint8Array(rgba);

    if (this.convertVariant === 1) {
      // ── 变体 1：Uint32 整体读 + 位运算 + 乘法 ──
      const u32 = new Uint32Array(rgba);
      const inv: number = 1.0 / 255.0;
      for (let i = 0; i < plane; i++) {
        const v: number = u32[i];               // 小端：低字节 = R
        out[i] = (v & 0xFF) * inv;
        out[plane + i] = ((v >>> 8) & 0xFF) * inv;
        out[2 * plane + i] = ((v >>> 16) & 0xFF) * inv;
      }
    } else if (this.convertVariant === 2) {
      // ── 变体 2：查表法（循环内只有查表与写入） ──
      const lut: Float32Array = MindSporeLiteDetector.LUT;
      for (let i = 0; i < plane; i++) {
        const o: number = i * 4;
        out[i] = lut[px[o]];
        out[plane + i] = lut[px[o + 1]];
        out[2 * plane + i] = lut[px[o + 2]];
      }
    } else {
      // ── 变体 0：原实现（保持原样，作为基线） ──
      for (let i = 0; i < plane; i++) {
        const o: number = i * 4;
        out[i] = px[o] / 255.0;
        out[plane + i] = px[o + 1] / 255.0;
        out[2 * plane + i] = px[o + 2] / 255.0;
      }
    }
    const loopMs: number = this.nowMs() - tLoop;

    return { input: out.buffer as ArrayBuffer, readbackMs: readbackMs, loopMs: loopMs };
  }

  // ────────────────────────────────────────────────────────────────
  // 后处理：解码 + NMS
  // ────────────────────────────────────────────────────────────────

  /**
   * 解析 YOLOv8 输出
   *
   * raw 的内存布局为 [10, 2100]（行主序）：
   *   raw[0*2100 + i] = cx  (i = 第 i 个候选框)
   *   raw[1*2100 + i] = cy
   *   raw[2*2100 + i] = w
   *   raw[3*2100 + i] = h
   *   raw[(4+c)*2100 + i] = 第 c 类的分数
   */
  private postprocess(raw: Float32Array, srcW: number, srcH: number): Detection[] {
    const cands: Candidate[] = [];

    for (let i = 0; i < NUM_ANCHORS; i++) {
      // 找最大类别分数
      let bestCls: number = -1;
      let bestScore: number = 0;
      for (let c = 0; c < NUM_CLASSES; c++) {
        const s: number = raw[(4 + c) * NUM_ANCHORS + i];
        if (s > bestScore) {
          bestScore = s;
          bestCls = c;
        }
      }
      if (bestScore < CONF_THRESHOLD || bestCls < 0) {
        continue;
      }

      // 框中心 + 宽高（320 尺度的像素）
      const cx: number = raw[0 * NUM_ANCHORS + i];
      const cy: number = raw[1 * NUM_ANCHORS + i];
      const w: number = raw[2 * NUM_ANCHORS + i];
      const h: number = raw[3 * NUM_ANCHORS + i];

      // 归一化到 0~1（相对模型输入尺寸）
      const nx: number = (cx - w / 2) / MODEL_SIZE;
      const ny: number = (cy - h / 2) / MODEL_SIZE;
      const nw: number = w / MODEL_SIZE;
      const nh: number = h / MODEL_SIZE;

      // 裁剪到画面内
      const x0: number = Math.max(0, nx);
      const y0: number = Math.max(0, ny);
      const x1: number = Math.min(1, nx + nw);
      const y1: number = Math.min(1, ny + nh);
      if (x1 - x0 <= 0.001 || y1 - y0 <= 0.001) {
        continue;
      }

      cands.push({
        cls: bestCls,
        score: bestScore,
        x: x0,
        y: y0,
        w: x1 - x0,
        h: y1 - y0
      });
    }

    if (cands.length === 0) {
      return [];
    }

    // 按分数降序，再做 NMS
    cands.sort((a: Candidate, b: Candidate) => b.score - a.score);
    const kept: Candidate[] = this.nms(cands);

    // 转成应用层数据结构
    const result: Detection[] = [];
    for (let k = 0; k < kept.length && k < MAX_DETECTIONS; k++) {
      const c = kept[k];
      result.push({
        type: CLASS_NAMES[c.cls],
        typeCn: CLASS_NAMES_CN[c.cls],
        confidence: c.score,
        x: c.x,
        y: c.y,
        w: c.w,
        h: c.h
      });
    }
    // 原图尺寸已用于归一化坐标，此处直接返回（界面按比例绘制）
    return result;
  }

  /** 非极大值抑制（按类别分别进行） */
  private nms(cands: Candidate[]): Candidate[] {
    const kept: Candidate[] = [];
    const suppressed: boolean[] = new Array<boolean>(cands.length).fill(false);

    for (let i = 0; i < cands.length; i++) {
      if (suppressed[i]) {
        continue;
      }
      const a = cands[i];
      kept.push(a);

      for (let j = i + 1; j < cands.length; j++) {
        if (suppressed[j]) {
          continue;
        }
        const b = cands[j];
        // 只对同类做抑制
        if (a.cls !== b.cls) {
          continue;
        }
        if (this.iou(a, b) > IOU_THRESHOLD) {
          suppressed[j] = true;
        }
      }
      if (kept.length >= MAX_DETECTIONS) {
        break;
      }
    }
    return kept;
  }

  /** 计算两个框的 IoU（坐标为归一化的 x,y,w,h） */
  private iou(a: Candidate, b: Candidate): number {
    const ax2: number = a.x + a.w;
    const ay2: number = a.y + a.h;
    const bx2: number = b.x + b.w;
    const by2: number = b.y + b.h;

    const ix1: number = Math.max(a.x, b.x);
    const iy1: number = Math.max(a.y, b.y);
    const ix2: number = Math.min(ax2, bx2);
    const iy2: number = Math.min(ay2, by2);

    const iw: number = ix2 - ix1;
    const ih: number = iy2 - iy1;
    if (iw <= 0 || ih <= 0) {
      return 0;
    }
    const inter: number = iw * ih;
    const union: number = a.w * a.h + b.w * b.h - inter;
    return union > 0 ? inter / union : 0;
  }

  // ────────────────────────────────────────────────────────────────

  // ────────────────────────────────────────────────────────────────
  // 基准测试接口（供 BenchRunner 调用）
  // ────────────────────────────────────────────────────────────────

  /**
   * 准备固定输入：解码一次图片并缓存成 [1,3,320,320] float32。
   *
   * 为什么要缓存：预热曲线 / 稳态 / 空闲扫描要测的是【纯推理】。
   * 若每次都走 detect()，两次 predict 之间会夹进解码与 RGBA→NCHW 转换，
   * 测出来的就不再是纯推理，也无法与「只测 predict」的口径对齐。
   */
  async prepareBenchInput(uri: string): Promise<boolean> {
    if (this.model === undefined) {
      return false;
    }
    let src: image.ImageSource | undefined = undefined;
    let pm: image.PixelMap | undefined = undefined;
    let file: fileIo.File | undefined = undefined;
    try {
      file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      src = image.createImageSource(file.fd);
      const opts: image.DecodingOptions = {
        desiredSize: { width: MODEL_SIZE, height: MODEL_SIZE },
        editable: false,
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888
      };
      pm = await src.createPixelMap(opts);
      this.benchInput = await this.toModelInput(pm);
      return true;
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'prepareBenchInput 失败: %{public}s', e.message);
      return false;
    } finally {
      if (pm !== undefined) {
        try {
          await pm.release();
        } catch (e) {
          // 忽略
        }
      }
      if (src !== undefined) {
        try {
          await src.release();
        } catch (e) {
          // 忽略
        }
      }
      if (file !== undefined) {
        try {
          fileIo.closeSync(file);
        } catch (e) {
          // 忽略
        }
      }
    }
  }

  /**
   * 用缓存输入跑一次 predict，返回【纯推理】耗时（ms）。
   * 未准备输入、或拿不到输入张量时返回 -1。
   */
  async benchInfer(): Promise<number> {
    if (this.model === undefined || this.benchInput === undefined) {
      return -1;
    }
    const inputs: mindSporeLite.MSTensor[] | undefined = this.model.getInputs();
    if (inputs === undefined || inputs.length === 0) {
      return -1;
    }
    inputs[0].setData(this.benchInput);   // 喂数据不计入计时（两后端一致，不偏袒任一方）
    const t: number = this.nowMs();
    await this.model.predict(inputs);
    return this.nowMs() - t;
  }

  /**
   * 同 benchInfer，但计时窗**包含读取输出张量**（getData()）。
   *
   * 为什么需要它：`predict()` 返回 Promise，若它在 NPU 真正算完之前就 resolve，
   * 那么 benchInfer 测到的只是"派发耗时"，会系统性低估真实推理成本。
   * 两条口径都测，差值即"派发与完成之间"的隐藏成本；若两者接近，说明计时可信。
   */
  async benchInferWithOutput(): Promise<number> {
    if (this.model === undefined || this.benchInput === undefined) {
      return -1;
    }
    const inputs: mindSporeLite.MSTensor[] | undefined = this.model.getInputs();
    if (inputs === undefined || inputs.length === 0) {
      return -1;
    }
    inputs[0].setData(this.benchInput);
    const t: number = this.nowMs();
    const outputs: mindSporeLite.MSTensor[] = await this.model.predict(inputs);
    if (outputs !== undefined && outputs.length > 0) {
      const data: ArrayBuffer = outputs[0].getData();   // 真正物化输出（含同步等待）
      if (data.byteLength === 0) {
        return -1;
      }
    }
    return this.nowMs() - t;
  }

  async release(): Promise<void> {
    this.model = undefined;
    this.benchInput = undefined;
    this.ready = false;
  }
}

/** 类别英文名（索引与训练时一致） */
const CLASS_NAMES: string[] = [
  'crazing',
  'inclusion',
  'patches',
  'pitted_surface',
  'rolled-in_scale',
  'scratches'
];

/** 类别中文名 */
const CLASS_NAMES_CN: string[] = [
  '裂纹',
  '夹杂物',
  '斑块',
  '麻点',
  '氧化铁皮压入',
  '划痕'
];
