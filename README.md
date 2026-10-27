# V语 / VYu

**Watch it. Save it.**

项目愿景：**If you can watch it, you can download it.** 能看，就能下载。

V语是一款 iOS 网页视频浏览与离线管理应用。你可以在 App 内打开网页，选择某个播放器旁的“下载此视频”，将支持的视频保存到本机，随后离线播放、搜索和整理。

项目仍在开发中。能在网页播放的视频不一定能独立下载；保存结果取决于站点授权、链接有效期、媒体格式和系统能力。V语使用公开系统 API，不绕过 DRM 或站点访问控制。

## 功能

- **网页浏览**：输入网址、前进后退、网页收藏、访问历史及历史清理。网址输入框支持一键清空，并保留输入焦点。
- **逐视频下载**：为可识别的播放器提供独立入口，支持动态加载和 iframe 中的常见视频。优先采用该视频自身或所属卡片的标题，没有可靠标题时回退到页面标题。
- **离线管理**：显示下载进度、文件大小、时长与本机生成的预览图；完成校验后可离线播放，保留观看位置。
- **优化本地存储**：在离线页的“本地存储”中开启，视频缓存目标为 1 GB。优先保留收藏，同类优先保留最近更新的视频；只释放已确认上传到 iCloud 的旧副本，点击后重新下载播放。未同步或正在使用的视频会保留，可能暂时超出目标。
- **批量操作**：选择或全选当前筛选结果，批量继续、暂停；“全部继续”可恢复整个列表中符合条件的暂停任务。重复点击不会重复启动，已完成、失败和取消项不会自动重下。
- **下载时亮屏**：仅在 App 前台有实际下载活动时保持屏幕亮起；全部暂停、完成、失败或离开前台后恢复默认，不修改系统自动锁定设置。
- **视频整理**：支持重命名，按当前名称和标签搜索，收藏视频、编辑标签，组合使用搜索与收藏筛选。已下载的视频可拖动预览，选择某一帧作为封面，并恢复自动封面。详见[离线视频整理](docs/video-library.md)。
- **本机导入**：选择、预览并导入 MP4、MOV、M4V 视频，包括用户自行录制的视频；App 不提供自动录屏。
- **iCloud Documents**：同步符合条件的视频文件、预览图和必要元数据，并同步已归档视频的自定义名称、收藏、标签与封面位置。同步行为见下文。

## 使用方式

1. 在浏览页输入网址，打开并播放目标视频。需要登录的网页由用户在网页内完成登录。
2. 点击该播放器旁的“下载此视频”。准备结果和进度会出现在离线列表，当前网页保持打开。没有识别到独立入口时，可查看“视频来源”；来源数可能包含同一视频的多个画质。
3. 在“离线”查看状态。已完成的条目可以播放，三点菜单提供整理和管理操作。
4. 多个任务需要恢复时，点击“全部继续”；只操作部分任务时，进入“选择”模式。全选仅针对当前筛选中的本机条目，离开选择模式会清除勾选。

批量恢复最多同时占用两个任务槽位，已有活动下载也计入占用。其余任务等待执行，暂停等待中的任务可撤销继续操作。登录状态或来源已失效的条目会提示原因，需要回到网页重新获取有效来源。

## 下载支持与限制

| 来源 | 当前行为 |
| --- | --- |
| 可直接访问的完整视频文件 | 使用 URLSession 下载；符合条件的普通文件可交由系统后台传输。完成前检查文件和音视频资产。 |
| 需要 Cookie 的普通视频文件 | 在有效会话范围内下载，需保持 App 在前台；登录失效后需重新登录。 |
| 普通文件的网页会话重试 | 在适用的 401/403 失败提示中提供入口，使用同一个 WKWebView 的 WKDownload。仅前台，支持取消，不支持暂停、断点续传或后台保证。 |
| 完整、未加密的 HLS 点播 | 支持部分格式。可处理的 fMP4 由系统后台下载分片，返回前台后合成为 MP4；其他适用格式使用系统离线资产。保留音轨与完整性检查。 |
| 需要 Cookie 的 HLS、直播、DASH 离线封装、DRM 或加密内容 | 当前不支持。 |
| `blob:` 或 MSE 播放器 | 只能尝试识别其真实媒体来源；临时地址、初始化文件或单个分片不能当作完整视频保存。 |

