# HarmonyOS 应用构建与部署

本目录是「钢材质检」鸿蒙应用，基于 ArkTS 开发，目标设备为华为平板。

---

## 一、工程结构

```
app/
├── entry/src/main/ets/
│   ├── entryability/EntryAbility.ets   应用入口
│   ├── model/
│   │   ├── DefectType.ets              NEU-DET 6 类缺陷定义 + 数据结构
│   │   ├── Detector.ets                检测器接口（关键抽象，为真实模型预留）
│   │   ├── MindSporeLiteDetector.ets   真实模型检测器（当前使用）
│   │   └── MockDetector.ets            模拟检测器（仅在模型加载失败时兜底）
│   └── pages/Index.ets                 主界面：拍照 → 检测 → 显示结果
├── entry/src/main/module.json5         模块配置 + 权限声明
├── build-profile.json5                 工程配置（签名配置留空，见下）
└── local.properties.example            开发机 SDK 路径模板
```

### 已接入真实模型（含失败兜底）

`Index.ets` 启动时按「真实模型优先」初始化，不再需要手改这一行：

```typescript
// entry/src/main/ets/pages/Index.ets —— setupDetector()

const real: MindSporeLiteDetector =
  new MindSporeLiteDetector(ctx.resourceManager as resourceManager.ResourceManager);
const ok: boolean = await real.init();

if (ok) {
  this.detector = real;          // 真实模型就绪：MindSpore Lite + NEU-DET 权重
  this.usingRealModel = true;
} else {
  // 加载失败才回退，界面照样可用
  this.modelStatus = '模型加载失败，使用模拟数据';
}
```

界面代码完全不用动 —— `Detector` 接口与 `DetectionResult` 数据契约已固定
（归一化坐标 0~1、置信度、耗时、后端名）。

> 后端选择同样自动：先试 NPU（nnrt），不可用则回退 CPU。
> NPU 的现状与排查见仓库根目录 `README.md` 的「NPU 问题的如实记录」一节。

---

## 二、环境要求

| 组件 | 版本 | 说明 |
|---|---|---|
| DevEco Studio | 6.1.1+ | 本项目在 6.1.1.300 上开发 |
| HarmonyOS SDK | API 24 | 与目标设备一致 |
| hvigor | 6.24.4 | DevEco 自带 |
| JDK | 21 | DevEco 自带 JBR |

目标设备：**HUAWEI MatePad 11.5''S（TGR-W10）**，OpenHarmony 6.1.1，API 24。

---

## 三、首次配置（必做）

### 1. 配置 SDK 路径

复制 `local.properties.example` 为 `local.properties`，按自己的安装位置修改：

```properties
sdk.dir=D:\\DevEco Studio\\sdk
nodejs.dir=D:\\DevEco Studio\\tools\\node
```

> 该文件已被 `.gitignore` 排除，因为路径含开发机用户名。

### 2. 配置签名（不做这步无法安装到真机）

```
DevEco Studio → 文件 → 项目结构 → 签名配置
→ 勾选「自动生成签名」→ 确定
```

因为是华为设备，**必须用 DevEco 自动签名**（原因见第五节）。
IDE 会向华为申请绑定调试设备的证书，并自动写入 `build-profile.json5`。

> ### ⚠️ 关键：`build-profile.json5` **是被 git 跟踪的**，`.gitignore` 对它无效
>
> 配置签名后，该文件里会含**加密口令和开发机路径**。而它在仓库里是
> `"signingConfigs": []` 并且**已被跟踪**——所以 `.gitignore` 拦不住它，
> 一个 `git add .` 就会把口令带进公开仓库。
>
> **配置完签名后，务必立刻把它从 git 视野里屏蔽掉：**
>
> ```powershell
> git update-index --skip-worktree app/build-profile.json5
>
> # 验收（三条都应满足）
> git status --short                            # 不出现 build-profile.json5
> git diff --stat -- app/build-profile.json5     # 空
> git add app/build-profile.json5                # git 自己拒绝入库
> ```
>
> **代价**：`skip-worktree` 是本地状态，以后 `git pull` 若该文件有冲突会报错，
> 先确认是不是它；需要恢复跟踪用 `git update-index --no-skip-worktree app/build-profile.json5`。

### 3. 跳过 IDE 直接用命令行构建（可选）

不想开 DevEco 时，可以手工完成上面两步：

1. 复制 `local.properties.example` → `local.properties`
2. 从一份**已经配好签名**的工程复制 `signingConfigs` 整段到 `app/build-profile.json5`
   （证书材料在 `C:\Users\<用户>\.ohos\config\default_<项目名>_<hash>.{cer,p7b,p12}`）
