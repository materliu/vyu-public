# V语受控网页与媒体

这些网页只提供播放控件，没有下载按钮。测试视频由本机 FFmpeg 的 `testsrc2` 图案与 440 Hz 正弦音合成，没有真实用户资料或第三方视频。媒体时长为 8 秒，标准样本为 H.264 Main 视频与 AAC 音频。

FFmpeg 和 Python 只用于开发测试。V语 App 不调用此服务器、Mac 命令或 FFmpeg 完成正式用户的下载；使用测试页面时，服务器才作为普通视频站点提供内容。

在工程根目录运行：

```bash
python3 scripts/fixture_generate.py
python3 scripts/fixture_test.py
python3 fixtures/server.py
```

生成脚本需要 `ffmpeg` 与 `ffprobe`；服务器和 HTTP 测试使用 Python 标准库。生成结果在 `fixtures/media/`，已被 Git 忽略；`inventory.json` 记录文件大小、SHA-256 与源视频轨道信息。当前生成 158 个文件，不包括清单自身，实际字节数以清单为准。重复生成会覆盖测试媒体。

默认入口是 `http://127.0.0.1:8765/`，跨源 iframe 使用 `8766` 端口。模拟器可直接访问这两个回环地址。iPhone 上的 `127.0.0.1` 指向手机本身；真机使用这些测试页时，需要将开发服务器绑定到可达的局域网地址，并在手机输入该地址。App 浏览和下载其他站点不依赖此开发服务器。

| 页面 | 视频或清单 | 验证内容 |
| --- | --- | --- |
| `/direct` | `/media/direct.mp4` | 8 秒有声 MP4，从播放页识别与下载 |
| `/cover-timeline` | `/media/cover-timeline.mp4` | 每两秒依次为黑、红、绿、蓝，检查精确选帧、自动避黑、取消和重启保留 |
| `/history-delayed` | 无媒体，延迟 0.8 秒返回网页 | 加载中清理历史后，迟到的导航提交不能恢复记录 |
| `/iframe` | 同源 iframe 内的 `/direct` | 所有 frame 的注入与消息归属 |
| `/cross-frame` | 另一端口 iframe 内的 `/direct` | 跨源 frame，不依赖主文档读取 frame DOM |
| `/dynamic` | 延迟 1 秒插入 `video > source` | DOM 变化与动态媒体 |
| `/multiple-videos` | 第一个 `/forbidden.mp4`；第二个 `/media/direct.mp4?second=1` | 每个播放器旁的独立下载入口，选择第二个时不能误下第一个 |
| `/video-card-titles` | 两张独立卡片中的合成 MP4 | 普通文本标题归属、作者/时间/标签排除、动态更新、点击第二个视频与重启后列表标题 |
| `/video-card-title-frame` | iframe 内的 `/video-card-title-inner` | 使用播放器所属 frame 的卡片标题，准备请求和持久化后不变 |
| `/video-card-title-hls` | 被拒绝的 HLS 与明确匹配的 MP4 | 失败处理页、下载确认和 MP4 备选沿用所选卡片标题 |
| `/head-denied` | `/head-denied.mp4` | HEAD 返回 403；GET 和 Range 返回有效 MP4，不能把预检失败当成下载被拒绝 |
| `/head-unsupported` | `/head-unsupported.mp4` | HEAD 返回 405、GET 返回 403，不能因 HEAD 不受支持就放行 |
| `/browser-session` | `/browser-session.mp4` | 合成兼容性场景：HEAD 与单字节 GET 探测返回 403，普通 GET 返回有效视频，用于验证网页会话重试入口 |
| `/context-required` | `/context-frame` 内的 `/context-required.mp4` | 使用播放器所属 frame 的 Referer、WebKit User-Agent 和当前测试 Cookie |
| `/hls` | `/media/hls/master.m3u8` | 360p、180p；每个变体含音频 |
| `/hls-separate` | `/media/hls-separate/master.m3u8` | 两档视频与独立 AAC 音轨、相对链接 |
| `/hls-alternatives` | 被拒绝的 `/hls-denied/master.m3u8`；页面 JSON 内同组 `/media/direct.mp4?matched=1` | 主清单 403 后，只提供同一播放器匹配的 MP4；另一组视频的高码率 MP4 不得混入 |
| `/hls-partial` | `/hls-partial/master.m3u8` | 高码率子清单返回 403，360p 子清单可用；保留可用画质并验证完整离线播放 |
| `/blob` | fetch JSON → fetch MP4 → Blob URL | 查找实际网络源，不能下载 `blob:` 字符串 |
| `/mse` | fetch JSON → fetch 分片 MP4 → SourceBuffer | `MediaSource` 或 `ManagedMediaSource`；无此 API 时页面说明原因 |
| `/dash` | XHR `/media/dash/manifest.mpd` | MPD、音画分离与支持边界；页面不含 DASH 播放器 |
| `/expired` | `/expired.mp4?expires=1` | HTTP 410；未来 Unix 时间戳可临时返回有效视频 |
| `/forbidden` | `/forbidden.mp4` | HTTP 403，保留失败原因 |
| `/silent` | `/media/silent.mp4` | 有视频、没有音轨；不虚报有声音 |
| `/corrupt` | `/media/corrupt.mp4` | 后缀与 MIME 是 MP4，内容无效；不能标记完成 |
| `/slow` | `/slow.mp4` | 每 16 KB 等待 150 ms，供暂停、取消与 Range 恢复测试 |
| `/batch`、`/batch-slow.mp4` | 独立慢速合成 MP4，每 16 KB 等待 2 秒 | 隔离 UI 测试使用真实下载 API 创建暂停、失败、取消及完整记录；覆盖批量操作、滚动选择和前后台亮屏，不改变原 `/slow.mp4` |
| `/protected` | `/media/protected/index.m3u8` | FairPlay/SAMPLE-AES 标记识别；仅为清单标记测试，片段未加密，无许可证服务 |