支持的 fMP4 HLS 会保存下载计划和已完成分片，暂停后继续时复用这些分片。合成与校验在前台完成；未完成的分片不会显示成可播放视频。后台请求不携带网页 Cookie、来源页或登录凭据；服务器要求网页会话时退回前台路径。其他需要本机网页中转的 HLS 仍需保持前台。iOS 决定后台任务的调度，用户强制结束 App 可能取消传输，重新打开后才会恢复缺失分片。

只有页面明确提供同一视频的 MP4 来源时，才可能显示 HLS 的 MP4 备选；不会猜测地址、签名或关联相邻视频。标题提取依赖网页结构，特殊布局仍可能回退到页面标题。

## 隐私与数据

网页内容由 WebKit 加载，登录会话由 WebKit 管理。下载在已有授权范围内使用所需的 User-Agent、来源策略和 Cookie，并在重定向时检查 Cookie 的作用域。网页登录不代表所有下载方式都已获得支持。

浏览历史、网页收藏、观看位置、下载来源与恢复资料保存在本机。导入使用系统选择器，只读取用户选中的视频。当前项目没有接入第三方统计或广告 SDK；访问网页和下载视频仍会向对应站点及其资源服务器发送请求。

工程允许访问用户输入的 HTTP/HTTPS 地址。HTTP 不提供传输加密；HTTPS 仍由系统校验证书。

### iCloud 同步

在启用 iCloud 的构建中，配置好云能力、设备登录账号且容器可用时，App 启动及回到前台会检查同步状态，并自动准备已有和新完成的合格视频。**当前没有 App 内的同步开关，也不是仅在点击上传后才同步。** 上传由系统调度，以界面的“已同步到 iCloud”为准。下文的个人团队本机模式在构建时明确关闭原生云同步，不改变正常构建的默认行为。

- 云端保存已验证的视频文件、可用预览图，以及标题、来源域名、时长、音轨等必要元数据；已归档视频的自定义名称、收藏、标签和封面位置独立同步，改名或修改封面不重传视频。
- 不把原始媒体 URL、签名参数、Cookie、下载恢复资料、浏览历史、网页收藏或观看位置放入应用的 iCloud 文档同步。
- 系统 HLS `.movpkg` 包不直接同步。已有包可能重新请求来源并生成 MP4；验证成功后才替换，失败时保留原视频。
- 云端视频可先显示列表，点击后下载并校验，再播放。“删除本机缓存”保留云端副本；“从所有设备删除”需要确认。
- iCloud 取回请求保存在本机并绑定账号，媒体传输由系统继续调度；回到前台后校验、导入，离开 App 后不再自动播放。取消取回会撤销待导入任务，已经交给系统的传输不保证立即停止。
- 优化存储仅清理已经确认上传、云端副本与本机内容一致且无冲突的视频；未上传成功的视频保留，允许本机缓存暂时超过 1 GB。
- 切换 iCloud 账号后需要确认继续同步，旧账号的视频不会自动上传到新账号。

本地模拟同步测试不能代替真实 iCloud 服务或多设备验收，跨设备传播与异常场景仍需持续验证。

## 开发环境

