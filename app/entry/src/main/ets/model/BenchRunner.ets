/**
 * 端侧推理基准测试套件 v2（一键跑，输出走 hilog，TAG = STEELQC_BENCH）
 *
 * ────────────────────────────────────────────────────────────────────
 * v2 相对 v1 的增强（全部由 v1 的数据分析倒推出来）
 * ────────────────────────────────────────────────────────────────────
 *   1. convertMs 拆两段：readback（像素回读） / loop（逐像素循环）
 *      —— v1 的 21 ms 是两个来源混在一起的，不拆就不知道该优化哪一段
 *   2. 前处理 3 种实现 A/B（原实现 / Uint32+位运算+乘法 / 查表）
 *      —— 同一版里直接比，省掉"改一版测一次"的两轮会话
 *   3. 纳秒时钟（systemDateTime.getTime(true)）：v1 用 Date.now()，对 4 ms 级
 *      测量有 ±25% 量化误差
 *   4. 输出读取口径对照：只等 Promise vs 读输出张量 → 判定 predict 是否"假快"
 *   5. 空闲扫描每档 3 次取中位（v1 只有 1 个样本，cpu 曲线非单调无法判读）
 *   6. 端到端扩到 30 张（每类 5 张），v1 每类只有 1 张
 *   7. 大图端到端：设备上自造 1280×960 / 2560×1920 JPEG，量化"取图分辨率"的代价
 *   8. 批量吞吐 50 张：核对 README 的吞吐声明
 *   9. 会话内稳态复测：检验可重复性
 *
 * ────────────────────────────────────────────────────────────────────
 * 两种模式
 * ────────────────────────────────────────────────────────────────────
 *   完整（约 9 分钟）：P0–P11 全跑
 *   快速（约 1 分钟）：跳过空闲扫描 / 大图 / 批量 / 复测，只留核心对照
 *
 * ────────────────────────────────────────────────────────────────────
 * 口径纪律
 * ────────────────────────────────────────────────────────────────────
 *   · infer = 仅 model.predict()；e2e = detect() 全程；两者永不同框比较
 *   · 纯推理阶段共用同一份预解码输入（不把解码/转换混进去）
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { resourceManager } from '@kit.LocalizationKit';
import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { MindSporeLiteDetector } from './MindSporeLiteDetector';
import { Detection, DetectionResult } from './DefectType';

const DOMAIN: number = 0x0000;
const TAG: string = 'STEELQC_BENCH';

/** 固定测试图（内置图库中的一张，200×200） */
const FIXED_IMG: string = 'scratches_1.jpg';

const WARMUP_N: number = 10;
const STEADY_N: number = 50;
const BLOCK_N: number = 20;
const BLOCK_ROUNDS: number = 3;
const IDLE_GAPS: number[] = [0.5, 2, 5, 10, 30, 60];
const IDLE_REPEAT: number = 3;
const CONS_PER_CLASS: number = 5;
const E2E_PER_CLASS: number = 5;
const CPU_THREAD_SET: number[] = [2, 4, 8];
const VARIANTS: number[] = [0, 1, 2];
const VAR_N: number = 20;
const OUTREAD_N: number = 5;
const BIG_IMAGES: string[] = ['1280x960', '2560x1920'];
const BIG_N: number = 5;
const CLASSES: string[] = ['crazing', 'inclusion', 'patches', 'pitted_surface', 'rolled-in_scale', 'scratches'];

export interface BenchProgress {
  phase: string;
  detail: string;
  line: string;
}

export class BenchRunner {
  private mgr: resourceManager.ResourceManager;
  private filesDir: string;
  private notify: (p: BenchProgress) => void;
  private stopped: boolean = false;
  private nnrt: MindSporeLiteDetector | undefined = undefined;
  private cpu: MindSporeLiteDetector | undefined = undefined;
  private fixedUri: string = '';

  constructor(mgr: resourceManager.ResourceManager, filesDir: string,
              notify: (p: BenchProgress) => void) {
    this.mgr = mgr;
    this.filesDir = filesDir;
    this.notify = notify;
  }

