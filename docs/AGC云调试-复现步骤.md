# AGC 云调试复现步骤（HarmonySteelQC-Core）

> 目标：把本仓库的应用装到华为云真机上跑通（加载 `neu_det_yolov8n.ms` 并完成检测），
> 为后续 NPU/CPU 实验做准备。
>
> 依据：2026-10-14 那次云调试**实测记录**（研究过程仓库
> `docs/GEM-W40-当前研究/进展-官方答复与AGC云调试方案.md` 第三、四、七节）
> ＋ 本次（2026-10-14 16:39）在本机的重新验证。
>
> 状态：**待审阅，尚未提交**。

---

## 0. 先回答「之前跑过，是不是可以直接跑」——可以，但要满足 3 个前提

| # | 前提 | 上次的结论 | 现在的状态 |
|---|---|---|---|
| 1 | **签名**：用 debug 自动签名包即可 | ⚠️ **待当场验证**：研究过程仓库称"AGC 云调试对上传的 HAP 自动放行，不受调试 profile 的 UDID 白名单限制"，但该仓库已确认可能存在错误信息，**不作为依据** | ✅ 本机材料还在，已用同一套签名重新打出签名包并通过校验（见 §1）；能否装上以会话 A 实测为准 |
| 2 | **仓库能出包** | —— | ✅ 交付版原本 `ohpm install` 和 release 构建都失败，已修（提交 `1ab499b`） |
| 3 | **账号与时长** | AGC 个人开发者账号已就绪；剩余优惠时长 **360 分钟**（每次申请 60 分钟） | ⚠️ 需你现场确认剩余时长是否还有 |

> ⚠️ 一个容易走错的方向：网上（含第三方实操文）普遍说"云调试只收 release 签名包"。
> 这条**同样未经验证**。因此会话 A 的第一件事就是**当场试装**：
> 装上 → 按 §5 验收；装不上 → 记下确切报错，走 §9 备用方案（发布证书路线）。
> **无论哪种结果都记录下来**，不预设结论。

---

## 1. 本机现状核对（2026-10-14 16:30-16:40 实测）

| 项 | 现值 |
|---|---|
| DevEco Studio | `D:\DevEco Studio`，6.1.1.300 |
| SDK | API 24 / HarmonyOS 6.1.1（6.1.1.125） |
| 签名材料 | `C:\Users\17999\.ohos\config\default_SteelQC_0c6hfUa…{p12, cer, p7b}` —— 三个文件都在 |
| Profile 内容 | `type=debug`、`bundle-name=com.zjsrtp.steelqc`、绑定 3 个 UDID、`allowed-acls=[READ_IMAGEVIDEO, WRITE_IMAGEVIDEO]`、有效期至 **2027-10-13** |
| 口令密文解密材料 | `C:\Users\17999\.ohos\config\material\{fd,ac,ce}` 存在（hvigor 靠它解密 `storePassword/keyPassword`） |
| 签名配置文件 | `app\signing.config.json`（**git-ignored**，从上一次工程搬运而来；口令密文长度 86） |
| 已出包 | `app\entry\build\default\outputs\default\entry-default-signed.hap` = **38.22 MB** |
| 签名校验 | `hap-sign-tool verify-app` → `Digest verify result: true` / **Verify success** |

---

## 2. 出包（一条命令）

```powershell
cd C:\Users\17999\Desktop\HarmonySteelQC-Core
powershell -NoProfile -ExecutionPolicy Bypass -File app\scripts\build-hap.ps1 -Mode debug -Sign
```

产物：`app\entry\build\default\outputs\default\entry-default-signed.hap`
（脚本会自动：清 `entry\build` → 注入签名 → 构建 → **还原** `build-profile.json5`，所以 `git status` 始终干净）

要点：

- **必须用 `-Mode debug`**：profile 是 debug 类型，与上次云调试一致。用 release 模式会造成"包类型与 profile 不符"。
- 换机器时要先 `copy app\signing.config.example.json app\signing.config.json` 并填 4 项材料；本机已配好。
- 若脚本被中途打断导致 `build-profile.json5` 残留签名配置，执行 `…-File app\scripts\build-hap.ps1 -Revert` 一键恢复。

