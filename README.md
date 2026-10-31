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
- **淡入淡出**：休息界面以 0.5–3 秒（默认 0.5 秒）淡入和淡出，开启“减弱动态效果”时直接显示和隐藏。
- **八种语言**：英语（默认）、简体中文、繁體中文、日本語、한국어、Español、Français、Português（葡萄牙）。
- **可选登录启动**：在设置中启用，由 macOS 管理登录项。
- **支持开发**：在设置的“支持”页面可通过 App 内购买留下小费（三档消耗型项目）。小费完全自愿，不解锁任何功能。

### 默认设置

| 项目 | 默认值 |
| --- | --- |
| 短休息 | 工作 20 分钟，休息 20 秒 |
| 长休息 | 工作 60 分钟，休息 5 分钟 |
| 启用与跳过 | 两种休息均启用，均允许跳过 |
| 背景 | 不透明纯色 |
| 淡入、淡出 | 各 0.5 秒 |
| 界面语言 | 英语，可在设置中切换 |
| 登录启动 | 关闭 |

工作间隔不包含休息和暂停时间。两种休息同时到期时优先长休息；完成长休息后重新开始两种工作间隔。跳过长休息不会取消已经到期的短休息。每次重新启动应用都会开始新的计时周期。

## 系统要求与当前状态

- **Apple Silicon Mac**，仅构建 `arm64`，不支持 Intel Mac。
- **macOS 26 或更高版本**为部署目标；目前在 macOS 27.0.1 上开发和验证，尚未验证 macOS 26。
- 已验证的开发工具链：**Xcode 27.1、Swift 6.4、macOS 27.0 SDK**。

当前首版已可在本地构建和运行，自动化测试通过，但正式发布验收尚未完成。项目已为 Mac App Store 上架做好准备（沙盒、隐私清单、出口合规声明、App 内购买和归档脚本），但尚未进行分发签名或上传，这一步需要付费的 Apple Developer Program 账户。未选择开发团队时，项目使用自动签名下的本地运行签名（Sign to Run Locally），无需证书即可构建和测试。尚未提供 Developer ID 公证版本或 DMG 安装包。

详细行为见[实施方案](docs/implementation-plan.md)，已验证结果和待验证项目见[验证报告](docs/validation-report.md)，上架步骤见 [App Store 发布指南](docs/app-store-release.md)。

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

Swift Testing 测试覆盖调度规则、过期回调防护、暂停与系统离开、设置校验与恢复、图片布局与导入解码、本地化覆盖和占位符一致性，以及小费的加载、取消、等待批准和失败处理。当前共有 **7 个测试套件、125 个测试函数**，其中部分为参数化测试。

测试以应用为宿主运行，但不会启动正常调度或显示菜单栏图标。测试使用独立的 `UserDefaults` 和临时目录，不修改日常设置。小费测试通过 `SKTestSession` 使用本地 StoreKit 配置 `TimeBreaker/TimeBreaker.storekit` 加载产品，不需要开发者账户，也不进行购买；购买流程请在 Xcode 中运行应用测试。

仍需人工验证的场景包括真实键鼠交互、VoiceOver、睡眠与唤醒、登录项注册，以及部分显示器和窗口环境。全屏覆盖也可能被同级别的第三方窗口局部遮挡，不能视为系统锁定。完整清单见[验证报告](docs/validation-report.md)。

## App 内购买与 App Store 发布

“支持”页面提供三档消耗型 App 内购买：

| 产品 ID | 本地测试价格 |
| --- | --- |
| `com.acgso.timebreaker.tip.small` | $0.99 |
| `com.acgso.timebreaker.tip.medium` | $2.99 |
| `com.acgso.timebreaker.tip.large` | $4.99 |

产品只在打开“支持”页面时加载。小费名称跟随应用语言，价格来自 App Store。每笔交易到达后立即完成（finish），应用启动时也会监听并完成此前未完成的交易。消耗型项目无需“恢复购买”。正式价格在 App Store Connect 中设置，产品 ID 必须与 `TipJar.Tier` 和 `TimeBreaker.storekit` 保持一致。

在 Xcode 中运行应用时，共享 scheme 会使用 `TimeBreaker.storekit`，免费账户即可在本地测试购买流程。可通过 **Debug → StoreKit → Manage Transactions** 查看或删除测试交易。

升级为付费开发者账户后，按照 [App Store 发布指南](docs/app-store-release.md) 创建 App 记录和 App 内购买项目，然后归档并上传：

```sh
# 付费团队 ID 显示在 Xcode → Settings → Accounts 中，与 Personal Team 的 ID 不同
TEAM_ID=<团队 ID> BUILD_NUMBER=1 scripts/archive-app-store.sh          # 导出签名的 .pkg 到 build/AppStore/Export
TEAM_ID=<团队 ID> BUILD_NUMBER=1 scripts/archive-app-store.sh upload   # 直接上传到 App Store Connect
```

