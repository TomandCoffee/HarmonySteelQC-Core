/**
 * 端侧推理基准测试套件（一键跑，输出走 hilog，TAG = STEELQC_BENCH）
 *
 * ────────────────────────────────────────────────────────────────────
 * 为什么要有它
 * ────────────────────────────────────────────────────────────────────
 * 手点「重新检测」测不出可信数据：
 *   · 掐不准间隔（而实测表明"距上次推理多久"直接决定耗时：0.7 s → 4~6 ms，
 *     10~18 s → 14~16 ms，2.7 min → 71 ms，设备首次 → 413 ms）
 *   · 单次样本无法区分"稳态"与"离群"
 *   · 两个后端必须吃**同一份输入**、且在**同一台设备同一进程**内交错测，
 *     否则又是跨口径 / 跨设备比较（本项目已经栽过两次）
 *
 * ────────────────────────────────────────────────────────────────────
 * 测什么（按顺序，约 4 分钟）
 * ────────────────────────────────────────────────────────────────────
 *   P0 环境     ：机型 / API / 模型字节数
 *   P1 后端初始化：nnrt 与 cpu 各起一个模型实例，各自报告 backend 名与初始化耗时
 *   P2 预热曲线 ：各 10 次连续推理，**逐次**记录（不丢弃 —— 冷启动本身是指标）
 *   P3 稳态     ：各 50 次连续推理（记录全部原始值 + min/med/max/mean）
 *   P4 空闲扫描 ：间隔 0.5 / 2 / 5 / 10 / 30 / 60 秒后各推理一次（产品真实节奏）
 *   P5 交错块   ：ABABAB 各 3 轮 × 20 次（抗热漂移，配对比较用）
 *   P6 端到端分段：6 张图（每类 1 张）拆 decode / convert / infer / nms 四段
 *   P7 后端一致性：每类 5 张共 30 张，两后端各跑一次，逐框比对
 *   P8 CPU 线程 ：2 / 4 / 8 线程各 20 次（配置敏感性）
 *
 * ────────────────────────────────────────────────────────────────────
 * 口径纪律（写在代码里，避免以后又混）
 * ────────────────────────────────────────────────────────────────────
 *   · infer  = 仅 model.predict() 的耗时（纯推理）
 *   · e2e    = detect() 全程（解码+缩放+转 NCHW+推理+NMS）
 *   · 两者永不同框比较；P2/P3/P4/P5 全是纯推理，P6 才是分段/端到端
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { resourceManager } from '@kit.LocalizationKit';
import { fileIo } from '@kit.CoreFileKit';
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
const CPU_THREAD_SET: number[] = [2, 4, 8];
const CONS_PER_CLASS: number = 5;
const CLASSES: string[] = ['crazing', 'inclusion', 'patches', 'pitted_surface', 'rolled-in_scale', 'scratches'];

export interface BenchProgress {
  /** 阶段名，如 'P3 稳态' */
  phase: string;
  /** 当前明细，如 'nnrt 23/50' */
  detail: string;
  /** 本条日志原文（界面可滚动显示，便于截图） */
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

  /** 统计摘要（中位数取上中位，样本量为偶数时如此约定） */
  private stat(values: number[]): string {
    if (values.length === 0) {
      return 'n=0';
    }
    const sorted: number[] = values.slice().sort((a: number, b: number) => a - b);
    let sum: number = 0;
    for (let i = 0; i < values.length; i++) {
      sum += values[i];
    }
    const med: number = sorted[Math.floor(sorted.length / 2)];
    return `n=${values.length} min=${sorted[0]} med=${med} max=${sorted[sorted.length - 1]}`
      + ` mean=${(sum / values.length).toFixed(1)}`;
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

  async run(): Promise<void> {
    this.stopped = false;
    this.log('=== BENCH BEGIN ===', '启动', '');
    this.log(`ENV chip=${String(deviceInfo.chipType)} model=${String(deviceInfo.productModel)}`
      + ` os=${String(deviceInfo.osFullName)} api=${String(deviceInfo.sdkApiVersion)}`);
    try {
      this.fixedUri = await this.localize(FIXED_IMG);
      this.log(`FIXED img=${FIXED_IMG}`);

      // ── P1 后端初始化 ──
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

      // ── P2 预热曲线 ──
      await this.warmup('nnrt', this.nnrt);
      await this.warmup('cpu', this.cpu);

      // ── P3 稳态 ──
      await this.steady('nnrt', this.nnrt);
      await this.steady('cpu', this.cpu);

      // ── P4 空闲间隔扫描 ──
      for (let i = 0; i < IDLE_GAPS.length; i++) {
        if (this.stopped) { break; }
        await this.idle('nnrt', this.nnrt, IDLE_GAPS[i]);
        await this.idle('cpu', this.cpu, IDLE_GAPS[i]);
      }

      // ── P5 交错块（ABABAB）──
      for (let r = 1; r <= BLOCK_ROUNDS; r++) {
        if (this.stopped) { break; }
        await this.block('nnrt', this.nnrt, r);
        await this.block('cpu', this.cpu, r);
      }

      // ── P6 端到端分段 ──
      if (!this.stopped) {
        await this.e2eSegments();
      }

      // ── P7 后端一致性 ──
      if (!this.stopped) {
        await this.consistency();
      }

      // ── P8 CPU 线程敏感性 ──
      if (!this.stopped) {
        await this.threadSweep();
      }
    } catch (err) {
      const e = err as BusinessError;
      this.log(`ERROR 套件异常中断: ${e.message}`);
    }
    this.log('=== BENCH END ===', '结束', '');
  }

  // ──────────────────────────── 各阶段实现 ────────────────────────────

  /** P2：预热曲线，逐次记录 */
  private async warmup(tag: string, det: MindSporeLiteDetector): Promise<void> {
    const values: number[] = [];
    for (let i = 1; i <= WARMUP_N; i++) {
      if (this.stopped) { return; }
      const ms: number = await det.benchInfer();
      values.push(ms);
      this.log(`WARM ${tag} i=${i} infer=${ms}`, 'P2 预热', `${tag} ${i}/${WARMUP_N}`);
    }
    this.log(`WARMSUM ${tag} values=${values.join(',')}`);
  }

  /** P3：稳态，记录全部原始值 */
  private async steady(tag: string, det: MindSporeLiteDetector): Promise<void> {
    const values: number[] = [];
    for (let i = 1; i <= STEADY_N; i++) {
      if (this.stopped) { return; }
      values.push(await det.benchInfer());
      this.notify({ phase: 'P3 稳态', detail: `${tag} ${i}/${STEADY_N}`, line: '' });
    }
    this.log(`STEADY ${tag} ${this.stat(values)}`);
    this.log(`STEADYRAW ${tag} values=${values.join(',')}`);
  }

  /** P4：空闲 gap 秒后推理一次 */
  private async idle(tag: string, det: MindSporeLiteDetector, gapSec: number): Promise<void> {
    this.notify({ phase: 'P4 空闲扫描', detail: `${tag} 等待 ${gapSec}s`, line: '' });
    await this.sleep(Math.round(gapSec * 1000));
    if (this.stopped) { return; }
    const ms: number = await det.benchInfer();
    this.log(`IDLE ${tag} gapSec=${gapSec} infer=${ms}`, 'P4 空闲扫描', `${tag} gap=${gapSec}s`);
  }

  /** P5：交错块，一次 20 次连续推理 */
  private async block(tag: string, det: MindSporeLiteDetector, round: number): Promise<void> {
    const values: number[] = [];
    for (let i = 1; i <= BLOCK_N; i++) {
      if (this.stopped) { return; }
      values.push(await det.benchInfer());
      this.notify({ phase: 'P5 交错块', detail: `第${round}轮 ${tag} ${i}/${BLOCK_N}`, line: '' });
    }
    this.log(`BLOCK round=${round} ${tag} ${this.stat(values)} values=${values.join(',')}`);
  }

  /** P6：端到端分段（每类 1 张，用 nnrt） */
  private async e2eSegments(): Promise<void> {
    if (this.nnrt === undefined) { return; }
    for (let c = 0; c < CLASSES.length; c++) {
      if (this.stopped) { return; }
      const name: string = `${CLASSES[c]}_1.jpg`;
      this.notify({ phase: 'P6 端到端', detail: name, line: '' });
      try {
        const uri: string = await this.localize(name);
        const res: DetectionResult = await this.nnrt.detect(uri);
        const decode: number = (res.decodeMs === undefined) ? -1 : res.decodeMs;
        const convert: number = (res.convertMs === undefined) ? -1 : res.convertMs;
        const nms: number = (res.nmsMs === undefined) ? -1 : res.nmsMs;
        this.log(`E2E img=${name} decode=${decode} convert=${convert} infer=${res.inferMs}`
          + ` nms=${nms} total=${res.costMs} boxes=${res.boxes.length}`);
      } catch (err) {
        const e = err as BusinessError;
        this.log(`E2E img=${name} FAILED ${e.message}`);
      }
    }
  }

  /** P7：两后端对同一批图的一致性 */
  private async consistency(): Promise<void> {
    if (this.nnrt === undefined || this.cpu === undefined) { return; }
    let mismatch: number = 0;
    let totalImages: number = 0;
    for (let c = 0; c < CLASSES.length; c++) {
      for (let k = 1; k <= CONS_PER_CLASS; k++) {
        if (this.stopped) { return; }
        const name: string = `${CLASSES[c]}_${k}.jpg`;
        this.notify({ phase: 'P7 一致性', detail: name, line: '' });
        try {
          const uri: string = await this.localize(name);
          const a: DetectionResult = await this.nnrt.detect(uri);
          const b: DetectionResult = await this.cpu.detect(uri);
          totalImages++;
          const sameCount: boolean = a.boxes.length === b.boxes.length;
          let sameCls: boolean = sameCount;
          for (let i = 0; i < a.boxes.length && sameCls; i++) {
            if (a.boxes[i].type !== b.boxes[i].type) {
              sameCls = false;
            }
          }
          const ok: boolean = sameCount && sameCls;
          if (!ok) {
            mismatch++;
          }
          this.log(`CONS img=${name} same=${ok}`
            + ` A=${this.boxesToString(a.boxes)} B=${this.boxesToString(b.boxes)}`);
        } catch (err) {
          const e = err as BusinessError;
          this.log(`CONS img=${name} FAILED ${e.message}`);
        }
      }
    }
    this.log(`CONSSUM images=${totalImages} mismatch=${mismatch}`
      + ` rate=${totalImages === 0 ? -1 : (mismatch / totalImages).toFixed(3)}`);
  }

  /** P8：CPU 线程数敏感性 */
  private async threadSweep(): Promise<void> {
    for (let i = 0; i < CPU_THREAD_SET.length; i++) {
      if (this.stopped) { return; }
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
        if (this.stopped) { return; }
        values.push(await det.benchInfer());
        this.notify({ phase: 'P8 线程', detail: `threads=${threads} ${k}/${BLOCK_N}`, line: '' });
      }
      this.log(`THREAD threads=${threads} ${this.stat(values)} values=${values.join(',')}`);
      await det.release();
    }
  }
}