3. 执行上面的 `skip-worktree` 屏蔽

> ⚠️ 手工写路径时**每个反斜杠都要写成两个**（`C:\\Users\\...`），
> 否则 JSON5 会把 `\U`、`\c` 当转义符吃掉。见坑 6。

---

## 四、构建

```powershell
$env:DEVECO_SDK_HOME = "D:\DevEco Studio\sdk"
$node = "D:\DevEco Studio\tools\node\node.exe"
$hv   = "D:\DevEco Studio\tools\hvigor\bin\hvigorw.js"

cd app
& $node $hv --mode module -p product=default -p module=entry@default assembleHap --no-daemon
```

产物：`entry\build\default\outputs\default\entry-default-signed.hap`

> **换了工作区之后，先清一次构建缓存再构建。**
> 如果 `app\` 是从别的目录复制来的，`entry\build\` 里会留着**旧工作区的中间产物**
> （时间戳能看出来），与新配置混用会报出莫名其妙的错误，例如：
>
> ```
> Failed to delete the directory or file '...\rawfile\neu_det_yolov8n.ms', No error.
> ```
>
> 这两个目录都在 `.gitignore` 里，删掉是安全的：
>
> ```powershell
> Remove-Item entry\build, .hvigor -Recurse -Force -ErrorAction SilentlyContinue
> ```

### 安装与启动

```powershell
$Hdc = "D:\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"

& $Hdc list targets -v                       # 确认设备：<key>  USB  Connected
& $Hdc install -r entry\build\default\outputs\default\entry-default-signed.hap
& $Hdc shell aa start -a EntryAbility -b com.zjsrtp.steelqc

# 看模型加载日志（TAG 是 MSSpLiteDetector，不是应用名）
& $Hdc shell hilog -r                        # 先清缓冲区
& $Hdc shell aa force-stop com.zjsrtp.steelqc
& $Hdc shell aa start -a EntryAbility -b com.zjsrtp.steelqc
& $Hdc shell hilog -x | Select-String MSSpLiteDetector
```

> **抓日志的两个要点**：
> 1. `hilog -x` 只读**当前缓冲区**，且不阻塞。所以必须「清缓冲 → 重启应用 → 立刻抓」，
>    否则模型初始化的那几行会被刷掉。
> 2. TAG 是 `MSSpLiteDetector`（模型）和 `SteelQC`（界面），
>    用应用名去 `Select-String` 会捞到一堆系统噪声。

---

## 五、签名：为什么必须用 DevEco 自动签名

这一节记录了完整踩坑过程，**结论是手工签名在华为设备上走不通**。

### 尝试一：SDK 自带的 OpenHarmony 调试证书（失败）

SDK 提供了整套 OpenHarmony 调试签名材料：

| 材料 | 路径 |
|---|---|
| 密钥库 | `sdk/default/openharmony/toolchains/lib/OpenHarmony.p12` |
| 签名工具 | `sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar` |
| Profile 证书链 | `sdk/default/openharmony/toolchains/lib/OpenHarmonyProfileDebug.pem` |
| Profile 模板 | `sdk/default/openharmony/toolchains/lib/UnsgnedDebugProfileTemplate.json` |

**签名流程本身是通的**（`hap-sign-tool verify-app` 返回 `Verify success`）：

```
第 1 步：签 Profile
  JSON(bundle-name + 设备 UDID) --[profile debug 密钥]--> .p7b
第 2 步：签 HAP
  HAP + .p7b + 应用证书链 --[application release 密钥]--> 已签名 HAP
```

**但安装到华为平板时报错**：

```
error: failed to install bundle. code:9568257 error: fail to verify pkcs7 file.
```

设备端 hilog 给出根因：

```
E C011FE/foundation/HapVerify: it do not come from trusted root,
  issuer: C=CN, O=OpenHarmony, OU=OpenHarmony Team, CN=OpenHarmony Application Root CA