---

## 3. AGC 控制台操作

1. 打开 `developer.huawei.com` → **AppGallery Connect** → 登录 → **我的项目**
2. 左侧菜单：**质量 → 云调试 → 单机调试**
3. 筛选：**真机**（⚠️ 设备列表里真机与仿真机混排，**仿真机没有真实 NPU，选了等于白测**）
4. 选机型（按官方"较新平台才开放深度 NPU"的口径排优先级）：

   | 优先级 | 机型 | 芯片 |
   |:--:|---|---|
   | ★★★ | Mate 70 / Pura 70 系列 | 9010 / 9020 |
   | ★★★ | Mate 90 系列（云上已确认有：HarmonyOS 7.0.0.109 / API 26） | 更新平台 |
   | ★★ | Mate 60 系列 | 9000S |
   | ★ | MatePad Pro 13.2 / 12.2 | 9000S / 9010 |

5. 申请设备（**每次 60 分钟**）→ 进入远程桌面

---

## 4. 上传与安装

云调试界面「**应用 → 本地上传**」→ 选 §2 产出的 `entry-default-signed.hap` → **自动安装**
（安装列表出现绿色对勾即成功；上次就是这一步直接通过的）

---

## 5. 验收清单：怎么算「跑起来了」

控制面板有 **Shell 输入框**（等价于本地 `hdc shell`，命令不加 `hdc shell` 前缀）与**日志区**。

> ⚠️ **云调试的 Shell 不支持管道符**：`hilog … | grep …` 会返回「无效命令或被限制执行！」。
> 必须用 hilog 自带的过滤参数，**一条命令一个动作、不加任何 `|`**。
> 优先用控制面板的 **hilog 标签页**（自带关键字过滤框，等于 UI 层的过滤，最省事）。

**做法 A（推荐）：先开 hilog 标签页，再重启应用**
1. 切到控制面板的 **hilog** 标签页（实时日志视图），在过滤框里填 `MSSpLiteDetector`
2. 回 **Shell脚本** 标签页执行下面三行（重启应用，日志会实时刷进 hilog 页）：
```
hilog -r
aa force-stop com.zjsrtp.steelqc
aa start -a EntryAbility -b com.zjsrtp.steelqc
```
3. 等 5~10 秒（模型 12 MB，要读盘 + 建后端），再看 hilog 页；需要看设备指纹就把过滤词换成 `DEVIPROBE`

**做法 B：全程用 Shell（无管道，靠 hilog 自带参数过滤）**

第 1 次执行（清缓冲 + 重启）：
```
hilog -r
aa force-stop com.zjsrtp.steelqc
aa start -a EntryAbility -b com.zjsrtp.steelqc
```
**等 10 秒**，第 2 次执行（按 TAG 过滤；`-T` 是 hilog 自带的标签过滤）：
```
hilog -x -T MSSpLiteDetector
```
第 3 次执行（应用界面日志 + 设备指纹都在这个 TAG 下）：
```
hilog -x -T SteelQC
```
> 只用到 `-x`（读当前缓冲区后退出）与 `-T`（按标签过滤）两个参数，**不依赖行数/级别等可选参数**，
> 兼容性最好。若某版本还支持 `-L I`、`-a 200` 之类，可自行加上；不支持就省掉。

| # | 观察点 | 预期 |
|:--:|---|---|
| 1 | 界面顶部模型状态 | `真实模型已就绪` |
| 2 | 日志 `MSSpLiteDetector` | `模型已读取: 12xxxxxx 字节` |
| 3 | 日志 `MSSpLiteDetector` | `模型加载成功，后端 = NPU` **或** `已回退 CPU（后端结果: N）`（都算"跑起来"，后者只说明这台设备没暴露 NPU） |
| 4 | 日志 `SteelQC` | `DEVIPROBE chip=… hw=… model=… os=… api=…` ← **这条是机型/平台测绘的数据来源，顺手记下来** |
| 5 | 内置图库选 `scratches_1.jpg` | 出框即通过（**不设具体数值基准**；研究仓库里的 76.9%/69 ms 不作为判据） |
| 6 | 批量选多张 | 汇总 `共 N 张，合格 x，不合格 y` |