两个 HLS 家族各有 360p 与 180p。每个视频变体含 4 个约 2 秒片段；独立音轨的 AAC 分段边界略有不同。各完整媒体的时长应约为 8 秒，不能用片段数代替完整性检查。DASH 包含独立的视频、音频初始化片段与媒体片段。测试会分别组合每条 DASH 轨道验证编码和完整时长，这不代表 App 已有 DASH 下载与封装功能。

媒体接口支持 `HEAD`、单段 `Range`、后缀范围、`Accept-Ranges`、`ETag`、`Last-Modified` 和 `If-Range`。无效或越界范围返回 416；`If-Range` 过期时返回完整 200 响应。页面、清单和媒体使用 `Cache-Control: no-store`，避免离线验收误用网页缓存。

离线验收前，先完成 App 下载，再让全部测试媒体请求返回 503：

```bash
curl -sS -X POST http://127.0.0.1:8765/__control \
  -H 'Content-Type: application/json' -d '{"offline":true}'
curl -sS http://127.0.0.1:8765/__health
```

控制状态作用于两个端口，也中断仍在传输的媒体响应。网页、`/__health` 和 `GET /__stats` 保持可用。此时 App 应从其容器中的文件播放，不能依赖网络流。恢复后可继续网络测试：

```bash
curl -sS -X POST http://127.0.0.1:8765/__control \
  -H 'Content-Type: application/json' -d '{"offline":false}'
```

`/__stats` 只返回各方法和 URL 路径的请求次数。服务器日志不记录查询参数、Cookie 或请求头。服务器退出后控制状态和计数清空。

`/context-frame` 只设置固定的本地测试 Cookie。媒体接口要求该 Cookie、包含 `AppleWebKit/` 的 User-Agent，以及指向同源 `/context-frame` 的 Referer；缺少任何一项均返回 403。这里没有真实账号资料，错误响应和日志也不会回显请求头。此用例用于验证 App 保留播放器已有的请求上下文。

`/browser-session` 刻意区分预检与普通下载请求，供 UI 测试触发“用网页会话重试”。这是合成的兼容性场景，不代表任何真实站点采用相同规则。

`/hls-alternatives.json` 动态返回两组 `video_info.variants`，URL 来自当前测试服务器。页面播放器只使用第一组 HLS 地址；第二组故意提供另一条 HLS 地址和更高码率的 MP4，以检查关联是否会串到别的视频。`/hls-partial/master.m3u8` 的第一个子清单固定返回 403，第二个使用已有的 8 秒有声 360p 媒体。两类清单在离线控制开启后都返回 503。`HLSCompatibilityIntegrationTests` 检查主清单错误阶段、同视频备选与页面切换失效、完整 MP4 下载，以及部分画质不可用时的 HLS 下载和末段离线播放。这些用例只验证本机合成场景，不代表已定位真实站点的拒绝原因。

`scripts/fixture_test.py` 用临时端口启动自己的服务器，不改变交互验收服务器的状态。19 项检查覆盖页面、跨源帧、字节范围、取消后拼接恢复、实体变化、过期与拒绝响应、离线切换、完整时长与音轨、HLS 清单、损坏媒体、保护标记、文件校验、DASH 分离轨道、HEAD 与 GET 不同结果、播放器请求上下文、多视频选择和网页会话重试场景。结果写入 `work/fixture-test-report.json`。这些检查验证测试环境；App 的 WKWebView、URLSession、WKDownload、AVAssetDownloadURLSession 和离线播放器仍需各自验收。