E C011FE/foundation/HapVerify: get cert chain for signInfo failed
E C01121/foundation/BMSInstaller: hap files check signature info failed
```

**结论：签名本身没问题，问题在设备的信任根。**
华为商用设备只信任华为签发的证书，不接受 OpenHarmony 社区调试证书。

> 判断依据：设备 `const.product.model = TGR-W10`（HUAWEI MatePad 11.5''S），
> 固件版本 `6.1.0.135(SP9C00E125R2P3)` —— 华为固件版本号格式。
> 虽然内核报 `OpenHarmony-6.1.1.120`，但信任链由华为管控。

### 尝试二：DevEco 自动签名（成功）

官方文档：https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-signing-auto

DevEco 会向华为申请绑定调试设备 UDID 的调试证书，写入 `build-profile.json5`：

```json5
"signingConfigs": [{
  "name": "default",
  "type": "HarmonyOS",
  "material": {
    "certpath": ".../.ohos/config/default_<项目名>_<hash>.cer",
    "keyAlias": "debugKey",
    "profile":   ".../.ohos/config/default_<项目名>_<hash>.p7b",
    "storeFile": ".../.ohos/config/default_<项目名>_<hash>.p12",
    "signAlg": "SHA256withECDSA",
    "keyPassword": "<加密值>",
    "storePassword": "<加密值>"
  }
}]
```

**配置一次之后**，命令行构建也会自动使用这套签名，产出可直接安装的 HAP。

自动签名需要登录华为开发者账号（免费注册）。

---

## 六、构建踩过的坑

### 坑 1：工程路径不能含中文

hvigor 会直接拒绝：

```
Error: Invalid project path. Current path does not match: ...
* Try: Please modify the project path to ensure that it only contains letters,
  digits, hyphens (-), underscores (_), periods (.), english parentheses (()),
  spaces, or the @ symbol
```

→ 工程必须放在**纯英文路径**下。

### 坑 2：命令行构建必须设 `DEVECO_SDK_HOME`

`local.properties` 里的 `sdk.dir` 对 hvigor 不生效：

```
Error Message: Invalid value of 'DEVECO_SDK_HOME' in the system environment path.
```

→ 构建前必须 `$env:DEVECO_SDK_HOME = "D:\DevEco Studio\sdk"`

### 坑 3：模块的 `hvigorfile.ts` 必须用 `hapTasks`

```
Error Message: Cannot find hvigor task 'assembleHap' in module 'entry'
```

```typescript
// entry/hvigorfile.ts  ← 必须这样
import { hapTasks } from '@ohos/hvigor-ohos-plugin';
export default { system: hapTasks, plugins: [] }
```

### 坑 4：`AppScope` 的 string.json 只能有一个根成员

```
Error Message: The node 'root' in the JSON file can only have one member.
```

应用级资源文件里**只能放 `app_name`**，其它字符串放模块级
`entry/src/main/resources/base/element/string.json`。

### 坑 5：版本号里的括号决定运行时类型

从 hvigor 源码读到的判断逻辑：

```javascript
runtimeOS ? valueOf(runtimeOS)
  : compatibleSdkVersion && !compatibleSdkVersion.toString().includes("(")
    ? RuntimeTypeEnum.OpenHarmony : RuntimeTypeEnum.HarmonyOS
```

→ **`"6.1.1(24)"`（带括号）= HarmonyOS；`24`（纯数字）= OpenHarmony**。
华为设备必须用带括号的格式。

### 坑 6：JSON5 里的 Windows 路径必须写双反斜杠

```
JSON5: invalid character '1'. At file: build-profile.json5:19:33
```

或者更隐蔽——构建一路走到签名才失败，且报出的路径少了一段：

```
Invalid storeFile value. The file must be included in
'C:\Users\<用户>\.ohosconfigdefault_SteelQC_....p12'
                         ↑ .ohos\config\ 的反斜杠没了