> 抓日志的两个要点（老坑）：
> ① `hilog -x` 只读当前缓冲区且不阻塞 → 必须「清缓冲 → 重启应用 → 立刻抓」；
> ② 应用日志 TAG 是 `MSSpLiteDetector` / `SteelQC`，用应用名去过滤会捞到一堆系统噪声。

---

## 6. 判读：这台云设备的 NPU 到底能不能用

**官方判据（离线可判，先看这一条）**：`HMS_HiAI_GetVersion()` 返回 `A1A2A3.X1X2X3.Y1Y2Y3.Z1Z2Z3`，
**第二段首位 `X1 = 0` → 不支持 NPU；`X1 ≠ 0` → 支持**。

| 设备 | 版本号 | X1 | 结论 |
|---|---|---|---|
| TGR-W10 MatePad 11.5"S（K1010） | `106.030.120.010` | **0** | ❌ 不支持（⚠️ 数值源自研究仓库，未独立复核） |
| MatePad Pro Max 悦享（Kirin T93） | `109.636.120.010` | **6** | ⚠️ 同样源自研究仓库，**本次需用实测日志重新确认** |

> 判据本身（`X1=0` 不支持 / `≠0` 支持）来自转述的官方答复，**本次一并复核**：
> 先拿到该设备的 `HMS_HiAI_GetVersion()` 返回值，再与实跑结果对照。

> ⚠️ 交付版（本仓库）**已关闭全部诊断探针**，看 `X1` 的原始日志来自研究版。
> 交付版能看的等价信号是**后端标识**：界面/日志显示 `MindSporeLite-nnrt(NPU)` = NPU 成功，
> `…-cpu` = 回退 CPU。想拿到 `X1`、单算子结果、NNRt 设备枚举，需要 §8 里的研究版或把探针接回来。

---

## 7. 失败速查

| 现象 | 原因 | 处理 |
|---|---|---|
| 上传被拒 / 提示非 release 应用 | 上传的是 unsigned 包，或平台策略变化 | 确认上传的是 `entry-default-signed.hap`；若确实被要求 release，走 §9 备用方案 |
| 设备列表里选到仿真机 | 没有真实 NPU | 重选带"真机"标识的设备 |
| 应用装不上（签名校验失败） | profile 过期 / 材料不匹配 | profile 有效期到 2027-10-13；重新在 DevEco 生成签名 |
| 界面显示「模型加载失败，使用模拟数据」 | rawfile 里的 `.ms` 没进包，或后端异常 | 解包核对 `resources/rawfile/neu_det_yolov8n.ms` |
| 构建报 `Failed to delete … neu_det_yolov8n.ms` | 切换 buildMode 后残留缓存（老坑 7） | 删 `app\entry\build` 再构建（脚本已内置） |
| 抓不到模型初始化日志 | 缓冲区被系统日志冲掉 | 压日志级别 + 清缓冲 + 立刻抓（见 §5） |
| 时长不够 | 每次 60 分钟，优惠时长有限 | 规划：一次会话内完成"安装 + 6 条验收 + 记录指纹" |

---

## 8. 交付版 vs 研究版：实验阶段该用哪个（需要你定）

| | 本仓库（交付版） | `D:\HarmonyProjects\HarmonySteelQC`（研究过程仓库） |
|---|---|---|
| 定位 | 干净交付版，诊断开关全关 | 研究过程存档（README 已标注「已归档·请勿参考」） |
| NPU 诊断探针 | ❌ 无（`src/main/cpp/` 未入库） | ✅ 有（`nnrt_probe.cpp`、`hiai_probe.cpp`、`Index.ets` 5 个开关） |
| NPU/CPU 对照基准 | `MindSporeLiteDetector` 有 `forceTarget` 构造参数，但**界面没入口** | ✅ `BackendBench.ets`（3 次预热 + 10 次计时，同机同输入对比） |
| 用途 | 「把程序跑起来」+ 交付出包 | 「做实验」：X1 判据、设备枚举、A/B 时序 |