| 工具或平台 | 要求 |
| --- | --- |
| macOS 与 Xcode | 安装完整 Xcode、iOS SDK 和模拟器运行时。当前开发环境为 Xcode 26.6，最低兼容 Xcode 版本尚未系统验证。 |
| 部署目标 | iOS 17.0 起；工程包含 iPhone 和 iPad 设备族。主要回归在 iPhone 模拟器完成，旧系统与 iPad 布局尚未全面验收。 |
| Swift | 工程使用 Swift 5 语言模式，编译器随 Xcode 提供。 |
| XcodeGen | 修改工程配置或增删源文件后用于重新生成工程；已有工程可直接打开。 |
| Python 3.9 或更高、FFmpeg、ffprobe | 仅用于开发测试。Python 脚本使用标准库；FFmpeg 需包含 libx264 和 AAC 编解码能力。 |

App 使用 SwiftUI、Combine、WebKit、URLSession、AVFoundation/AVKit、PhotosUI 和 iCloud Documents。当前没有第三方 Swift Package 依赖，运行时不依赖 Python、FFmpeg、Mac 或开发测试服务器。

## 构建

以下命令均在仓库根目录执行。

`project.yml` 是工程配置来源，`VYu.xcodeproj` 已纳入版本管理。`Config/Build.xcconfig` 提供公共默认值，并可选读取被 Git 忽略的 `Config/Local.xcconfig`。无需个人配置也能构建模拟器版本。修改配置或增删源码后执行：

```sh
xcodegen generate
```

### 没有开发者证书：使用模拟器

无需 Apple 开发者账号、开发证书或 provisioning profile。打开 `VYu.xcodeproj`，选择 `VYu` Scheme 和 iOS 模拟器；也可从命令行构建：

```sh
xcodebuild -project VYu.xcodeproj -scheme VYu \
  -configuration Release -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath work/ReleaseCheck \
  CODE_SIGN_IDENTITY=- build
```