每次上传都需要更大的构建号。指南中还包括 App 审核备注模板、隐私标签填写说明，以及[隐私政策草稿](docs/privacy-policy.md)；隐私政策需要先填写联系方式并发布到公开网址。

## 资源占用

调度使用单个 `ContinuousClock` 截止时间等待任务，后台等待期间不进行逐秒轮询。倒计时仅在休息界面可见或菜单打开时刷新，菜单栏图标保持静态。设置持久化不包含每秒倒计时。

开发机上的一次 Release 实测（M1 Pro、双显示器、接通电源）显示：

- 20 分钟工作等待期间，累计 CPU 时间增加约 **0.04 秒**，空闲唤醒为 **0 次**。
- 首次休息前内存占用约 **14–16 MB**，首次休息后约 **21–23 MB**。
- 3600 万像素 HEIC 背景在连续多次休息结束后回落至约 **22–29 MB**。

这些是特定环境中的测量结果，不代表所有设备。电池供电、低电量模式、GPU 能耗和数小时连续运行尚未测量，方法和数据见[验证报告](docs/validation-report.md)。

## 设置与数据

- 偏好设置保存在应用沙盒中的 `UserDefaults`。
- 导入图片会复制到 `~/Library/Containers/com.acgso.timebreaker/Data/Library/Application Support/Backgrounds/`，原始文件不会被修改，移动或删除原图不影响已导入背景。
- 应用启用了 App Sandbox，仅申请用户选择文件的只读访问权限，不申请网络、屏幕录制或全局输入监听权限。
- App 内购买由 Apple 通过 StoreKit 处理。应用不保存或上传购买信息，隐私清单 `PrivacyInfo.xcprivacy` 声明不追踪、不收集数据。
- 如需重置全部设置和已导入图片，先退出应用，再删除 `~/Library/Containers/com.acgso.timebreaker`。此操作会清除应用数据，macOS 可能要求访问授权。

## 诊断启动参数

以下参数用于复现和验证运行行为，仅在本次启动中覆盖设置，不自动保存。但如果在同一次运行中修改设置，应用会保存当时的完整设置状态。

| 参数 | 作用 |
| --- | --- |
| `-TBShortWorkSeconds N`、`-TBLongWorkSeconds N` | 工作间隔，单位为秒 |
| `-TBShortBreakSeconds N`、`-TBLongBreakSeconds N` | 休息时长，单位为秒 |
| `-TBShortAllowsSkip NO`、`-TBLongAllowsSkip NO` | 禁止跳过对应休息 |
| `-TBTransparency N` | 背景透明度，0–99 |
| `-TBFadeInSeconds N`、`-TBFadeOutSeconds N` | 淡入、淡出时长，单位为秒，0.5–3 |
| `-TBColor RRGGBB` | 背景颜色 |
| `-TBBackgroundImage PATH` | 导入沙盒可读取的图片，例如 `/System/Library/Desktop Pictures` 中的图片 |
| `-TBLayout stretch\|center\|scaleToFit` | 图片布局 |
| `-TBLanguage ID` | 界面语言，例如 `zh-Hans`、`ja` 或 `pt-PT` |
| `-TBSettingsTab breaks\|appearance\|general\|support` | 打开设置时显示的页面 |
| `-TBSchedulingActivity YES` | 等待期间限制 App Nap，仅用于诊断，默认关闭 |

例如，10 秒后显示一次禁止跳过的 15 秒短休息：

```sh
open -n build/Release/TimeBreaker.app --args \
  -TBShortWorkSeconds 10 -TBShortBreakSeconds 15 -TBShortAllowsSkip NO
```

查看调度、界面呈现和覆盖诊断日志：

```sh
log stream --style compact --predicate 'subsystem == "com.acgso.timebreaker"'
```

## 项目结构

| 路径 | 内容 |
| --- | --- |
| `TimeBreaker/App` | 应用入口、菜单栏和主菜单、登录项、诊断参数 |
| `TimeBreaker/Scheduling` | 确定性调度规则、截止时间等待、系统活动监听 |
| `TimeBreaker/Overlay` | 各显示器的覆盖窗口及 SwiftUI 休息界面 |
| `TimeBreaker/Appearance` | 图片布局、导入及有尺寸限制的解码 |
| `TimeBreaker/Settings` | 设置模型、持久化和设置窗口 |
| `TimeBreaker/Store` | App 内购买（小费）及交易处理 |
| `TimeBreaker/Localization` | 语言选择、字符串键及查找 |
| `TimeBreaker/Resources` | 字符串目录 `Localizable.xcstrings`、资源目录和隐私清单 |
| `TimeBreakerTests` | Swift Testing 测试套件 |
| `scripts` | Mac App Store 归档、导出和上传脚本 |
| `docs` | 技术调研、实施方案、验证报告、App Store 发布指南和隐私政策草稿 |

首版范围不包含 Intel 构建、Developer ID 签名、公证、DMG 打包、云服务或动态背景。App Store 上架的准备工作已完成，正式提交需要付费开发者账户。
