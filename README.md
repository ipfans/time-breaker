# Time Breaker

Time Breaker 是一款原生 macOS 菜单栏休息提醒应用。它在后台运行，到达设定时间后，在所有显示器上显示全屏休息界面和倒计时，提醒你站起来、远离屏幕。

使用 Swift 6、AppKit 和 SwiftUI 构建，无第三方依赖。启动后自动开始计时，关闭设置窗口不会退出应用。

## 功能

- **短休息与长休息**：分别设置启用状态、工作间隔、休息时长和是否允许跳过。
- **多显示器提醒**：每个显示器显示独立的全屏覆盖窗口，共享同一次休息和倒计时。
- **暂停与继续**：暂停时保留剩余时间并隐藏休息界面，继续后从剩余时间恢复。
- **禁止跳过**：可分别关闭两种休息的“跳过”按钮；暂停和正常退出始终可用。
- **自然休息计入**：根据系统睡眠、显示器睡眠和会话切换事件计算离开时间，达到条件后计入休息；手动暂停本身不计入。
- **自定义背景**：纯色或 PNG、JPEG、HEIC 静态图片，支持拉伸、居中、等比适应，以及 0–99% 背景透明度；文字和按钮保持清晰可读。
- **八种语言**：英语（默认）、简体中文、繁體中文、日本語、한국어、Español、Français、Português（葡萄牙）。
- **可选登录启动**：在设置中启用，由 macOS 管理登录项。

### 默认设置

| 项目 | 默认值 |
| --- | --- |
| 短休息 | 工作 20 分钟，休息 20 秒 |
| 长休息 | 工作 60 分钟，休息 5 分钟 |
| 启用与跳过 | 两种休息均启用，均允许跳过 |
| 背景 | 不透明纯色 |
| 界面语言 | 英语，可在设置中切换 |
| 登录启动 | 关闭 |

工作间隔不包含休息和暂停时间。两种休息同时到期时优先长休息；完成长休息后重新开始两种工作间隔。跳过长休息不会取消已经到期的短休息。每次重新启动应用都会开始新的计时周期。

## 系统要求与当前状态

- **Apple Silicon Mac**，仅构建 `arm64`，不支持 Intel Mac。
- **macOS 26 或更高版本**为部署目标；目前在 macOS 27.0.1 上开发和验证，尚未验证 macOS 26。
- 已验证的开发工具链：**Xcode 27.1、Swift 6.4、macOS 27.0 SDK**。

当前首版已可在本地构建和运行，自动化测试通过，但正式发布验收尚未完成。应用使用本地临时签名（Sign to Run Locally），无需 Developer ID 证书；尚未提供公证、DMG 安装包或 App Store 版本。

详细行为见[实施方案](docs/implementation-plan.md)，已验证结果和待验证项目见[验证报告](docs/validation-report.md)。

## 构建与运行

在仓库根目录执行：

```sh
# Debug 构建
xcodebuild -project TimeBreaker.xcodeproj -scheme TimeBreaker -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData build

# Release 构建
xcodebuild -project TimeBreaker.xcodeproj -scheme TimeBreaker -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData build
```

构建产物位于 `build/DerivedData/Build/Products/<Configuration>/TimeBreaker.app`。复制 Release 应用到固定位置并启动：

```sh
ditto build/DerivedData/Build/Products/Release/TimeBreaker.app build/Release/TimeBreaker.app
open build/Release/TimeBreaker.app
```

也可以在 Xcode 中打开 `TimeBreaker.xcodeproj`，选择共享的 **TimeBreaker** scheme 进行构建和运行。

应用没有 Dock 图标。点击菜单栏中的杯子图标，可以查看下次休息时间、暂停或继续、打开设置及退出。在 Finder 中再次打开应用也会显示设置窗口。

登录启动位于设置的“通用”页面。建议先将 Release 应用复制到 `/Applications` 再启用；从构建目录运行时，登录项可能不可用。macOS 可能要求在“系统设置 → 通用 → 登录项”中批准。

## 测试与验证

```sh
xcodebuild -project TimeBreaker.xcodeproj -scheme TimeBreaker \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData test
```

Swift Testing 测试覆盖调度规则、过期回调防护、暂停与系统离开、设置校验与恢复、图片布局与导入解码、本地化覆盖和占位符一致性。当前验证报告记录了 **6 个测试套件、107 个测试函数**，其中部分为参数化测试。

测试以应用为宿主运行，但不会启动正常调度或显示菜单栏图标。测试使用独立的 `UserDefaults` 和临时目录，不修改日常设置。