```

**原因**：JSON / JSON5 里反斜杠是转义字符。`\U`、`\c`、`\.` 都不是合法转义，
反斜杠直接被吞掉。

**正确写法**：`"certpath": "C:\\Users\\<用户>\\.ohos\\config\\default_xxx.cer"`

**教训**：别手工敲路径，整段复制现成配置，或让 DevEco 自动生成。

### 坑 7：复制过的工作区会把旧构建缓存一起带过来

**现象**：`app\` 目录从别处复制而来，构建时报

```
Tools execution failed.
Error Message: Failed to delete the directory or file
'...\intermediates\res\default\resources\rawfile\neu_det_yolov8n.ms', No error.
```

**判据**：看 `entry\build\` 里文件的时间戳，比本次构建早很多，就是旧工作区残留。

**解法**：删掉 `entry\build` 和 `.hvigor` 再构建（都在 `.gitignore` 内，删除安全）。

> 也可能是杀毒软件实时扫描临时锁住了刚生成的大文件（本项目模型 12 MB），
> 这种情况下稍等重试即可，不一定要删目录。

---

## 七、端侧 AI 能力（API 存在，但`TGR-W10` NPU 实测未跑通）

SDK 声明文件 `@ohos.ai.mindSporeLite.d.ts` 中存在 NPU 相关接口：

```typescript
enum NNRTDeviceType                              // NPU 设备类型
interface NNRTDeviceDescription                  // NPU 设备描述
function getAllNNRTDeviceDescriptions(): NNRTDeviceDescription[]
enum PerformanceMode                             // 性能模式
```

**API 齐全，设备也能枚举出加速器**（实测 `设备总数: 1`，`type=ACCELERATOR(3) name=HIAI_F`），
但 2026-10-13 真机实测确认 **NPU 推理跑不通**：设备名 `HIAI_F` 不被 MindSpore Lite
的 NPU 路径接受，自动回退 CPU。

> ⚠️ **注意失败的形态是「假成功」，不是报错。**
> `loadModelFromBuffer()` 在 NPU 路径下**会返回一个非空对象**，
> 只有 `getInputs()` 才返回 `undefined`（底层原生模型为空）。
> **不能靠"有没有抛异常"判断 NPU 是否可用。**
>
> 这条已实测：`nnrt` 给 deviceID / 不给 / 空对象 / `['kirin_npu']` / `['npu']`
> 六种组合结果**完全一致**——ArkTS 层对无效参数不校验、不报错。
> 详见根目录 `README.md` 的「补充实测」一节。

> 完整日志与因果链见仓库根目录 `README.md` 的「NPU 问题的如实记录」。
> **结论：这条路的阻塞在 SDK / ROM 层，应用侧改不动。**

### 诊断工具：`model/NpuProbe.ets`

排查 NPU 时不必重写探针，仓库里已经有一个（`NPU_DIAGNOSTIC` 开关控制，**默认关闭**）。
打开方式：

```typescript
// entry/src/main/ets/pages/Index.ets
private readonly NPU_DIAGNOSTIC: boolean = true;   // 默认 false
```

重新构建装机后抓日志：

```powershell
$Hdc = "D:\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"

& $Hdc shell "hilog -b E"      # ⚠️ 关键：全局日志压到 ERROR
& $Hdc shell "hilog -G 16M"    # 缓冲区开到最大
& $Hdc shell hilog -r
& $Hdc shell aa force-stop com.zjsrtp.steelqc
& $Hdc shell aa start -a EntryAbility -b com.zjsrtp.steelqc
& $Hdc shell "hilog -x -L I" | Select-String NPUPROBE
```

> **为什么必须压日志级别**：不压的话，系统的 INFO 洪流会把诊断输出从缓冲区挤出去。
> 我第一次跑就只抓到 2 行（首尾各一行，中间全被冲掉）。
> 压到 ERROR 后系统噪音消失，但应用自己的 INFO 仍能输出，诊断完整可见。

```
best.pt ──> .onnx ──[MindSpore Lite 转换工具]──> .ms
                                                    ↓
                            entry/src/main/resources/rawfile/
                                                    ↓
                    ArkTS 用 mindSporeLite.loadModelFromBuffer() 加载
```

> ⚠️ **转换器版本不能高于设备推理引擎的版本。**
> 本项目的 `.ms` 由 2.10.0 转换，而设备引擎是 2.7.0，设备端会警告：
>
> ```
> The current model version MindSpore Lite 2.10.0 is later than
> the inference engine version MindSpore Lite 2.7.0.
> ```
>
> 排查 NPU 问题时这是必须一并排除的变量。

> **实测耗时超预期时，先确认实际用的是哪个后端**，不要直接归因于算子回退。
> 本项目 276 ms 是**CPU 后端**的成绩；设备会把「哪个后端生效」打进日志
> （`已回退 CPU（后端结果: N）`），以日志为准。

---

## 八、常用命令速查

```powershell
$Hdc = "D:\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"

& $Hdc list targets                    # 列出设备
& $Hdc shell bm get -u                 # 获取 UDID
& $Hdc install -r <hap路径>            # 安装
& $Hdc uninstall com.zjsrtp.steelqc    # 卸载
& $Hdc shell aa start -a EntryAbility -b com.zjsrtp.steelqc

& $Hdc shell hilog | Select-String SteelQC     # 应用日志

# 排查安装失败（签名问题必看）
& $Hdc shell "hilog -x | grep -i -E 'HapVerify|BMSInstaller' | tail -30"

# 截图（后缀必须是 .jpeg，写成 .png 会报 invalid）
& $Hdc shell snapshot_display -f /data/local/tmp/shot.jpeg
& $Hdc file recv /data/local/tmp/shot.jpeg ./shot.jpeg
```