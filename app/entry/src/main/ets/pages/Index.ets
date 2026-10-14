import { cameraPicker } from '@kit.CameraKit';
import { camera } from '@kit.CameraKit';
import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { MockDetector } from '../model/MockDetector';
import { MindSporeLiteDetector } from '../model/MindSporeLiteDetector';
import { resourceManager } from '@kit.LocalizationKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { picker, fileIo } from '@kit.CoreFileKit';
import { Detector } from '../model/Detector';
import { Detection, DetectionResult, BatchItem, ALL_DEFECT_TYPES, DEFECT_META, DefectMeta } from '../model/DefectType';

const DOMAIN: number = 0x0000;
const TAG: string = 'SteelQC';

/** 图片显示区域高度（vp） */
const CANVAS_HEIGHT: number = 320;

/** 单次批量识别的最大图片数 */
const BATCH_MAX: number = 10;

/**
 * 显示矩形：图片在容器内按 Contain 模式居中显示时实际占用的区域
 */
interface DisplayRect {
  left: number;
  top: number;
  width: number;
  height: number;
}

/** 内置图库的类别筛选项 */
interface GalleryClass {
  /** 显示名 */
  cn: string;
  /** 文件名前缀；空串 = 全部 */
  prefix: string;
}

/**
 * 内置图库的 LazyForEach 数据源 —— 1800 张 NEU-DET 图不能全量渲染，
 * 只按可视区懒加载。
 */
class GallerySource implements IDataSource {
  private items: string[] = [];

  setItems(list: string[]): void {
    this.items = list;
  }

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): string {
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
  }
}

/**
 * 打印设备指纹 —— 多机型 / AGC 云调试验证用。
 *
 * 为什么需要它：NPU 可用性取决于「平台」，而平台不能只看机型名。
 * 每在一台设备上跑一次，hilog 里就留下一条以 DEVIPROBE 开头的记录：
 *
 *   DEVIPROBE chip=... hw=... model=... os=... api=...
 *
 * 多测几台即可横向对照，回答「哪些平台开放 NPU」——
 * 这是结题报告里「边界测绘」那部分的数据来源。
 *
 * 抓取方式：
 *   hdc shell "hilog -x -L I" | Select-String DEVIPROBE
 */
function logDeviceFingerprint(): void {
  try {
    const parts: string[] = [];
    // chipType 自 API 21 起提供，直接给出芯片型号（本机型如 Kirin 9000WL）
    parts.push(`chip=${String(deviceInfo.chipType)}`);
    // hardwareModel 通常是单板/平台名（本机为 SH1TGRLM 一类的代号）
    parts.push(`hw=${String(deviceInfo.hardwareModel)}`);
    parts.push(`model=${String(deviceInfo.productModel)}`);
    parts.push(`alias=${String(deviceInfo.productModelAlias)}`);
    parts.push(`market=${String(deviceInfo.marketName)}`);
    parts.push(`series=${String(deviceInfo.productSeries)}`);
    parts.push(`sw=${String(deviceInfo.softwareModel)}`);
    parts.push(`os=${String(deviceInfo.osFullName)}`);
    parts.push(`display=${String(deviceInfo.displayVersion)}`);
    parts.push(`api=${String(deviceInfo.sdkApiVersion)}`);
    parts.push(`type=${String(deviceInfo.deviceType)}`);
    parts.push(`patch=${String(deviceInfo.securityPatchTag)}`);
    hilog.info(DOMAIN, TAG, 'DEVIPROBE %{public}s', parts.join(' '));
  } catch (err) {
    const e = err as BusinessError;
    hilog.error(DOMAIN, TAG, 'DEVIPROBE 读取设备信息失败: %{public}s', e.message);
  }
}

@Entry
@Component
struct Index {
  // ---------- 状态 ----------
  @State imageUri: string = '';
  @State detecting: boolean = false;
  @State statusText: string = '选择图片后自动识别钢材表面缺陷';
  @State boxes: Detection[] = [];
  @State costMs: number = 0;
  @State backend: string = 'Mock';
  @State imgWidth: number = 0;
  @State imgHeight: number = 0;
  @State history: string[] = [];
  @State containerW: number = 0;
  @State containerH: number = 0;

  // ---------- 批量识别状态 ----------
  /** 'single' = 单张详情；'batch' = 批量列表 */
  @State viewMode: string = 'single';
  /** 批量检测结果 */
  @State batchItems: BatchItem[] = [];
  /** 批量进度提示，如 "正在识别 3/10" */
  @State batchProgress: string = '';
  /** 批量是否进行中 */
  @State batchRunning: boolean = false;