`CODE_SIGN_IDENTITY=-` 使用本地 ad hoc 签名，不依赖开发者证书。这与面向注册真机的 Ad Hoc 分发不同。[Apple 的 ad hoc 签名说明](https://developer.apple.com/documentation/security/seccodesignatureflags/adhoc)

上面的命令只构建，不会自动运行 App。在 Xcode 中选中模拟器后按 Run 可运行；测试命令见下一节。后台下载相关测试保留 ad hoc 签名，项目实测未签名 App 的后台下载服务可能无法工作。

只检查能否编译、完全跳过签名时，可运行以下命令。这个产物不作为运行或下载测试依据：

```sh
xcodebuild -project VYu.xcodeproj -scheme VYu \
  -configuration Release -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath work/UnsignedCompileCheck \
  CODE_SIGNING_ALLOWED=NO build
```

### 免费 Apple Account：个人团队真机测试

在 Xcode 中登录自己的 Apple Account 后，可以使用 Personal Team 进行有限的真机开发测试。免费团队不支持 iCloud Documents 或 CloudKit，因此必须显式使用下列本机模式，不能直接沿用完整云权限。[Apple 账号说明](https://developer.apple.com/help/account/basics/about-your-developer-account/)、[iOS 能力支持表](https://developer.apple.com/help/account/reference/supported-capabilities-ios/)

先创建自己的本机配置；若文件已存在，应编辑现有文件，不要覆盖：

```sh
test -e Config/Local.xcconfig || cp Config/Local.xcconfig.example Config/Local.xcconfig
```

在 `Config/Local.xcconfig` 中填写自己的团队 ID 和唯一 Bundle ID，并选择本机模式：

```xcconfig
VYU_DEVELOPMENT_TEAM = YOUR_PERSONAL_TEAM_ID
VYU_BUNDLE_IDENTIFIER = com.example.yourname.vyu
VYU_SIGNING_ENTITLEMENTS = Config/LocalOnly.entitlements
VYU_ICLOUD_ENABLED = NO
```

`YOUR_PERSONAL_TEAM_ID` 和示例 Bundle ID 必须替换。`LocalOnly.entitlements` 不请求 iCloud 权限，`NO` 同时停止原生云账号、容器查询和同步；浏览、下载、本机导入与离线管理仍可使用。合成云端测试保留独立的临时目录通道。

打开工程后，在 Signing & Capabilities 中核对解析后的 Personal Team、Bundle ID 和自动签名，选择自己的设备运行。证书和描述文件由 Xcode 管理；设备要求的解锁、信任和 Developer Mode 需本人按系统提示完成。不要把个人值写回 `project.yml` 或生成工程。

Apple 当前列出的 Personal Team 限制为最多 10 个 App ID、3 台设备、每台设备 3 个 App；App ID 和设备注册有效期为 7 天，描述文件自签发起 7 天到期，到期需重新构建安装。这是个人开发测试路径，不是应用分发方案。[官方限制](https://developer.apple.com/help/account/basics/about-your-developer-account/)

### 有相应开发者团队权限：完整 iCloud 构建

本项目使用 **iCloud Documents**，不是 CloudKit。真机使用这些云能力需要加入支持该能力的 Apple 开发者团队，并取得对应 App ID、容器和描述文件的权限；免费个人团队不具备这些能力。[官方能力表](https://developer.apple.com/help/account/reference/supported-capabilities-ios/)

1. 在被忽略的 `Config/Local.xcconfig` 中填写自己的 `VYU_DEVELOPMENT_TEAM`、`VYU_BUNDLE_IDENTIFIER`，使用 `VYU_SIGNING_ENTITLEMENTS = App/VYu.entitlements`、`VYU_ICLOUD_ENABLED = YES`。
2. 为自己的 App ID 配置 iCloud Documents，并关联有权使用的容器。仓库中的 Bundle ID 和容器名只是项目默认标识，不授予其他团队访问权限。
3. Fork 使用不同容器时，一致修改 `App/VYu.entitlements` 的 iCloud/ubiquity 标识、`project.yml` 的 `NSUbiquitousContainers` 字典键，以及 `App/Cloud/CloudVideoSync.swift` 的 `containerIdentifier`；执行 `xcodegen generate` 更新工程和 Info.plist。权限文件为手工维护，不再由生成器覆盖。
4. 在 Xcode 中核对团队、权限及描述文件。使用已有签名材料的命令行构建示例如下；若材料尚未配置，先由本人在 Xcode 中处理，不通过删除云权限来伪装完整构建成功。

```sh
xcodebuild -project VYu.xcodeproj -scheme VYu \
  -configuration Release -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath work/DeviceBuild build
```

此命令只生成真机包，不安装或分发，也不自动申请新的描述文件。真实云端验收还需要本人启用 iCloud Drive，并检查上传、取回和多设备传播。[Apple iCloud 配置说明](https://developer.apple.com/documentation/xcode/configuring-icloud-services)

### 本机配置与公开文件

`Config/Local.xcconfig` 仅保存本机覆盖值，加入 `.gitignore`；公开模板只使用 `VYU_` 变量。不要在 YAML 中用环境变量直接展开个人团队值，也不要将本机文件加入工程文件组，以免生成工程重新包含私人配置。检查时可运行 `git check-ignore Config/Local.xcconfig` 和 `git diff --check`。签名材料、构建日志及备份放在忽略目录，不提交到仓库。

## 测试与本地演示

测试素材由本机 FFmpeg 生成，使用图案和合成音频，不需要真实网页、登录账号或个人视频。生成媒体与构建产物不纳入 Git。

在一个终端运行：

```sh
python3 scripts/fixture_generate.py
python3 scripts/fixture_test.py
python3 fixtures/server.py
```

前两条分别生成媒体、检查测试服务；最后一条持续提供 HTTP 服务，默认绑定 `127.0.0.1` 的 8765 和 8766 端口。结束后可按 Ctrl-C 停止。页面说明见[受控网页与媒体](fixtures/README.md)。

使用 Xcode 新建专用测试模拟器，避免与日常使用的数据混用。在另一个终端列出可用模拟器：

```sh
xcrun simctl list devices available
```

将下面的 UUID 替换成该测试模拟器的标识，保持服务运行，再执行单元、集成和 UI 测试：

```sh
VYU_SIMULATOR_ID='<专用模拟器 UUID>'

xcodebuild -project VYu.xcodeproj -scheme VYu \
  -sdk iphonesimulator \
  -destination "platform=iOS Simulator,id=$VYU_SIMULATOR_ID" \
  -derivedDataPath work/DerivedData \
  -resultBundlePath work/LocalTests.xcresult \
  CODE_SIGN_IDENTITY=- \
  -parallel-testing-enabled NO \
  -skip-testing:VYuTests/PublicTwitterPlaybackTests \
  -skip-testing:VYuTests/PublicCloudRoundTripTests \
  test
```

重复运行时，为 `-resultBundlePath` 使用新的目录名。两个排除项是单独启用的公开网络和真实 iCloud 探针，不属于本地回归；本地云同步测试使用临时目录。服务未启动时，部分集成测试会跳过，应检查测试报告，不能把跳过当作通过。

回归覆盖视频发现与标题归属、请求上下文、下载和完整性校验、批量操作、前后台亮屏、网址清空、本机持久化、视频整理及模拟云同步。最近完整回归使用 iOS 26.5 模拟器；受控场景通过不代表所有站点或设备都兼容。

仓库暂未提供公开演示截图。可在模拟器中的 V语 打开 `http://127.0.0.1:8765/direct` 体验下载，或打开 `/video-card-titles`、`/multiple-videos`、`/slow` 对应页面查看标题、多视频选择和暂停操作。所有示例均为合成素材。

## 开发缓存清理

构建时复用同一用途的 `work/` 目录。构建和测试全部结束后，先查看可清理清单，再执行清理：

```sh
python3 scripts/clean_dev_cache.py
python3 scripts/clean_dev_cache.py --apply
```

脚本只处理 `work/` 顶层中能确认的构建树、编译模块缓存和测试结果包。默认保留最新一份模拟器构建目录、一份真机构建目录及两份 `.xcresult`；`--keep-results N` 可调整测试结果包保留数。旧缓存删除后，需要时会重新生成。

删除前检查 Git 跟踪与忽略状态、符号链接、构建进程和文件占用；检查失败时不删除。源码副本、未识别目录、本机签名配置、备份、`outputs/`、模拟器和手机数据均保留。脚本不会定时运行，每次开发任务结束后按工程约定执行。

清理工具自身的测试不需要启动 iOS 模拟器或媒体服务：

```sh
python3 scripts/test_clean_dev_cache.py
```

## 项目结构

```text
App/
  Browser/       网页浏览、媒体发现与网页会话下载
  Downloads/     下载调度、HLS 处理、校验与亮屏控制
  Cloud/         iCloud 文件、元数据及同步状态
  Library/       网页资料、视频整理与预览图
  Core/          媒体模型、请求策略及校验工具
  UI/            浏览、离线列表与播放器界面
  Resources/     图标等资源
Config/          公共构建默认值、本机配置示例与可选本机模式权限
Tests/           单元与集成测试
UITests/         界面回归
fixtures/        本地 HTTP 测试页面与服务
scripts/         合成媒体生成和服务检查
docs/            使用、设计与验证文档
project.yml      XcodeGen 工程配置
VYu.xcodeproj/   生成的 Xcode 工程
```

`work/`、`outputs/` 和 `fixtures/media/` 为忽略的本地产物，不是仓库附带的安装包或媒体资源。

## 贡献

提交问题时，请提供 iOS/Xcode 版本、可复现步骤、预期与实际行为。优先使用合成页面或可公开的最小示例，不提交 Cookie、带签名的媒体地址、私人页面、账号资料或个人视频。

代码变更请保持范围清晰，并为受影响的下载、持久化或界面行为补充相应回归。涉及工程结构时同步更新 `project.yml` 与生成工程；提交前运行相关本地测试，并注明未覆盖的真机或真实服务场景。

## 许可证

本项目采用 [MIT 许可证](LICENSE)。

Copyright (c) 2026 materliu