仍需人工验证的场景包括真实键鼠交互、VoiceOver、睡眠与唤醒、登录项注册，以及部分显示器和窗口环境。全屏覆盖也可能被同级别的第三方窗口局部遮挡，不能视为系统锁定。完整清单见[验证报告](docs/validation-report.md)。

## 资源占用

调度使用单个 `ContinuousClock` 截止时间等待任务，后台等待期间不进行逐秒轮询。倒计时仅在休息界面可见或菜单打开时刷新，菜单栏图标保持静态。设置持久化不包含每秒倒计时。

开发机上的一次 Release 实测（M1 Pro、双显示器、接通电源）显示：

- 20 分钟工作等待期间，累计 CPU 时间增加约 **0.04 秒**，空闲唤醒为 **0 次**。
- 首次休息前内存占用约 **14–16 MB**，首次休息后约 **21–23 MB**。
- 3600 万像素 HEIC 背景在连续多次休息结束后回落至约 **22–29 MB**。

这些是特定环境中的测量结果，不代表所有设备。电池供电、低电量模式、GPU 能耗和数小时连续运行尚未测量，方法和数据见[验证报告](docs/validation-report.md)。

## 设置与数据

- 偏好设置保存在应用沙盒中的 `UserDefaults`。
- 导入图片会复制到 `~/Library/Containers/com.ipfans.TimeBreaker/Data/Library/Application Support/Backgrounds/`，原始文件不会被修改，移动或删除原图不影响已导入背景。
- 应用启用了 App Sandbox，仅申请用户选择文件的只读访问权限，不申请网络、屏幕录制或全局输入监听权限。
- 如需重置全部设置和已导入图片，先退出应用，再删除 `~/Library/Containers/com.ipfans.TimeBreaker`。此操作会清除应用数据，macOS 可能要求访问授权。

## 诊断启动参数

以下参数用于复现和验证运行行为，仅在本次启动中覆盖设置，不自动保存。但如果在同一次运行中修改设置，应用会保存当时的完整设置状态。

| 参数 | 作用 |
| --- | --- |
| `-TBShortWorkSeconds N`、`-TBLongWorkSeconds N` | 工作间隔，单位为秒 |
| `-TBShortBreakSeconds N`、`-TBLongBreakSeconds N` | 休息时长，单位为秒 |
| `-TBShortAllowsSkip NO`、`-TBLongAllowsSkip NO` | 禁止跳过对应休息 |
| `-TBTransparency N` | 背景透明度，0–99 |
| `-TBColor RRGGBB` | 背景颜色 |
| `-TBBackgroundImage PATH` | 导入沙盒可读取的图片，例如 `/System/Library/Desktop Pictures` 中的图片 |
| `-TBLayout stretch\|center\|scaleToFit` | 图片布局 |
| `-TBLanguage ID` | 界面语言，例如 `zh-Hans`、`ja` 或 `pt-PT` |
| `-TBSettingsTab breaks\|appearance\|general` | 打开设置时显示的页面 |
| `-TBSchedulingActivity YES` | 等待期间限制 App Nap，仅用于诊断，默认关闭 |

例如，10 秒后显示一次禁止跳过的 15 秒短休息：

```sh
open -n build/Release/TimeBreaker.app --args \
  -TBShortWorkSeconds 10 -TBShortBreakSeconds 15 -TBShortAllowsSkip NO
```

查看调度、界面呈现和覆盖诊断日志：

```sh
log stream --style compact --predicate 'subsystem == "com.ipfans.TimeBreaker"'
```

## 项目结构

| 路径 | 内容 |
| --- | --- |
| `TimeBreaker/App` | 应用入口、菜单栏和主菜单、登录项、诊断参数 |
| `TimeBreaker/Scheduling` | 确定性调度规则、截止时间等待、系统活动监听 |
| `TimeBreaker/Overlay` | 各显示器的覆盖窗口及 SwiftUI 休息界面 |
| `TimeBreaker/Appearance` | 图片布局、导入及有尺寸限制的解码 |
| `TimeBreaker/Settings` | 设置模型、持久化和设置窗口 |
| `TimeBreaker/Localization` | 语言选择、字符串键及查找 |
| `TimeBreaker/Resources` | 字符串目录 `Localizable.xcstrings` 和资源目录 |
| `TimeBreakerTests` | Swift Testing 测试套件 |
| `docs` | 技术调研、实施方案和验证报告 |

首版范围不包含 Intel 构建、Developer ID 签名、公证、DMG 打包、App Store 发布、云服务或动态背景。