  // ---------- 内置图库状态（NEU-DET 全量 1800 张，随 HAP 分发） ----------
  @State galleryOpen: boolean = false;
  /** 当前筛选类别（GALLERY_CLASSES 下标，0 = 全部） */
  @State galleryClassIdx: number = 0;
  /** 全部图片名（自然排序后） */
  private allNeuNames: string[] = [];
  /** 图库懒加载数据源 */
  @State gallerySource: GallerySource = new GallerySource();
  /** 当前筛选下的数量（面板标题用） */
  @State galleryCount: number = 0;
  private galleryLoaded: boolean = false;
  /** 图库类别筛选项 */
  private readonly GALLERY_CLASSES: GalleryClass[] = [
    { cn: '全部', prefix: '' },
    { cn: '裂纹', prefix: 'crazing' },
    { cn: '夹杂物', prefix: 'inclusion' },
    { cn: '斑块', prefix: 'patches' },
    { cn: '麻点', prefix: 'pitted' },
    { cn: '氧化铁皮', prefix: 'rolled-in' },
    { cn: '划痕', prefix: 'scratches' }
  ];

  // ---------- 检测器 ----------
  // 默认使用模拟检测器，aboutToAppear 中会尝试换成真实的 MindSpore Lite 检测器。
  // 若模型加载失败（如设备不支持 NPU 且 CPU 也异常），则保留模拟器，
  // 保证界面始终可用，不会白屏。
  private detector: Detector = new MockDetector();
  /** 是否已切换到真实模型 */
  @State usingRealModel: boolean = false;
  /** 真实模型的加载状态说明，显示在界面上 */
  @State modelStatus: string = '正在加载模型…';

  // ---------- 生命周期 ----------
  aboutToAppear(): void {
    logDeviceFingerprint();
    // 加载真实模型（MindSpore Lite，优先 nnrt/NPU）；失败自动回退模拟检测器
    this.setupDetector();
  }


  /**
   * 优先加载真实模型（MindSpore Lite + NEU-DET 训练权重），
   * 失败时回退到模拟检测器，保证界面始终可用。
   */
  private async setupDetector(): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (ctx === undefined || ctx.resourceManager === undefined) {
        throw new Error('无法获取 resourceManager');
      }

      const real: MindSporeLiteDetector =
        new MindSporeLiteDetector(ctx.resourceManager as resourceManager.ResourceManager);

      this.modelStatus = '正在加载模型…';
      const ok: boolean = await real.init();

