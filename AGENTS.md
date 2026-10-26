# V语工程约定

这是独立的 iOS 项目，根目录就是当前仓库。Bundle ID 为 `app.vyu.ios`。不得使用其他 App 的沙盒、真实资料或远端仓库。

本仓库之外的项目仅可作为只读参考，不修改其文件、Git、运行进程或安装包。

使用公开 WebKit、URLSession、AVFoundation API。网页脚本消息是不可信输入；保留来源、导航代次、大小和 URL 校验。不得把 `blob:` 字符串、m3u8 文本或部分分片标成完成的视频。不得绕过 DRM 或站点访问控制。

Cookie 和恢复数据只能留在本机受保护目录，不记录、导出或同步登录凭据。下载成功必须经过文件或离线资产验证。保存失败原因时避免输出完整签名 URL、请求头或 Cookie。

先运行 `python3 scripts/fixture_generate.py` 与 `python3 fixtures/server.py`，再运行 iOS 集成测试。使用专用 VYu 模拟器和临时资料。模拟器构建需要 ad hoc 签名，未签名 App 无法连接后台下载服务。

`project.yml` 是工程配置来源，`Config/Build.xcconfig` 提供公共默认值；个人签名值只放在被忽略的 `Config/Local.xcconfig` 中，通过 `VYU_` 变量在构建时展开。不要把实际团队值写进 YAML 或生成工程。`App/VYu.entitlements` 是手工维护的权限模板，不由 XcodeGen 覆盖。增删源文件后执行 `xcodegen generate`，将生成的 `VYu.xcodeproj` 一起更新。开发生成物写入 `work/`；用户交付物写入 `outputs/`。不把测试媒体、构建目录或签名材料提交到 Git。

面对用户的文案遵循全局 unslop 约定。区分源码实现、模拟器验证和真机验收，不把受控测试成功描述成所有站点均支持。

## Git 同步

使用本仓库已有的远端配置与跟踪分支，不在公开文档中保存个人地址。

- 每次任务开始前，先检查工作区，再拉取远端最新代码；当前分支跟踪 `origin/main` 时执行 `git pull --ff-only origin main`。
- 有未提交改动或分支分叉时，先保留现有改动并处理同步，不覆盖用户代码，不使用强制推送。
- 任务完成后，完成必要验证，提交本次改动并推送到对应远端分支；默认推送到 `main`。没有新改动时，也要确认本地提交均已推送。
- 拉取、合并或推送失败时，明确报告实际状态，不把未完成的同步描述为成功。