  /** 请求停止（下一次循环边界生效） */
  stop(): void {
    this.stopped = true;
  }

  // ──────────────────────────── 基础设施 ────────────────────────────

  private log(msg: string, phase: string = '', detail: string = ''): void {
    hilog.info(DOMAIN, TAG, '%{public}s', msg);
    this.notify({ phase: phase, detail: detail, line: msg });
  }

  private async sleep(ms: number): Promise<void> {
    await new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  /** 统计摘要（毫秒保留两位小数；中位数取上中位，偶数样本时如此约定） */
  private stat(values: number[]): string {
    const v: number[] = values.filter((x: number) => x >= 0).sort((a: number, b: number) => a - b);
    if (v.length === 0) {
      return 'n=0';
    }
    let sum: number = 0;
    for (let i = 0; i < v.length; i++) {
      sum += v[i];
    }
    const med: number = v[Math.floor(v.length / 2)];
    return `n=${v.length} min=${v[0].toFixed(2)} med=${med.toFixed(2)}`
      + ` max=${v[v.length - 1].toFixed(2)} mean=${(sum / v.length).toFixed(2)}`;
  }

  private median(values: number[]): number {
    const v: number[] = values.filter((x: number) => x >= 0).sort((a: number, b: number) => a - b);
    if (v.length === 0) {
      return -1;
    }
    return v[Math.floor(v.length / 2)];
  }

  private fmt(values: number[]): string {
    const parts: string[] = [];
    for (let i = 0; i < values.length; i++) {
      parts.push(values[i].toFixed(2));
    }
    return parts.join(',');
  }

  /** 把 rawfile 图落盘到沙箱并返回 file:// URI（重复调用只写一次） */
  private async localize(name: string): Promise<string> {
    const p: string = `${this.filesDir}/bench_${name}`;
    if (fileIo.accessSync(p)) {
      return 'file://' + p;
    }
    const bytes: Uint8Array = await this.mgr.getRawFileContent('neuimg/' + name);
    const f = fileIo.openSync(p, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(f.fd, bytes.buffer as ArrayBuffer);
    } finally {
      fileIo.closeSync(f);
    }
    return 'file://' + p;
  }

  /**
   * 设备上自造大图：把小图放大后重新编码成 JPEG。
   *
   * 为什么需要：包内只有 200×200 的图，而真实拍照是数兆像素 ——
   * 解码与缩放的代价完全不可比。这里用"放大 + 重编码"造出真实分辨率的大图：
   * **分辨率是真的**（JPEG 解码开销随分辨率增长），内容清晰与否不影响计时。
   */
  private async makeLargeJpeg(srcUri: string, w: number, h: number): Promise<string> {
    const p: string = `${this.filesDir}/bench_big_${w}x${h}.jpg`;
    if (fileIo.accessSync(p)) {
      return 'file://' + p;
    }
    let src: image.ImageSource | undefined = undefined;
    let pm: image.PixelMap | undefined = undefined;
    const file = fileIo.openSync(srcUri, fileIo.OpenMode.READ_ONLY);
    try {
      src = image.createImageSource(file.fd);
      const opts: image.DecodingOptions = {
        desiredSize: { width: w, height: h },
        editable: false,
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888
      };
      pm = await src.createPixelMap(opts);
      const packer: image.ImagePacker = image.createImagePacker();
      const packOpts: image.PackingOption = { format: 'image/jpeg', quality: 90 };
      const buf: ArrayBuffer = await packer.packing(pm, packOpts);
      const out = fileIo.openSync(p, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(out.fd, buf);
      } finally {
        fileIo.closeSync(out);
      }
      await packer.release();
      this.log(`BIGMAKE ${w}x${h} bytes=${buf.byteLength}`);
      return 'file://' + p;
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
      try {
        fileIo.closeSync(file);
      } catch (e) {
        // 忽略
      }
    }
  }

  private boxesToString(boxes: Detection[]): string {
    if (boxes.length === 0) {
      return 'none';
    }
    const parts: string[] = [];
    for (let i = 0; i < boxes.length && i < 4; i++) {
      const b: Detection = boxes[i];
      parts.push(`${b.type}:${b.confidence.toFixed(2)}:${b.x.toFixed(2)},${b.y.toFixed(2)},`
        + `${b.w.toFixed(2)},${b.h.toFixed(2)}`);
    }
    return parts.join(' | ');
  }

  // ──────────────────────────── 主流程 ────────────────────────────

  async run(quick: boolean = false): Promise<void> {
    this.stopped = false;
    this.log(`=== BENCH BEGIN === mode=${quick ? 'quick' : 'full'}`);
    this.log(`ENV chip=${String(deviceInfo.chipType)} model=${String(deviceInfo.productModel)}`
      + ` os=${String(deviceInfo.osFullName)} api=${String(deviceInfo.sdkApiVersion)}`);
    try {
      this.fixedUri = await this.localize(FIXED_IMG);
      this.log(`FIXED img=${FIXED_IMG}`);

      // ── P1 双后端初始化（强制指定，不回退）──
      this.notify({ phase: 'P1 初始化', detail: '加载 nnrt 后端', line: '' });
      this.nnrt = new MindSporeLiteDetector(this.mgr, 'nnrt');
      let t: number = Date.now();
      const okNpu: boolean = await this.nnrt.init();
      this.log(`INIT backend=nnrt ok=${okNpu} initMs=${Date.now() - t}`);

      this.notify({ phase: 'P1 初始化', detail: '加载 cpu 后端', line: '' });
      this.cpu = new MindSporeLiteDetector(this.mgr, 'cpu');
      t = Date.now();
      const okCpu: boolean = await this.cpu.init();
      this.log(`INIT backend=cpu ok=${okCpu} initMs=${Date.now() - t}`);

      if (!okNpu || !okCpu) {
        this.log('ABORT 后端初始化失败，后续测试无意义');
        this.log('=== BENCH END ===');
        return;
      }

      const pNpu: boolean = await this.nnrt.prepareBenchInput(this.fixedUri);
      const pCpu: boolean = await this.cpu.prepareBenchInput(this.fixedUri);
      this.log(`BENCHINPUT nnrt=${pNpu} cpu=${pCpu}`);
      if (!pNpu || !pCpu) {
        this.log('ABORT 固定输入准备失败');
        this.log('=== BENCH END ===');
        return;
      }

      // ── P2 预热曲线（逐次记录，不丢弃）──
      await this.warmup('nnrt', this.nnrt);
      await this.warmup('cpu', this.cpu);

      // ── P2b 输出读取口径对照 ──
      await this.outreadCheck('nnrt', this.nnrt);
      await this.outreadCheck('cpu', this.cpu);

      // ── P3 稳态 ──
      await this.steady('nnrt', this.nnrt);
      await this.steady('cpu', this.cpu);

      // ── P4 空闲间隔扫描（快速模式跳过）──
      if (!quick) {
        for (let i = 0; i < IDLE_GAPS.length; i++) {
          if (this.stopped) {
            break;
          }
          await this.idleSweep('nnrt', this.nnrt, IDLE_GAPS[i]);
          await this.idleSweep('cpu', this.cpu, IDLE_GAPS[i]);
        }
      }

      // ── P5 交错块（ABABAB）──
      for (let r = 1; r <= BLOCK_ROUNDS; r++) {
        if (this.stopped) {
          break;
        }
        await this.block('nnrt', this.nnrt, r);
        await this.block('cpu', this.cpu, r);
      }

      // ── P6 端到端分段（每类 5 张，共 30 张）──
      if (!this.stopped) {
        await this.e2eSegments();
      }

      // ── P6b 前处理实现变体 A/B（同机同输入交错）──
      if (!this.stopped) {
        await this.convertVariants();
      }

      // ── P7 后端一致性（30 张）──
      if (!this.stopped) {
        await this.consistency();
      }

      // ── P8 CPU 线程扫描 ──
      if (!this.stopped) {
        await this.threadSweep();
      }

      // ── P9 大图 / P10 批量吞吐 / P11 稳态复测（快速模式跳过）──
      if (!quick && !this.stopped) {
        await this.largeImages();
      }
      if (!quick && !this.stopped) {
        await this.batchThroughput();
      }
      if (!quick && !this.stopped) {
        await this.steady('nnrt', this.nnrt, 'REPEAT');
        await this.steady('cpu', this.cpu, 'REPEAT');
      }
    } catch (err) {
      const e = err as BusinessError;
      this.log(`ERROR 套件异常中断: ${e.message}`);
    }
    this.log('=== BENCH END ===', '结束', '');
  }

  // ──────────────────────────── 各阶段 ────────────────────────────

  /** P2：预热曲线，逐次记录 */
  private async warmup(tag: string, det: MindSporeLiteDetector): Promise<void> {
    const values: number[] = [];
    for (let i = 1; i <= WARMUP_N; i++) {
      if (this.stopped) {
        return;
      }
      const ms: number = await det.benchInfer();
      values.push(ms);
      this.log(`WARM ${tag} i=${i} infer=${ms.toFixed(2)}`, 'P2 预热', `${tag} ${i}/${WARMUP_N}`);
    }
    this.log(`WARMSUM ${tag} values=${this.fmt(values)}`);
  }

  /** P2b：只等 Promise vs 读输出张量 —— 判定 predict 是否"真算完才 resolve" */
  private async outreadCheck(tag: string, det: MindSporeLiteDetector): Promise<void> {
    const plain: number[] = [];
    const withOut: number[] = [];
    for (let i = 0; i < OUTREAD_N; i++) {
      if (this.stopped) {
        return;
      }
      plain.push(await det.benchInfer());
      withOut.push(await det.benchInferWithOutput());
      this.notify({ phase: 'P2b 口径对照', detail: `${tag} ${i + 1}/${OUTREAD_N}`, line: '' });
    }
    this.log(`OUTREAD ${tag} kind=plain n=${OUTREAD_N} med=${this.median(plain).toFixed(2)}`);
    this.log(`OUTREAD ${tag} kind=withOutput n=${OUTREAD_N} med=${this.median(withOut).toFixed(2)}`);
  }

  /** P3 / P11：稳态（prefix=REPEAT 表示会话内复测） */
  private async steady(tag: string, det: MindSporeLiteDetector, prefix: string = 'STEADY'): Promise<void> {
    const values: number[] = [];
    for (let i = 1; i <= STEADY_N; i++) {
      if (this.stopped) {
        return;
      }
      values.push(await det.benchInfer());
      this.notify({
        phase: prefix === 'REPEAT' ? 'P11 复测' : 'P3 稳态',
        detail: `${tag} ${i}/${STEADY_N}`, line: ''
      });
    }
    this.log(`${prefix} ${tag} ${this.stat(values)}`);
    this.log(`${prefix}RAW ${tag} values=${this.fmt(values)}`);
  }

  /** P4：某档间隔重复 IDLE_REPEAT 次，报单次与中位 */
  private async idleSweep(tag: string, det: MindSporeLiteDetector, gapSec: number): Promise<void> {
    const values: number[] = [];
    for (let k = 1; k <= IDLE_REPEAT; k++) {
      this.notify({ phase: 'P4 空闲扫描', detail: `${tag} 档 ${gapSec}s 第 ${k}/${IDLE_REPEAT} 次（等待中）`, line: '' });
      await this.sleep(Math.round(gapSec * 1000));
      if (this.stopped) {
        return;
      }
      const ms: number = await det.benchInfer();
      values.push(ms);
      this.log(`IDLE ${tag} gapSec=${gapSec} iter=${k} infer=${ms.toFixed(2)}`,
        'P4 空闲扫描', `${tag} gap=${gapSec}s ${k}/${IDLE_REPEAT}`);
    }
    this.log(`IDLESUM ${tag} gapSec=${gapSec} n=${values.length} med=${this.median(values).toFixed(2)}`);
  }

  /** P5：交错块（每块 20 次连续推理） */
  private async block(tag: string, det: MindSporeLiteDetector, round: number): Promise<void> {
    const values: number[] = [];
    for (let i = 1; i <= BLOCK_N; i++) {
      if (this.stopped) {
        return;
      }
      values.push(await det.benchInfer());
      this.notify({ phase: 'P5 交错块', detail: `第${round}轮 ${tag} ${i}/${BLOCK_N}`, line: '' });
    }
    this.log(`BLOCK round=${round} ${tag} ${this.stat(values)} values=${this.fmt(values)}`);
  }

  /**
   * P6：端到端分段（每类 5 张，共 30 张）
   *
   * ⚠️ 2026-10-14 改动：**两个后端都测**。
   *   本项目的研究问题是"同一台机器上 NPU 是否实现了加速"，而产品真实用法是
   *   端到端（解码→转换→推理→NMS）。只测 nnrt 的 e2e 无法回答"换成 CPU 会慢多少"，
   *   所以这里对同一张图分别走 nnrt 与 cpu，各记一行分段，各自汇总。
   */
  private async e2eSegments(): Promise<void> {
    if (this.nnrt === undefined || this.cpu === undefined) {
      return;
    }
    const tags: string[] = ['nnrt', 'cpu'];
    for (let ti = 0; ti < tags.length; ti++) {
      const tag: string = tags[ti];
      const det: MindSporeLiteDetector = (tag === 'nnrt') ? this.nnrt : this.cpu;
      const dec: number[] = [];
      const rb: number[] = [];
      const lp: number[] = [];
      const inf: number[] = [];
      const nms: number[] = [];
      const tot: number[] = [];
      const cost: number[] = [];
      for (let c = 0; c < CLASSES.length; c++) {
        for (let k = 1; k <= E2E_PER_CLASS; k++) {
          if (this.stopped) {
            return;
          }
          const name: string = `${CLASSES[c]}_${k}.jpg`;
          this.notify({ phase: 'P6 端到端', detail: `${tag} ${name}`, line: '' });
          try {
            const uri: string = await this.localize(name);
            const r: DetectionResult = await det.detect(uri);
            const d: number = (r.decodeMs === undefined) ? -1 : r.decodeMs;
            const a: number = (r.readbackMs === undefined) ? -1 : r.readbackMs;
            const l: number = (r.loopMs === undefined) ? -1 : r.loopMs;
            const i: number = r.inferMs;
            const n: number = (r.nmsMs === undefined) ? -1 : r.nmsMs;
            const tt: number = r.costMs;
            dec.push(d);
            rb.push(a);
            lp.push(l);
            inf.push(i);
            nms.push(n);
            tot.push(tt);
            cost.push(tt);
            this.log(`E2E backend=${tag} img=${name} decode=${d.toFixed(2)} readback=${a.toFixed(2)}`
              + ` loop=${l.toFixed(2)} infer=${i.toFixed(2)} nms=${n.toFixed(2)}`
              + ` total=${tt.toFixed(2)} boxes=${r.boxes.length}`);
          } catch (err) {
            const e = err as BusinessError;
            this.log(`E2E backend=${tag} img=${name} FAILED ${e.message}`);
          }
        }
      }
      this.log(`E2ESUM backend=${tag} n=${tot.length} decode_med=${this.median(dec).toFixed(2)}`
        + ` readback_med=${this.median(rb).toFixed(2)} loop_med=${this.median(lp).toFixed(2)}`
        + ` infer_med=${this.median(inf).toFixed(2)} nms_med=${this.median(nms).toFixed(2)}`
        + ` total_med=${this.median(tot).toFixed(2)}`);
    }
  }

  /** P6b：前处理三种实现交错对比（同机、同输入、同图） */
  private async convertVariants(): Promise<void> {
    if (this.nnrt === undefined) {
      return;
    }
    const conv: number[][] = [[], [], []];
    const rb: number[][] = [[], [], []];
    const lp: number[][] = [[], [], []];
    for (let i = 0; i < VAR_N; i++) {
      for (let vi = 0; vi < VARIANTS.length; vi++) {
        if (this.stopped) {
          return;
        }
        const v: number = VARIANTS[vi];
        this.nnrt.setConvertVariant(v);
        try {
          const r: DetectionResult = await this.nnrt.detect(this.fixedUri);
          conv[vi].push((r.convertMs === undefined) ? -1 : r.convertMs);
          rb[vi].push((r.readbackMs === undefined) ? -1 : r.readbackMs);
          lp[vi].push((r.loopMs === undefined) ? -1 : r.loopMs);
        } catch (err) {
          const e = err as BusinessError;
          this.log(`VAR variant=${v} FAILED ${e.message}`);
        }
        this.notify({ phase: 'P6b 前处理变体', detail: `第 ${i + 1}/${VAR_N} 轮 变体${v}`, line: '' });
      }
    }
    this.nnrt.setConvertVariant(0);   // 复位，避免影响后续阶段
    for (let vi = 0; vi < VARIANTS.length; vi++) {
      this.log(`VAR variant=${VARIANTS[vi]} n=${conv[vi].length}`
        + ` convert_med=${this.median(conv[vi]).toFixed(2)}`
        + ` readback_med=${this.median(rb[vi]).toFixed(2)}`
        + ` loop_med=${this.median(lp[vi]).toFixed(2)}`);
    }
  }

  /** P7：两后端对同一批图的一致性（30 张） */
  private async consistency(): Promise<void> {
    if (this.nnrt === undefined || this.cpu === undefined) {
      return;
    }
    let mismatch: number = 0;
    let total: number = 0;
    for (let c = 0; c < CLASSES.length; c++) {
      for (let k = 1; k <= CONS_PER_CLASS; k++) {
        if (this.stopped) {
          return;
        }
        const name: string = `${CLASSES[c]}_${k}.jpg`;
        this.notify({ phase: 'P7 一致性', detail: name, line: '' });
        try {
          const uri: string = await this.localize(name);
          const a: DetectionResult = await this.nnrt.detect(uri);
          const b: DetectionResult = await this.cpu.detect(uri);
          total++;
          let same: boolean = a.boxes.length === b.boxes.length;
          for (let i = 0; i < a.boxes.length && same; i++) {
            if (a.boxes[i].type !== b.boxes[i].type) {
              same = false;
            }
          }
          if (!same) {
            mismatch++;
          }
          this.log(`CONS img=${name} same=${same}`
            + ` A=${this.boxesToString(a.boxes)} B=${this.boxesToString(b.boxes)}`);
        } catch (err) {
          const e = err as BusinessError;
          this.log(`CONS img=${name} FAILED ${e.message}`);
        }
      }
    }
    this.log(`CONSSUM images=${total} mismatch=${mismatch}`
      + ` rate=${total === 0 ? -1 : (mismatch / total).toFixed(3)}`);
  }

  /** P8：CPU 线程数敏感性 */
  private async threadSweep(): Promise<void> {
    for (let i = 0; i < CPU_THREAD_SET.length; i++) {
      if (this.stopped) {
        return;
      }
      const threads: number = CPU_THREAD_SET[i];
      this.notify({ phase: 'P8 线程', detail: `threads=${threads} 初始化`, line: '' });
      const det: MindSporeLiteDetector = new MindSporeLiteDetector(this.mgr, 'cpu');
      det.setCpuThreads(threads);
      const ok: boolean = await det.init();
      if (!ok) {
        this.log(`THREAD threads=${threads} initFailed`);
        continue;
      }
      if (!await det.prepareBenchInput(this.fixedUri)) {
        this.log(`THREAD threads=${threads} inputFailed`);
        continue;
      }
      const values: number[] = [];
      for (let k = 1; k <= BLOCK_N; k++) {
        if (this.stopped) {
          return;
        }
        values.push(await det.benchInfer());
        this.notify({ phase: 'P8 线程', detail: `threads=${threads} ${k}/${BLOCK_N}`, line: '' });
      }
      this.log(`THREAD threads=${threads} ${this.stat(values)} values=${this.fmt(values)}`);
      await det.release();
    }
  }

  /** P9：大图端到端（设备自造 JPEG，量化取图分辨率的代价） */
  private async largeImages(): Promise<void> {
    if (this.nnrt === undefined) {
      return;
    }
    for (let bi = 0; bi < BIG_IMAGES.length; bi++) {
      if (this.stopped) {
        return;
      }
      const spec: string = BIG_IMAGES[bi];
      const wh: string[] = spec.split('x');
      const w: number = Number.parseInt(wh[0], 10);
      const h: number = Number.parseInt(wh[1], 10);
      this.notify({ phase: 'P9 大图', detail: `生成 ${spec}`, line: '' });
      let uri: string = '';
      try {
        uri = await this.makeLargeJpeg(this.fixedUri, w, h);
      } catch (err) {
        const e = err as BusinessError;
        this.log(`BIG img=${spec} MAKEFAILED ${e.message}`);
        continue;
      }
      const dec: number[] = [];
      const conv: number[] = [];
      const inf: number[] = [];
      const tot: number[] = [];
      for (let k = 1; k <= BIG_N; k++) {
        if (this.stopped) {
          return;
        }
        this.notify({ phase: 'P9 大图', detail: `${spec} ${k}/${BIG_N}`, line: '' });
        try {
          const r: DetectionResult = await this.nnrt.detect(uri);
          dec.push((r.decodeMs === undefined) ? -1 : r.decodeMs);
          conv.push((r.convertMs === undefined) ? -1 : r.convertMs);
          inf.push(r.inferMs);
          tot.push(r.costMs);
        } catch (err) {
          const e = err as BusinessError;
          this.log(`BIG img=${spec} FAILED ${e.message}`);
        }
      }
      this.log(`BIG img=${spec} n=${tot.length} decode_med=${this.median(dec).toFixed(2)}`
        + ` convert_med=${this.median(conv).toFixed(2)} infer_med=${this.median(inf).toFixed(2)}`
        + ` total_med=${this.median(tot).toFixed(2)}`);
    }
  }

  /** P10：批量吞吐（连续 50 张端到端，核对 README 的吞吐声明） */
  private async batchThroughput(): Promise<void> {
    if (this.nnrt === undefined) {
      return;
    }
    const names: string[] = [];
    for (let c = 0; c < CLASSES.length; c++) {
      for (let k = 1; k <= 8; k++) {
        names.push(`${CLASSES[c]}_${k}.jpg`);
      }
    }
    names.push(`${CLASSES[0]}_9.jpg`);
    names.push(`${CLASSES[0]}_10.jpg`);

    // 文件准备不计入计时（localize 只写一次，重复调用直接返回）
    const uris: string[] = [];
    for (let i = 0; i < names.length; i++) {
      if (this.stopped) {
        return;
      }
      uris.push(await this.localize(names[i]));
      this.notify({ phase: 'P10 批量', detail: `准备文件 ${i + 1}/${names.length}`, line: '' });
    }

    const t0: number = Date.now();
    let ok: number = 0;
    for (let i = 0; i < uris.length; i++) {
      if (this.stopped) {
        return;
      }
      try {
        await this.nnrt.detect(uris[i]);
        ok++;
      } catch (err) {
        const e = err as BusinessError;
        this.log(`BATCH item=${names[i]} FAILED ${e.message}`);
      }
      this.notify({ phase: 'P10 批量', detail: `${i + 1}/${uris.length}`, line: '' });
    }
    const totalMs: number = Date.now() - t0;
    this.log(`BATCH n=${ok} totalMs=${totalMs} avgMs=${(totalMs / Math.max(1, ok)).toFixed(2)}`
      + ` perSec=${(ok * 1000 / Math.max(1, totalMs)).toFixed(2)}`);
  }
}