      if (ok) {
        this.detector = real;
        this.usingRealModel = true;
        this.modelStatus = '真实模型已就绪';
        hilog.info(DOMAIN, TAG, '已启用 MindSpore Lite 真实模型');
      } else {
        this.modelStatus = '模型加载失败，使用模拟数据';
        hilog.warn(DOMAIN, TAG, '真实模型加载失败，回退模拟检测器');
      }
    } catch (err) {
      const e = err as BusinessError;
      this.modelStatus = `模型加载异常，使用模拟数据：${e.message}`;
      hilog.error(DOMAIN, TAG, 'setupDetector 异常: %{public}s', e.message);
    }

    // 模拟器的 init（真实检测器已在 init 内完成加载）
    if (!this.usingRealModel) {
      try {
        await this.detector.init();
      } catch (err) {
        const e = err as BusinessError;
        hilog.error(DOMAIN, TAG, 'fallback init 失败: %{public}s', e.message);
      }
    }
  }

  aboutToDisappear(): void {
    this.detector.release();
  }

  // ---------- 内置测试图库（NEU-DET 1800 张，随 HAP 分发） ----------

  /** 从 rawfile 枚举全部图并自然排序（cra_1, cra_2 … 而非 cra_1, cra_10） */
  private sortNeuNames(list: string[]): string[] {
    const out: string[] = list.slice();
    out.sort((a: string, b: string): number => {
      const ai: number = a.indexOf('_');
      const bi: number = b.indexOf('_');
      const ap: string = (ai > 0) ? a.substring(0, ai) : a;
      const bp: string = (bi > 0) ? b.substring(0, bi) : b;
      if (ap !== bp) {
        return ap < bp ? -1 : 1;
      }
      const an: number = Number.parseInt(a.substring(ai + 1, a.indexOf('.')));
      const bn: number = Number.parseInt(b.substring(bi + 1, b.indexOf('.')));
      return an - bn;
    });
    return out;
  }

  private async loadGallery(): Promise<void> {
    if (this.galleryLoaded) {
      return;
    }
    this.galleryLoaded = true;
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const mgr = ctx.resourceManager as resourceManager.ResourceManager;
      const names: string[] = await mgr.getRawFileList('neuimg');
      this.allNeuNames = this.sortNeuNames(names);
      this.applyGalleryFilter();
      hilog.info(DOMAIN, TAG, '内置图库加载 %{public}d 张', this.allNeuNames.length);
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(DOMAIN, TAG, '内置图库加载失败: %{public}s', e.message);
      this.galleryLoaded = false;
    }
  }

  private applyGalleryFilter(): void {
    const prefix: string = this.GALLERY_CLASSES[this.galleryClassIdx].prefix;
    const filtered: string[] = [];
    for (let i = 0; i < this.allNeuNames.length; i++) {
      const n: string = this.allNeuNames[i];
      if (prefix === '' || n.startsWith(prefix + '_')) {
        filtered.push(n);
      }
    }
    this.galleryCount = filtered.length;
    // 换数据源对象触发 LazyForEach 全量刷新
    const src: GallerySource = new GallerySource();
    src.setItems(filtered);
    this.gallerySource = src;
  }

  /** 从 rawfile 落盘到沙箱并检测 */
  private async pickTestImage(name: string): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const mgr = ctx.resourceManager as resourceManager.ResourceManager;
      const bytes: Uint8Array = await mgr.getRawFileContent('neuimg/' + name);
      const p: string = ctx.filesDir + '/' + name;
      const f = fileIo.openSync(p,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(f.fd, bytes.buffer as ArrayBuffer);
      } finally {
        fileIo.closeSync(f);
      }
      this.galleryOpen = false;
      this.viewMode = 'single';
      this.batchItems = [];
      this.imageUri = 'file://' + p;
      this.boxes = [];
      await this.runDetect();
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(DOMAIN, TAG, '内置图库检测失败: %{public}s', e.message);
      this.statusText = `内置图库检测失败：${e.message}`;
    }
  }

  // ---------- 业务逻辑 ----------

  /** 调起系统相机拍照 */
  private async takePhoto(): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const profile: cameraPicker.PickerProfile = {
        cameraPosition: camera.CameraPosition.CAMERA_POSITION_BACK
      };
      const result: cameraPicker.PickerResult =
        await cameraPicker.pick(ctx, [cameraPicker.PickerMediaType.PHOTO], profile);

      if (result.resultCode !== 0) {
        this.statusText = '已取消拍照';
        return;
      }
      this.imageUri = result.resultUri;
      this.boxes = [];
      await this.runDetect();
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'takePhoto failed: %{public}s', e.message);
      this.statusText = `调起相机失败：${e.message}`;
    }
  }

  /**
   * 从相册选择图片
   *
   * 用系统相册选择器（PhotoViewPicker）而非直接读媒体库：
   * 选择器由系统实现，选中的文件会临时授权给本应用读取，
   * 因此不需要申请 READ_IMAGEVIDEO 权限，隐私上更干净。
   */
  private async pickFromGallery(): Promise<void> {
    try {
      const picker = new photoAccessHelper.PhotoViewPicker();
      const options = new photoAccessHelper.PhotoSelectOptions();
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      options.maxSelectNumber = BATCH_MAX;

      const result = await picker.select(options);

      if (result === undefined || result.photoUris === undefined
        || result.photoUris.length === 0) {
        this.statusText = '未选择图片';
        return;
      }

      hilog.info(DOMAIN, TAG, '已选择 %{public}d 张图片', result.photoUris.length);
      await this.handlePicked(result.photoUris);
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'pickFromGallery failed: %{public}s', e.message);
      this.statusText = `选择图片失败：${e.message}`;
    }
  }

  /**
   * 从文件选择图片
   *
   * 与「从相册选择」互补：相册只能看图库里的图，
   * 文件选择器可以浏览任意目录，适合导入数据集图片或外部素材。
   *
   * 注意：DocumentViewPicker 的构造函数推荐传 UIAbilityContext，
   * 不传虽然也能编译，但官方标注 "potential risk of operation failure"。
   */
  private async pickFromFiles(): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const docPicker = new picker.DocumentViewPicker(ctx);

      const options = new picker.DocumentSelectOptions();
      // 后缀过滤器格式："描述|后缀1,后缀2"
      options.fileSuffixFilters = ['图片|.jpg,.jpeg,.png,.bmp,.webp'];
      options.maxSelectNumber = BATCH_MAX;

      const uris: string[] = await docPicker.select(options);

      if (uris === undefined || uris.length === 0) {
        this.statusText = '未选择文件';
        return;
      }

      hilog.info(DOMAIN, TAG, '已选择 %{public}d 个文件', uris.length);
      await this.handlePicked(uris);
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'pickFromFiles failed: %{public}s', e.message);
      this.statusText = `选择文件失败：${e.message}`;
    }
  }

  /**
   * 统一处理选择结果：1 张走单张流程，多张走批量流程
   */
  private async handlePicked(uris: string[]): Promise<void> {
    if (uris.length === 1) {
      this.viewMode = 'single';
      this.batchItems = [];
      this.imageUri = uris[0];
      this.boxes = [];
      await this.runDetect();
    } else {
      await this.runBatchDetect(uris);
    }
  }

  /**
   * 批量识别
   *
   * 串行处理而非并发：模型实例共享，并发调用 predict 会冲突。
   * 串行还能给出准确的进度反馈。
   *
   * 单张失败不影响整批：错误记录在该项里，继续处理后续图片。
   */
  private async runBatchDetect(uris: string[]): Promise<void> {
    const list: string[] = uris.length > BATCH_MAX ? uris.slice(0, BATCH_MAX) : uris;

    this.viewMode = 'batch';
    this.batchRunning = true;
    this.detecting = true;
    this.batchItems = [];
    this.boxes = [];
    this.imageUri = '';

    const batchStart: number = Date.now();
    const items: BatchItem[] = [];

    for (let i = 0; i < list.length; i++) {
      this.batchProgress = `正在识别 ${i + 1}/${list.length}`;
      this.statusText = this.batchProgress;

      try {
        const res: DetectionResult = await this.detector.detect(list[i]);
        items.push({
          uri: list[i],
          index: i + 1,
          imageWidth: res.imageWidth,
          imageHeight: res.imageHeight,
          boxes: res.boxes,
          costMs: res.costMs,
          ok: res.boxes.length === 0,
          error: ''
        });
      } catch (err) {
        const e = err as BusinessError;
        hilog.error(DOMAIN, TAG, '第 %{public}d 张识别失败: %{public}s', i + 1, e.message);
        items.push({
          uri: list[i],
          index: i + 1,
          imageWidth: 0,
          imageHeight: 0,
          boxes: [],
          costMs: 0,
          ok: false,
          error: e.message
        });
      }

      // 每处理完一张就刷新界面，让用户看到进度
      this.batchItems = items.slice();
    }

    this.batchRunning = false;
    this.detecting = false;

    const totalMs: number = Date.now() - batchStart;
    const badCount: number = items.filter((it: BatchItem) => !it.ok).length;
    this.statusText =
      `共 ${items.length} 张，合格 ${items.length - badCount}，不合格 ${badCount}，总耗时 ${totalMs} ms`;
    this.batchProgress = '';
    this.costMs = totalMs;

    this.pushHistory(this.statusText);
    promptAction.showToast({ message: this.statusText, duration: 3000 });
  }

  /** 从批量列表进入单张详情 */
  private showDetail(item: BatchItem): void {
    this.imageUri = item.uri;
    this.boxes = item.boxes;
    this.costMs = item.costMs;
    this.imgWidth = item.imageWidth;
    this.imgHeight = item.imageHeight;
    this.viewMode = 'single';
    this.statusText = item.error.length > 0
      ? `识别失败：${item.error}`
      : (item.boxes.length === 0
        ? '未检出缺陷（合格）'
        : `检出 ${item.boxes.length} 处缺陷 · 耗时 ${item.costMs} ms`);
  }

  /** 从单张详情返回批量列表 */
  private backToList(): void {
    if (this.batchItems.length === 0) {
      return;
    }
    this.viewMode = 'batch';
    this.statusText = '点击列表项查看单张详情';
  }

  /** 对当前图片执行检测 */
  private async runDetect(): Promise<void> {
    if (this.imageUri.length === 0 || this.detecting) {
      return;
    }
    this.detecting = true;
    this.statusText = '正在检测…';
    try {
      const res: DetectionResult = await this.detector.detect(this.imageUri);
      this.boxes = res.boxes;
      this.costMs = res.costMs;
      this.backend = res.backend;
      this.imgWidth = res.imageWidth;
      this.imgHeight = res.imageHeight;

      if (res.boxes.length === 0) {
        this.statusText = '未检出缺陷（图片合格）';
      } else {
        this.statusText = `检出 ${res.boxes.length} 处缺陷 · 耗时 ${res.costMs} ms`;
      }
      this.pushHistory(this.statusText);
      promptAction.showToast({ message: this.statusText, duration: 2000 });
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'detect failed: %{public}s', e.message);
      this.statusText = `检测失败：${e.message}`;
    } finally {
      this.detecting = false;
    }
  }

  private pushHistory(text: string): void {
    const time: string = new Date().toLocaleTimeString();
    const item: string = `[${time}] ${text}`;
    const next: string[] = [item];
    for (let i = 0; i < this.history.length && i < 9; i++) {
      next.push(this.history[i]);
    }
    this.history = next;
  }

  private reset(): void {
    this.imageUri = '';
    this.boxes = [];
    this.costMs = 0;
    this.imgWidth = 0;
    this.imgHeight = 0;
    this.viewMode = 'single';
    this.batchItems = [];
    this.batchProgress = '';
    this.statusText = '选择图片后自动识别钢材表面缺陷';
  }

  /**
   * 计算图片在容器内按 Contain 模式显示时的真实矩形
   *
   * 关键：objectFit(Contain) 会在容器内留黑边，
   * 若直接用容器尺寸换算检测框，框会整体偏移。必须按实际显示区域算。
   */
  private getDisplayRect(): DisplayRect {
    const cw: number = this.containerW > 0 ? this.containerW : 360;
    const ch: number = this.containerH > 0 ? this.containerH : CANVAS_HEIGHT;
    if (this.imgWidth <= 0 || this.imgHeight <= 0) {
      return { left: 0, top: 0, width: cw, height: ch };
    }
    const scale: number = Math.min(cw / this.imgWidth, ch / this.imgHeight);
    const w: number = this.imgWidth * scale;
    const h: number = this.imgHeight * scale;
    return { left: (cw - w) / 2, top: (ch - h) / 2, width: w, height: h };
  }

  private pct(v: number): string {
    return `${(v * 100).toFixed(1)}%`;
  }

  /** 批量结果中合格的张数 */
  private passCount(): number {
    let c: number = 0;
    for (let i = 0; i < this.batchItems.length; i++) {
      if (this.batchItems[i].ok) {
        c++;
      }
    }
    return c;
  }

  /**
   * 把一张图检出的缺陷压成一句话，如 "划痕×2、裂纹×1"
   * 按类别归并计数，比逐个罗列更易读。
   */
  private summarize(boxes: Detection[]): string {
    const counts: Map<string, number> = new Map<string, number>();
    for (let i = 0; i < boxes.length; i++) {
      const cn: string = boxes[i].typeCn;
      const cur: number = counts.get(cn) ?? 0;
      counts.set(cn, cur + 1);
    }
    const parts: string[] = [];
    counts.forEach((v: number, k: string) => {
      parts.push(`${k}×${v}`);
    });
    return '检出 ' + parts.join('、');
  }

  // ---------- 界面 ----------
  build() {
    Column() {
      // ===== 顶部标题栏 =====
      Row() {
        Text('钢材质检').fontSize(20).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
        Blank()
        Text(this.backend).fontSize(12).fontColor('#CCFFFFFF')
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .backgroundColor('#1F6FEB')

      Scroll() {
        Column({ space: 12 }) {
          if (this.viewMode === 'batch') {
            this.BatchPanel()
          } else {
            this.ImageCanvas()
            this.StatusBar()
          }
          if (this.galleryOpen) {
            this.TestGallery()
          }
          this.ActionButtons()
          if (this.viewMode === 'single' && this.boxes.length > 0) {
            this.ResultList()
          }
          this.DefectLegend()
          if (this.history.length > 0) {
            this.HistoryList()
          }
          Text(this.usingRealModel
            ? '说明：正在使用 NEU-DET 数据集训练的 YOLOv8n 真实模型（MindSpore Lite 端侧推理）。'
            : '说明：模型未加载，当前使用模拟数据验证业务流程。')
            .fontSize(11)
            .fontColor('#999999')
            .width('100%')
            .padding(8)
            .backgroundColor('#F5F5F5')
            .borderRadius(6)
        }
        .width('100%')
        .padding(12)
      }
      .layoutWeight(1)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F0F2F5')
  }

  /** 批量识别面板：汇总 + 结果列表 */
  @Builder
  BatchPanel() {
    Column({ space: 10 }) {
      // ── 汇总条 ──
      Row() {
        Column({ space: 2 }) {
          Text(`${this.batchItems.length}`).fontSize(22).fontWeight(FontWeight.Bold)
          Text('总数').fontSize(11).fontColor('#999999')
        }.layoutWeight(1)

        Column({ space: 2 }) {
          Text(`${this.passCount()}`).fontSize(22).fontWeight(FontWeight.Bold)
            .fontColor('#52C41A')
          Text('合格').fontSize(11).fontColor('#999999')
        }.layoutWeight(1)

        Column({ space: 2 }) {
          Text(`${this.batchItems.length - this.passCount()}`).fontSize(22)
            .fontWeight(FontWeight.Bold).fontColor('#FF4D4F')
          Text('不合格').fontSize(11).fontColor('#999999')
        }.layoutWeight(1)
      }
      .width('100%')
      .padding(12)
      .backgroundColor('#FFFFFF')
      .borderRadius(8)

      // ── 进度 ──
      if (this.batchRunning) {
        Row({ space: 8 }) {
          LoadingProgress().width(18).height(18)
          Text(this.batchProgress).fontSize(13).fontColor('#1F6FEB')
        }
        .width('100%')
        .padding(8)
        .backgroundColor('#E6F4FF')
        .borderRadius(6)
      }

      // ── 结果列表 ──
      ForEach(this.batchItems, (item: BatchItem) => {
        Row({ space: 10 }) {
          // 缩略图
          Image(item.uri)
            .width(56)
            .height(56)
            .objectFit(ImageFit.Cover)
            .borderRadius(6)
            .backgroundColor('#EEEEEE')

          Column({ space: 3 }) {
            Row({ space: 6 }) {
              Text(`样品 ${item.index}`).fontSize(14).fontWeight(FontWeight.Medium)
              Text(item.ok ? '合格' : '不合格')
                .fontSize(11)
                .fontColor('#FFFFFF')
                .backgroundColor(item.ok ? '#52C41A' : '#FF4D4F')
                .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                .borderRadius(3)
            }
            if (item.error.length > 0) {
              Text(`识别失败：${item.error}`).fontSize(11).fontColor('#FF4D4F')
            } else if (item.boxes.length === 0) {
              Text('未检出缺陷').fontSize(11).fontColor('#999999')
            } else {
              Text(this.summarize(item.boxes)).fontSize(11).fontColor('#666666')
            }
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Text('›').fontSize(20).fontColor('#CCCCCC')
        }
        .width('100%')
        .padding(10)
        .backgroundColor('#FFFFFF')
        .borderRadius(8)
        .onClick(() => {
          this.showDetail(item);
        })
      }, (item: BatchItem) => `batch-${item.index}-${item.uri}`)

      Text('点击任意一项查看检测框详情')
        .fontSize(11).fontColor('#999999').width('100%')
    }
    .width('100%')
  }

  /** 图片区 + 检测框叠加层 */
  @Builder
  ImageCanvas() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.imageUri.length > 0) {
        Image(this.imageUri)
          .width('100%')
          .height(CANVAS_HEIGHT)
          .objectFit(ImageFit.Contain)
          .backgroundColor('#000000')
          .borderRadius(8)

        // 检测框叠加：按图片实际显示矩形换算坐标
        ForEach(this.boxes, (item: Detection, index: number) => {
          this.BoxOverlay(item, index)
        }, (item: Detection, index: number) => `box-${index}-${item.type}`)
      } else {
        Column({ space: 8 }) {
          Text('📷').fontSize(40)
          Text('暂无图片').fontSize(14).fontColor('#999999')
          Text('拍照 / 相册 / 文件均可').fontSize(12).fontColor('#BBBBBB')
        }
        .width('100%')
        .height(CANVAS_HEIGHT)
        .justifyContent(FlexAlign.Center)
        .backgroundColor('#FFFFFF')
        .borderRadius(8)
        .border({ width: 1, color: '#E0E0E0', style: BorderStyle.Dashed })
      }
    }
    .width('100%')
    .height(CANVAS_HEIGHT)
    .onAreaChange((oldArea: Area, newArea: Area) => {
      this.containerW = Number(newArea.width);
      this.containerH = Number(newArea.height);
    })
  }

  /** 内置图库面板：类别筛选 + 懒加载网格（NEU-DET 全量） */
  @Builder
  TestGallery() {
    Column({ space: 8 }) {
      Row() {
        Text(`🖼 内置图库（NEU-DET · 当前 ${this.galleryCount} 张）`)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .layoutWeight(1)
        Button('收起')
          .height(28)
          .fontSize(12)
          .onClick(() => {
            this.galleryOpen = false;
          })
      }
      .width('100%')

      // 类别筛选
      Scroll() {
        Row({ space: 6 }) {
          ForEach(this.GALLERY_CLASSES, (item: GalleryClass, idx: number) => {
            Text(item.cn)
              .fontSize(12)
              .fontColor(this.galleryClassIdx === idx ? '#FFFFFF' : '#333333')
              .backgroundColor(this.galleryClassIdx === idx ? '#1F6FEB' : '#EFEFEF')
              .padding({ left: 10, right: 10, top: 4, bottom: 4 })
              .borderRadius(14)
              .onClick(() => {
                this.galleryClassIdx = idx;
                this.applyGalleryFilter();
              })
          }, (item: GalleryClass, idx: number) => `${item.prefix}-${idx}`)
        }
        .padding({ top: 2, bottom: 2 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')

      // 图片网格（懒加载）
      Scroll() {
        Grid() {
          LazyForEach(this.gallerySource, (name: string) => {
            GridItem() {
              Column({ space: 2 }) {
                Image($rawfile(`neuimg/${name}`))
                  .width('100%')
                  .height(64)
                  .objectFit(ImageFit.Cover)
                  .borderRadius(4)
                  .border({ width: 1, color: '#E0E0E0' })
                Text(name.replace('.jpg', ''))
                  .fontSize(8)
                  .fontColor('#666666')
                  .maxLines(1)
              }
              .width('100%')
              .onClick(() => {
                this.pickTestImage(name);
              })
            }
          }, (name: string) => name)
        }
        .columnsTemplate('1fr 1fr 1fr 1fr 1fr')
        .columnsGap(5)
        .rowsGap(5)
        .width('100%')
      }
      .height(300)
      .scrollable(ScrollDirection.Vertical)
      .scrollBar(BarState.Auto)
    }
    .width('100%')
    .padding(10)
    .backgroundColor('#FFFFFF')
    .borderRadius(8)
    .border({ width: 1, color: '#E0E0E0' })
  }

  /** 单个检测框 */
  @Builder
  BoxOverlay(item: Detection, index: number) {
    Column() {
      Text(`${item.typeCn} ${this.pct(item.confidence)}`)
        .fontSize(10)
        .fontColor('#FFFFFF')
        .backgroundColor(DEFECT_META[item.type].color)
        .padding({ left: 4, right: 4, top: 1, bottom: 1 })
        .borderRadius(3)
    }
    .alignItems(HorizontalAlign.Start)
    .border({ width: 2, color: DEFECT_META[item.type].color })
    .width(this.getDisplayRect().width * item.w)
    .height(this.getDisplayRect().height * item.h)
    .position({
      x: this.getDisplayRect().left + this.getDisplayRect().width * item.x,
      y: this.getDisplayRect().top + this.getDisplayRect().height * item.y
    })
  }

  /** 状态栏 */
  @Builder
  StatusBar() {
    Column({ space: 4 }) {
      Row() {
        Text(this.statusText)
          .fontSize(14)
          .fontColor(this.boxes.length > 0 ? '#FF4D4F' : '#666666')
          .layoutWeight(1)
        if (this.detecting) {
          LoadingProgress().width(20).height(20)
        }
      }
      .width('100%')

      Row({ space: 6 }) {
        Text(this.usingRealModel ? '●' : '○')
          .fontSize(10)
          .fontColor(this.usingRealModel ? '#52C41A' : '#FAAD14')
        Text(this.usingRealModel ? `真实模型 · ${this.modelStatus}` : this.modelStatus)
          .fontSize(11)
          .fontColor('#999999')
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 4, right: 4 })
  }

  /** 操作按钮（三种取图方式 + 结果操作） */
  @Builder
  ActionButtons() {
    Column({ space: 10 }) {
      // 第一行：三种取图方式
      Row({ space: 8 }) {
        Button('拍照')
          .layoutWeight(1)
          .height(46)
          .backgroundColor('#1F6FEB')
          .enabled(!this.detecting)
          .onClick(() => {
            this.takePhoto();
          })

        Button('相册')
          .layoutWeight(1)
          .height(46)
          .backgroundColor('#13C2C2')
          .enabled(!this.detecting)
          .onClick(() => {
            this.pickFromGallery();
          })

        Button('文件')
          .layoutWeight(1)
          .height(46)
          .backgroundColor('#722ED1')
          .enabled(!this.detecting)
          .onClick(() => {
            this.pickFromFiles();
          })
      }
      .width('100%')

      // 第二行：内置图库
      Row({ space: 8 }) {
        Button(this.galleryOpen ? '收起图库' : '🖼 内置图库（NEU-DET 1800 张）')
          .layoutWeight(1)
          .height(42)
          .backgroundColor('#EB2F96')
          .enabled(!this.detecting)
          .onClick(() => {
            this.galleryOpen = !this.galleryOpen;
            if (this.galleryOpen) {
              this.loadGallery();
            }
          })
      }
      .width('100%')

      // 第三行：结果操作
      Row({ space: 8 }) {
        if (this.batchItems.length > 0 && this.viewMode === 'single') {
          Button('返回列表')
            .layoutWeight(1)
            .height(46)
            .backgroundColor('#FA8C16')
            .enabled(!this.detecting)
            .onClick(() => {
              this.backToList();
            })
        } else {
          Button('重新检测')
            .layoutWeight(1)
            .height(46)
            .backgroundColor('#52C41A')
            .enabled(this.imageUri.length > 0 && !this.detecting)
            .onClick(() => {
              this.runDetect();
            })
        }

        Button('清空')
          .layoutWeight(1)
          .height(46)
          .backgroundColor('#8C8C8C')
          .enabled(this.imageUri.length > 0 && !this.detecting)
          .onClick(() => {
            this.reset();
          })
      }
      .width('100%')
    }
    .width('100%')
  }

  /** 检测结果列表 */
  @Builder
  ResultList() {
    Column({ space: 6 }) {
      Row() {
        Text('检测结果').fontSize(15).fontWeight(FontWeight.Bold)
        Blank()
        Text(`推理 ${this.costMs} ms`).fontSize(12).fontColor('#999999')
      }
      .width('100%')

      ForEach(this.boxes, (item: Detection, index: number) => {
        Row({ space: 8 }) {
          Column()
            .width(4)
            .height(36)
            .backgroundColor(DEFECT_META[item.type].color)
            .borderRadius(2)

          Column({ space: 2 }) {
            Row({ space: 6 }) {
              Text(item.typeCn).fontSize(15).fontWeight(FontWeight.Medium)
              Text(`#${index + 1}`).fontSize(11).fontColor('#999999')
            }
            Text(item.type).fontSize(10).fontColor('#AAAAAA')
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Column({ space: 2 }) {
            Text(this.pct(item.confidence))
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor(DEFECT_META[item.type].color)
            Text('置信度').fontSize(10).fontColor('#AAAAAA')
          }
          .alignItems(HorizontalAlign.End)
        }
        .width('100%')
        .padding(10)
        .backgroundColor('#FFFFFF')
        .borderRadius(6)
      }, (item: Detection, index: number) => `row-${index}-${item.type}-${item.confidence}`)
    }
    .width('100%')
  }

  /** 缺陷类型图例 */
  @Builder
  DefectLegend() {
    Column({ space: 6 }) {
      Text('支持检测的 6 类缺陷（NEU-DET 数据集）')
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .width('100%')

      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(ALL_DEFECT_TYPES, (meta: DefectMeta) => {
          Row({ space: 4 }) {
            Column()
              .width(8)
              .height(8)
              .backgroundColor(meta.color)
              .borderRadius(4)
            Text(meta.cn).fontSize(11).fontColor('#555555')
          }
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .margin({ right: 6, bottom: 6 })
          .backgroundColor('#FFFFFF')
          .borderRadius(4)
        }, (meta: DefectMeta) => meta.en)
      }
      .width('100%')
    }
    .width('100%')
    .padding(10)
    .backgroundColor('#FAFAFA')
    .borderRadius(6)
  }

  /** 操作历史 */
  @Builder
  HistoryList() {
    Column({ space: 4 }) {
      Text('检测记录').fontSize(13).fontWeight(FontWeight.Medium).width('100%')
      ForEach(this.history, (item: string, index: number) => {
        Text(item).fontSize(11).fontColor('#777777').width('100%')
      }, (item: string, index: number) => `his-${index}-${item}`)
    }
    .width('100%')
    .padding(10)
    .backgroundColor('#FFFFFF')
    .borderRadius(6)
  }
}