**建议**（待你确认）：
- 若这一步只验证「装得上、跑得通」→ 用本仓库的交付版（已出签名包，可直接上传）；
- 若紧接着要出实验数据 → 用研究版出包，或把 `BackendBench.ets` 与探针开关迁到本仓库（走 `feat/` 分支）。

---

## 9. 备用方案：如果平台确实要求 release 签名

1. DevEco：**Build → Generate Key and CSR** → 得到 `.p12` + `.csr`
2. AGC：**证书、App ID 和 Profile** → 新增**发布证书**（上传 `.csr`）→ 下载 `.cer`
3. AGC：**Profile → 添加** → 类型选**发布** → 关联发布证书与 `com.zjsrtp.steelqc` → 勾选权限 → 下载 `.p7b`
4. 把三个文件路径填进 `app\signing.config.json`；**口令必须用 DevEco 生成的那串密文**
   （hvigor 会用 `DecipherUtil` 解密，明文口令会直接报 `00303116 … less than 32`）
5. `app\scripts\build-hap.ps1 -Mode release -Sign`

---

## 附二：一键基准测试套件（应用内，v2）

应用底部有两个按钮（结果都走 hilog）：

| 按钮 | 覆盖 | 耗时 |
|---|---|---|
| ⚡ **快速测试** | P0–P3 + P2b 输出读取口径 + P5 交错块 + P6 端到端(30 张) + P6b 前处理变体 + P7 一致性 + P8 线程 | ~1 分钟 |
| 🧪 **完整测试** | 上面全部 + P4 空闲扫描（6 档 × 3 次）+ P9 大图自造 + P10 批量 50 张 + P11 会话内复测 | **~12 分钟**（空闲扫描占 ~10.75 分钟） |

```
hilog -r                          ← 点按钮前先清缓冲
（点按钮；期间保持屏幕常亮、不要切后台/锁屏）
hilog -x -T STEELQC_BENCH         ← 取结果
```

分析（可从原始日志重算，结论不依赖手算）：

```powershell
powershell -File app\scripts\analyze-bench.ps1 -LogPath <日志文件路径>
```

v2 的关键设计（都由 v1 数据倒推）：
- **纯推理阶段共用同一份预解码输入**，与端到端口径严格分离；
  端到端另报 `decode / readback / loop / infer / nms` **五段** —— 其中 readback 与 loop
  的拆分决定了"该优化哪一段"（实测 readback≈0，loop 占 57%）；
- **三种前处理实现同机交错 A/B**（原实现 / Uint32+位运算+乘法 / 查表），
  省掉"改一版测一次"的多轮会话；
- **纳秒时钟**（`systemDateTime.getTime(true)`）消除 1 ms 量化对 4 ms 级测量的 ±25% 误差；
- **输出读取口径对照**：只等 Promise vs 读输出张量，用于判定 `predict()` 是否"假快"；
- **设备上自造大图**（放大 + 重编码为 1280×960 / 2560×1920 JPEG），量化取图分辨率的代价。

> ⚠️ 运行期间定时器与推理会被系统节流，空闲扫描尤其敏感；
> 长会话（>10 分钟）可能进入不同功耗状态，跨轮对比时需注意（见第 2 轮分析的未闭合项）。

---

## 附：本次已完成的验证（可复核）

```
ohpm install                              → exit 0（修复悬空依赖后）
release 构建（未签名）                     → BUILD SUCCESSFUL，entry-default-unsigned.hap 38.17 MB
debug 构建（签名）                         → BUILD SUCCESSFUL in 47.3 s，entry-default-signed.hap 38.22 MB
hap-sign-tool verify-app                  → Digest verify result: true，Verify success
HAP 内容核对                               → resources/rawfile/neu_det_yolov8n.ms 12.05 MB + neuimg 1800 张
git status                                → 干净（build-profile.json5 签名注入已自动还原，signing.config.json 被忽略）
python training/tools/verify_claims.py    → 全部核对项通过（数据集/指标/ONNX/类别顺序/依赖/划分复现）
```
