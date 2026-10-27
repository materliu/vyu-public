import SwiftUI
import WebKit
import AVKit

private let paper = Color(uiColor: .secondarySystemGroupedBackground)
private let canvas = Color(uiColor: .systemGroupedBackground)

private struct CandidatePresentation: Identifiable {
    let id = UUID()
    let candidate: MediaCandidate?
}

private struct DownloadToast: Identifiable {
    let id = UUID()
    let text: String
    let warning: Bool
    let resolution: MediaCandidate?
}

private enum OfflineVideoItem: Identifiable {
    case local(DownloadRecord)
    case cloud(CloudVideoEntry)

    var id: UUID {
        switch self {
        case .local(let record): return record.id
        case .cloud(let entry): return entry.id
        }
    }

    var title: String {
        let title: String
        switch self {
        case .local(let record): title = record.candidate.title
        case .cloud(let entry): title = entry.manifest.title
        }
        return title.isEmpty ? "视频" : title
    }
}

private struct VideoTagPresentation: Identifiable {
    let id: UUID
    let title: String
}

private struct VideoNamePresentation: Identifiable {
    let id: UUID
    let originalTitle: String
}

private struct VideoCoverPresentation: Identifiable {
    let id: UUID
    let title: String
    let localURL: URL
}

struct ContentView: View {
    @ObservedObject var browser: BrowserModel
    @ObservedObject var downloads: DownloadManager
    @ObservedObject var library: LibraryStore
    @ObservedObject var cloud: CloudVideoSync
    @ObservedObject var videoMetadata: VideoMetadataStore
    @ObservedObject var storage: VideoStorageOptimizer
    @State private var tab = 0
    @State private var address = ""
    @State private var showAddress = false
    @State private var candidatePresentation: CandidatePresentation?
    @State private var playerRecord: DownloadRecord?
    @State private var recordToRemove: DownloadRecord?
    @State private var cloudToRemove: CloudVideoEntry?
    @State private var cloudToDelete: UUID?
    @State private var showVideoImport = false
    @State private var preparingDownloads: Set<MediaCandidate.ID> = []
    @State private var watchedDownloads: [UUID: MediaCandidate] = [:]
    @State private var downloadToast: DownloadToast?
    @State private var toastTask: Task<Void, Never>?
    @State private var offlineQuery = ""
    @State private var onlyFavoriteVideos = false
    @State private var tagPresentation: VideoTagPresentation?
    @State private var namePresentation: VideoNamePresentation?
    @State private var coverPresentation: VideoCoverPresentation?
    @State private var showStorageSettings = false
    @State private var playerLease: UUID?
    @State private var coverLease: UUID?
    @State private var metadataError: String?
    @State private var offlineSelection = OfflineSelection()

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { browserPage }.tabItem { Label("浏览", systemImage: "safari") }.tag(0)
            NavigationStack { favoritesPage }.tabItem { Label("收藏", systemImage: "bookmark") }.tag(1)
            NavigationStack { downloadsPage }.tabItem { Label("离线", systemImage: "arrow.down.circle") }.tag(2)
        }
        .sheet(isPresented: $showAddress) { addressSheet }
        .sheet(isPresented: $showVideoImport) { LocalVideoImportSheet(downloads: downloads) }
        .sheet(isPresented: $showStorageSettings) { VideoStorageSettingsSheet(storage: storage, cloud: cloud) }
        .sheet(item: $tagPresentation) { presentation in
            VideoTagEditorSheet(videoID: presentation.id, title: presentation.title, videoMetadata: videoMetadata)
        }
        .sheet(item: $namePresentation) { presentation in
            VideoNameEditorSheet(videoID: presentation.id, originalTitle: presentation.originalTitle,
                                 videoMetadata: videoMetadata)
        }
        .sheet(item: $coverPresentation, onDismiss: {
            if let token = coverLease { downloads.endUsingLocalVideo(token); coverLease = nil }
        }) { presentation in
            VideoCoverPickerSheet(videoID: presentation.id, title: presentation.title, localURL: presentation.localURL,
                                  downloads: downloads, videoMetadata: videoMetadata)
        }
        .alert("无法保存", isPresented: Binding(get: { metadataError != nil }, set: { if !$0 { metadataError = nil } })) {
            Button("好") { metadataError = nil }
        } message: {
            Text(metadataError ?? "请重试。")
        }
        .sheet(item: Binding(get: { browser.popup }, set: { if $0 == nil { browser.closePopup() } })) { popup in
            BrowserPopupSheet(popup: popup, canReturnToXLogin: browser.canReturnToXLogin,
                              onReturnToXLogin: browser.returnToXLogin, onClose: browser.closePopup)
        }
        .sheet(item: $candidatePresentation) { presentation in
            CandidateSheet(browser: browser, downloads: downloads, initialCandidate: presentation.candidate,
                           didStart: { candidate in
                               candidatePresentation = nil
                               if let record = downloads.records.first(where: { $0.candidate.id == candidate.id }) {
                                   watchDownload(record.id, candidate: candidate)
                               }
                           })
        }
        .overlay(alignment: .top) { downloadToastView }
        .fullScreenCover(item: $playerRecord, onDismiss: {
            if let token = playerLease { downloads.endUsingLocalVideo(token); playerLease = nil }
        }) { record in
            if let url = downloads.localURL(for: record) {
                OfflinePlayer(url: url, record: record, library: library)
            }
        }
        .confirmationDialog("移除视频记录？", isPresented: Binding(get: { recordToRemove != nil }, set: { if !$0 { recordToRemove = nil } }), titleVisibility: .visible) {
            Button("移除记录与本机视频", role: .destructive) {
                if let record = recordToRemove { cloud.hideFromThisDevice(id: record.id); library.removePosition(for: record.id) }
                recordToRemove = nil
            }
        } message: { Text("清除本机记录、视频和观看位置。已上传到 iCloud 的视频及网页收藏会保留。") }
        .confirmationDialog("从本机列表移除？", isPresented: Binding(get: { cloudToRemove != nil }, set: { if !$0 { cloudToRemove = nil } }), titleVisibility: .visible) {
            Button("从本机列表移除", role: .destructive) {
                if let entry = cloudToRemove { cloud.hideFromThisDevice(id: entry.id) }
                cloudToRemove = nil
            }
        } message: { Text("iCloud 中的视频会保留，可通过“显示全部云端视频”找回。") }
        .confirmationDialog("从所有设备删除？", isPresented: Binding(get: { cloudToDelete != nil }, set: { if !$0 { cloudToDelete = nil } }), titleVisibility: .visible) {
            Button("删除 iCloud 和所有设备的视频", role: .destructive) {
                if let id = cloudToDelete { Task { await cloud.deleteEverywhere(id: id); library.removePosition(for: id) } }
                cloudToDelete = nil
            }
        } message: { Text("这会删除 iCloud 副本。其他设备下次同步时也会删除这条视频，无法撤销。") }
        .onChange(of: cloud.readyToPlay) { _, record in
            if let record {
                if !offlineSelection.isActive { presentPlayer(record) }
                cloud.readyToPlay = nil
            }
        }
        .onChange(of: tab) { _, selected in
            if selected != 2 { cloud.cancelPendingPlayback(); offlineSelection.end() }
        }
        .onChange(of: visibleLocalOfflineIDs) { _, ids in
            offlineSelection.reconcile(visibleLocalIDs: ids)
        }
        .onChange(of: browser.historyVisit) { _, event in
            guard let event, browser.isCurrentHistoryVisitAllowed(event) else { return }
            library.visit(url: event.url, title: event.title)
        }
        .onChange(of: browser.historyTitleUpdate) { _, event in
            guard let event, browser.isCurrentHistoryVisitAllowed(event) else { return }
            library.updateRecentTitle(url: event.url, title: event.title)
        }
        .onChange(of: browser.pendingDownload) { _, candidate in
            guard let candidate else { return }
            browser.pendingDownload = nil
            guard tab == 0, candidatePresentation == nil else { return }
            startInlineDownload(candidate)
        }
        .onChange(of: browser.downloadNotice) { _, message in
            guard let message else { return }
            browser.downloadNotice = nil
            showDownloadToast(message, warning: true)
        }
        .onChange(of: downloads.records) { _, records in
            for record in records where watchedDownloads[record.id] != nil {
                if record.phase == .failed {
                    let candidate = watchedDownloads.removeValue(forKey: record.id)
                    showDownloadFailure(candidate: candidate, failure: record.failure)
                } else if [.complete, .cancelled].contains(record.phase) {
                    watchedDownloads.removeValue(forKey: record.id)
                }
            }
        }
        .onChange(of: browser.documentID) { _, _ in candidatePresentation = nil }
    }

    @ViewBuilder private var downloadToastView: some View {
        if let toast = downloadToast {
            HStack(spacing: 10) {
                Image(systemName: toast.warning ? "exclamationmark.circle" : "checkmark.circle.fill")
                    .foregroundStyle(toast.warning ? Color.orange : Color.accentColor)
                Text(toast.text).font(.subheadline).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("downloadToast")
                if let candidate = toast.resolution {
                    Button("处理") {
                        guard browser.isCurrentCandidate(candidate) else { return }
                        candidatePresentation = CandidatePresentation(candidate: candidate)
                        downloadToast = nil
                    }.accessibilityIdentifier("resolveDownloadFromToast")
                }
                Button("查看") { tab = 2; downloadToast = nil }
                    .accessibilityIdentifier("viewDownloadsFromToast")
            }
            .padding(14).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 16).padding(.top, 8)
        }
    }

    private func showDownloadToast(_ text: String, warning: Bool = false, resolution: MediaCandidate? = nil) {
        let toast = DownloadToast(text: text, warning: warning, resolution: resolution)
        downloadToast = toast
        toastTask?.cancel()
        toastTask = Task {
            do { try await Task.sleep(for: .seconds(warning ? 10 : 6)) } catch { return }
            if downloadToast?.id == toast.id { downloadToast = nil }
        }
    }

    private func showDownloadFailure(candidate: MediaCandidate?, failure: String?) {
        let resolution = candidate.flatMap { candidate -> MediaCandidate? in
            let canRetrySession = candidate.kind == .file && ["HTTP 401", "HTTP 403"].contains { failure?.contains($0) == true }
            guard browser.isCurrentCandidate(candidate),
                  canRetrySession || !browser.alternatives(for: candidate).isEmpty else { return nil }
            return candidate
        }
        showDownloadToast("下载失败，详情已保存在离线中", warning: true, resolution: resolution)
    }

    private func watchDownload(_ id: UUID, candidate: MediaCandidate) {
        guard let record = downloads.records.first(where: { $0.id == id }) else { return }
        if record.phase == .failed { showDownloadFailure(candidate: candidate, failure: record.failure) }
        else {
            if ![.complete, .cancelled].contains(record.phase) { watchedDownloads[id] = candidate }
            showDownloadToast("已加入离线下载")
        }
    }

    private func reuseDownload(_ candidate: MediaCandidate) -> Bool {
        guard let record = BrowserDownloadPolicy.existingDownload(candidate, in: downloads) else { return false }
        if record.phase == .paused {
            downloads.resume(id: record.id)
            watchedDownloads[record.id] = candidate
            showDownloadToast("已继续离线下载")
        } else {
            showDownloadToast(record.phase == .complete ? "这个视频已在离线中" : "这个视频已加入下载")
        }
        return true
    }

    private func startInlineDownload(_ candidate: MediaCandidate) {
        guard !preparingDownloads.contains(candidate.id) else {
            showDownloadToast("这个视频正在加入下载"); return
        }
        guard !reuseDownload(candidate) else { return }
        preparingDownloads.insert(candidate.id)
        let document = browser.documentID, discovery = browser.discoveryID
        Task {
            defer { preparingDownloads.remove(candidate.id) }
            guard let prepared = await browser.prepareForDownload(candidate) else {
                if browser.documentID == document { showDownloadToast("视频来源已变化，请重新点击下载", warning: true) }
                return
            }
            let cookies = await browser.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            guard browser.documentID == document, browser.discoveryID == discovery,
                  browser.isCurrentCandidate(prepared), !reuseDownload(prepared) else { return }
            // start creates the queued record before its first network wait;
            // preflight failures therefore remain visible in the offline list.
            showDownloadToast("已加入离线下载")
            let id = await downloads.start(candidate: prepared, cookies: cookies)
            watchDownload(id, candidate: prepared)
        }
    }

    private var browserPage: some View {
        VStack(spacing: 0) {
            if let visibleURL = browser.displayURL {
                Button { address = visibleURL.absoluteString; showAddress = true } label: {
                    HStack { Image(systemName: visibleURL.scheme == "https" ? "lock" : "globe"); Text(visibleURL.host ?? "网页").lineLimit(1); Spacer(); Image(systemName: "pencil") }
                        .font(.subheadline).padding(12).background(paper, in: RoundedRectangle(cornerRadius: 14))
                }.padding(.horizontal).padding(.bottom, 8).accessibilityIdentifier("addressBar")
            }
            if browser.isGoogleSignIn {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Google 不支持在应用内嵌浏览器中登录。").font(.subheadline.weight(.medium))
                    Text("请返回原站点，选择账号和密码等其他登录方式。").font(.footnote).foregroundStyle(.secondary)
                    if browser.canGoBack { Button("返回原网页") { browser.goBack() } }
                }.frame(maxWidth: .infinity, alignment: .leading).padding().background(Color.orange.opacity(0.10))
            }
            // Keep WebKit mounted from the first request, including redirects and errors.
            ZStack(alignment: .top) {
                BrowserSurface(webView: browser.webView)
                    .opacity(browser.displayURL == nil ? 0 : 1)
                if browser.displayURL == nil { home.frame(maxWidth: .infinity, maxHeight: .infinity).background(canvas) }
                else if let message = browser.loadError {
                    ContentUnavailableView {
                        Label("网页暂时无法打开", systemImage: "globe")
                    } description: {
                        Text(message).accessibilityIdentifier("pageLoadError")
                    } actions: {
                        Button("重试") { browser.reload() }.buttonStyle(.borderedProminent).accessibilityIdentifier("retryPage")
                        Button("修改网址") { address = browser.displayURL?.absoluteString ?? ""; showAddress = true }
                    }.background(canvas)
                } else if browser.isLoading {
                    HStack(spacing: 8) { ProgressView(); Text("正在打开网页…").font(.caption) }
                        .padding(10).background(.regularMaterial, in: Capsule()).accessibilityIdentifier("pageLoading")
                }
            }
            if browser.displayURL != nil {
                VStack(spacing: 8) {
                    Text(browser.statusText).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).lineLimit(2).accessibilityIdentifier("discoveryStatus")
                    HStack {
                        Button { browser.goBack() } label: { Image(systemName: "chevron.left").frame(width: 32, height: 36) }.disabled(!browser.canGoBack).accessibilityLabel("返回网页")
                        if browser.isLoading {
                            Button { browser.stopLoading() } label: { Image(systemName: "xmark").frame(width: 32, height: 36) }.accessibilityLabel("停止加载").accessibilityIdentifier("stopPageLoading")
                        } else {
                            Button { browser.reload() } label: { Image(systemName: "arrow.clockwise").frame(width: 32, height: 36) }.accessibilityLabel("刷新网页")
                        }
                        Button { if let url = browser.url { library.toggleFavorite(url: url, title: browser.title) } } label: {
                            Image(systemName: browser.url.map(library.isFavorite) == true ? "bookmark.fill" : "bookmark").frame(width: 32, height: 36)
                        }.disabled(!browser.hasCurrentDocument).accessibilityLabel("收藏网页")
                        Spacer()
                        Button { browser.refreshCandidates(); candidatePresentation = CandidatePresentation(candidate: nil) } label: {
                            Label(browser.candidates.isEmpty ? "检查视频" : "视频来源 · \(browser.candidates.count)", systemImage: "arrow.down.circle")
                                .font(.subheadline.weight(.medium))
                        }.buttonStyle(.borderedProminent).disabled(!browser.hasCurrentDocument).accessibilityIdentifier("showCandidates")
                    }
                }.padding(12).background(paper)
            }
        }
        .background(canvas)
        .navigationTitle("V语")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                HistoryButton(library: library, browser: browser, iconOnly: true, openPage: openHistoryPage)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { address = ""; showAddress = true } label: { Image(systemName: "plus") }.accessibilityLabel("打开网址")
            }
        }
    }

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("打开视频网页，把能下载的内容留在本机。").foregroundStyle(.secondary)
                Button { showAddress = true } label: {
                    Label("输入网址，打开视频站点", systemImage: "magnifyingglass").frame(maxWidth: .infinity, alignment: .leading).padding(18).background(paper, in: RoundedRectangle(cornerRadius: 18))
                }.accessibilityIdentifier("openAddress")
                if browser.statusText != "输入网址，打开网页后识别视频" {
                    Text(browser.statusText).font(.footnote).foregroundStyle(.secondary)
                }
                if !library.recent.isEmpty {
                    HStack {
                        Text("最近访问").font(.headline)
                        Spacer()
                        HistoryButton(library: library, browser: browser, openPage: openHistoryPage)
                    }
                    ForEach(library.recent.prefix(8)) { page in pageRow(page) }
                } else {
                    Label("最近访问和收藏的站点会留在这里。", systemImage: "clock").font(.subheadline).foregroundStyle(.secondary)
                }
                Text("网页能播放，不代表能下载。遇到受保护或暂不支持的视频，仍可继续浏览和收藏网页。")
                    .font(.footnote).foregroundStyle(.secondary).padding(.top, 20)
            }.padding(24)
        }
    }

    private var favoritesPage: some View {
        Group {
            if library.favorites.isEmpty { ContentUnavailableView("还没有收藏", systemImage: "bookmark", description: Text("浏览时点收藏，下次从这里打开原网页。")) }
            else { List(library.favorites) { page in pageRow(page).swipeActions { Button("取消收藏", role: .destructive) { library.toggleFavorite(url: page.url, title: page.title) } } } }
        }.navigationTitle("收藏")
    }

    private func pageRow(_ page: SavedPage) -> some View {
        Button { browser.open(page.url.absoluteString); tab = 0 } label: {
            HStack(spacing: 14) {
                Image(systemName: "globe").font(.title2).frame(width: 42, height: 42).background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) { Text(page.title).foregroundStyle(.primary).lineLimit(2); Text(page.url.host ?? "网页").font(.caption).foregroundStyle(.secondary) }
                Spacer(); Image(systemName: "arrow.up.right").font(.caption)
            }.padding(.vertical, 5)
        }
    }

    private var downloadsPage: some View {
        VStack(spacing: 0) {
            cloudHeader
            offlineFilters
            if !offlineItems.isEmpty { offlineDownloadActions }
            if offlineItems.isEmpty {
                ContentUnavailableView {
                    Label("还没有离线视频", systemImage: "arrow.down.circle")
                } description: {
                    Text("打开网页下载视频，或从相册导入录屏和视频。")
                } actions: {
                    Button("导入录屏/视频") { showVideoImport = true }.buttonStyle(.bordered)
                }
            } else if filteredOfflineItems.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text("没有匹配的视频").accessibilityIdentifier("offlineSearchEmpty")
                    } icon: {
                        Image(systemName: "magnifyingglass")
                    }
                } description: {
                    Text(onlyFavoriteVideos && offlineQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                         ? "在视频菜单中点收藏，方便下次找到。" : "试试其他标题或标签。")
                } actions: {
                    Button("清除筛选") { offlineQuery = ""; onlyFavoriteVideos = false }
                        .buttonStyle(.bordered).accessibilityIdentifier("clearOfflineFilters")
                }
            } else {
                List {
                    ForEach(filteredOfflineItems) { item in
                        if offlineSelection.isActive {
                            switch item {
                            case .local(let record): selectableDownloadRow(record)
                            case .cloud(let entry):
                                cloudSummary(entry)
                                    .padding(.vertical, 10)
                                    .accessibilityElement(children: .combine)
                                    .accessibilityHint("云端视频不参与批量下载操作")
                                    .accessibilityIdentifier("unselectableCloudVideo-\(entry.id.uuidString)")
                            }
                        } else {
                            Group {
                                switch item {
                                case .local(let record): downloadRow(record)
                                case .cloud(let entry): cloudRow(entry)
                                }
                            }.swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button {
                                    toggleVideoFavorite(item.id)
                                } label: {
                                    Label(videoMetadata.isFavorite(item.id) ? "取消收藏" : "收藏",
                                          systemImage: videoMetadata.isFavorite(item.id) ? "heart.slash" : "heart")
                                }.tint(.pink).accessibilityIdentifier("swipeVideoFavorite")
                            }
                        }
                    }
                }.scrollDismissesKeyboard(.interactively)
            }
        }.navigationTitle("离线")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(offlineSelection.isActive ? "完成" : "选择") {
                        if offlineSelection.isActive { offlineSelection.end() }
                        else { cloud.cancelPendingPlayback(); offlineSelection.begin() }
                    }.disabled(!offlineSelection.isActive && visibleLocalOfflineIDs.isEmpty)
                        .accessibilityIdentifier("offlineSelectionMode")
                        .accessibilityValue(offlineSelection.isActive ? "选择中" : "未选择")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("本地存储", systemImage: "internaldrive") { showStorageSettings = true }
                        .accessibilityIdentifier("manageLocalStorage")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("导入录屏/视频", systemImage: "plus") { showVideoImport = true }
                        .accessibilityIdentifier("importOfflineVideo")
                }
            }
    }

    private var offlineItems: [OfflineVideoItem] {
        var result: [OfflineVideoItem] = []
        var seen: Set<UUID> = []
        for record in downloads.records where seen.insert(record.id).inserted {
            if [.failed, .cancelled].contains(record.phase), let entry = cloud.entry(for: record.id) {
                result.append(.cloud(entry))
            } else { result.append(.local(record)) }
        }
        for entry in cloud.visibleEntries where seen.insert(entry.id).inserted { result.append(.cloud(entry)) }
        return result
    }

    private var filteredOfflineItems: [OfflineVideoItem] {
        offlineItems.filter { item in
            (!onlyFavoriteVideos || videoMetadata.isFavorite(item.id)) &&
                VideoMetadataSearch.matches(title: videoMetadata.displayTitle(for: item.id, fallback: item.title),
                                            tags: videoMetadata.tags(for: item.id), query: offlineQuery)
        }
    }

    private var visibleLocalOfflineIDs: Set<UUID> {
        Set(filteredOfflineItems.compactMap { item in
            if case .local(let record) = item, record.localCacheEvicted != true { return record.id }
            return nil
        })
    }

    private var selectedResumableIDs: Set<UUID> {
        offlineSelection.ids.intersection(visibleLocalOfflineIDs).filter { downloads.canResume(id: $0) }
    }

    private var selectedPausableIDs: Set<UUID> {
        offlineSelection.ids.intersection(visibleLocalOfflineIDs).filter { downloads.canPause(id: $0) }
    }

    private var offlineDownloadActions: some View {
        let resumableCount = downloads.records.filter { downloads.canResume(id: $0.id) }.count
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button("全部继续", systemImage: "play.fill") { downloads.resumeAllDownloads() }
                    .buttonStyle(.borderedProminent).disabled(resumableCount == 0)
                    .accessibilityIdentifier("resumeAllDownloads")
                Text("\(resumableCount) 个可继续下载，不受筛选影响")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("resumableDownloadCount")
            }
            if offlineSelection.isActive {
                HStack {
                    Button(offlineSelection.includesAll(visibleLocalIDs: visibleLocalOfflineIDs) ? "取消全选" : "全选当前筛选") {
                        offlineSelection.toggleAll(visibleLocalIDs: visibleLocalOfflineIDs)
                    }.disabled(visibleLocalOfflineIDs.isEmpty)
                        .accessibilityIdentifier("selectAllOfflineTasks")
                    Spacer()
                    Text("已选择 \(offlineSelection.ids.count) 项").font(.subheadline)
                        .accessibilityIdentifier("offlineSelectionSummary")
                }
                Text("仅选择当前筛选中的本机项目；云端视频不参与。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button("继续所选（\(selectedResumableIDs.count)）", systemImage: "play") {
                        downloads.resumeDownloads(ids: selectedResumableIDs)
                    }.disabled(selectedResumableIDs.isEmpty)
                        .accessibilityIdentifier("resumeSelectedDownloads")
                    Button("暂停所选（\(selectedPausableIDs.count)）", systemImage: "pause") {
                        downloads.pauseDownloads(ids: selectedPausableIDs)
                    }.disabled(selectedPausableIDs.isEmpty)
                        .accessibilityIdentifier("pauseSelectedDownloads")
                }.buttonStyle(.bordered)
            }
        }.padding(.horizontal, 20).padding(.bottom, 12).frame(maxWidth: .infinity, alignment: .leading)
            .background(canvas)
    }

    private func selectableDownloadRow(_ record: DownloadRecord) -> some View {
        let selected = offlineSelection.ids.contains(record.id)
        return Button {
            offlineSelection.toggle(record.id, visibleLocalIDs: visibleLocalOfflineIDs)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(selected ? Color.accentColor : .secondary)
                    .frame(width: 28, height: 36)
                VStack(alignment: .leading, spacing: 8) {
                    downloadSummary(record)
                    if record.phase != .complete {
                        Text(status(record)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(videoMetadata.displayTitle(for: record.id, fallback: record.candidate.title))
            .accessibilityValue("\(selected ? "已选择" : "未选择") · \(status(record))")
            .accessibilityHint("轻点\(selected ? "取消选择" : "选择")")
            .accessibilityIdentifier("offlineTaskSelection-\(record.id.uuidString)")
    }

    private var offlineFilters: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("搜索标题或标签", text: $offlineQuery)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.search).accessibilityIdentifier("offlineVideoSearch")
                if !offlineQuery.isEmpty {
                    Button { offlineQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            .frame(width: 32, height: 36)
                    }.accessibilityLabel("清除搜索").accessibilityIdentifier("clearOfflineSearch")
                }
            }.padding(.leading, 12).padding(.trailing, 4).frame(minHeight: 44)
                .background(paper, in: RoundedRectangle(cornerRadius: 12))
            Picker("视频筛选", selection: $onlyFavoriteVideos) {
                Text("全部").tag(false)
                Text("已收藏").tag(true)
            }.pickerStyle(.segmented).accessibilityIdentifier("offlineVideoFilter")
        }.padding(.horizontal, 20).padding(.bottom, 12).background(canvas)
    }

    private func toggleVideoFavorite(_ id: UUID) {
        do { try videoMetadata.toggleFavorite(id) }
        catch { metadataError = error.localizedDescription }
    }

    @ViewBuilder private func videoTags(_ id: UUID) -> some View {
        let tags = videoMetadata.tags(for: id)
        if !tags.isEmpty {
            Text(tags.map { "#\($0)" }.joined(separator: "  "))
                .font(.caption).foregroundStyle(Color.accentColor).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("offlineVideoTags")
        }
    }

    private func videoTitle(_ title: String, id: UUID) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if videoMetadata.isFavorite(id) {
                Image(systemName: "heart.fill").font(.caption).foregroundStyle(.pink).accessibilityHidden(true)
            }
            Text(videoMetadata.displayTitle(for: id, fallback: title)).font(.headline).foregroundStyle(.primary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func videoMetadataAccessibility(_ id: UUID) -> String {
        var values: [String] = []
        if videoMetadata.isFavorite(id) { values.append("已收藏") }
        let tags = videoMetadata.tags(for: id)
        if !tags.isEmpty { values.append("标签：" + tags.joined(separator: "、")) }
        if let seconds = videoMetadata.coverFrameSeconds(for: id) {
            values.append(String(format: "自选封面 · %.3f 秒", seconds))
        }
        return values.joined(separator: " · ")
    }

    @ViewBuilder private func videoOrganizationActions(id: UUID, title: String) -> some View {
        Button("重命名", systemImage: "pencil") {
            namePresentation = VideoNamePresentation(id: id, originalTitle: title)
        }.accessibilityIdentifier("renameVideo")
        Button(videoMetadata.isFavorite(id) ? "取消收藏" : "收藏视频",
               systemImage: videoMetadata.isFavorite(id) ? "heart.slash" : "heart") {
            toggleVideoFavorite(id)
        }.accessibilityIdentifier("toggleVideoFavorite")
        Button("编辑标签", systemImage: "tag") {
            tagPresentation = VideoTagPresentation(id: id, title: videoMetadata.displayTitle(for: id, fallback: title))
        }.accessibilityIdentifier("editVideoTags")
    }

    private var cloudHeader: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: cloud.isAvailable ? "icloud" : "icloud.slash").padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text("iCloud 同步").font(.subheadline.weight(.medium))
                Text(cloud.message).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("cloudSyncStatus")
                if let message = cloud.metadataMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("videoMetadataSyncStatus")
                }
                if cloud.accountChanged {
                    Button("继续使用当前 iCloud 账号") { Task { await cloud.acceptCurrentAccount() } }.font(.caption)
                    Text("原账号的视频仍留在本机，不会自动上传到新账号。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                Button("本地存储", systemImage: "internaldrive") { showStorageSettings = true }
                Button("重新同步", systemImage: "arrow.clockwise") { Task { await cloud.retrySync() } }
                Button("显示全部云端视频", systemImage: "icloud") { cloud.showCloudVideos() }
            } label: { Image(systemName: "ellipsis.circle").frame(width: 32, height: 32) }
            .accessibilityLabel("管理 iCloud 同步")
        }.padding(.horizontal, 20).padding(.vertical, 12).background(canvas)
    }

    private func cloudRow(_ entry: CloudVideoEntry) -> some View {
        ZStack(alignment: .topTrailing) {
            Button { Task { await cloud.restore(id: entry.id) } } label: {
                cloudSummary(entry).padding(.trailing, 44).padding(.vertical, 10).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!cloud.isAvailable)
                .accessibilityIdentifier("cloudVideoRow")
                .accessibilityLabel(videoMetadata.displayTitle(for: entry.id, fallback: entry.manifest.title))
                .accessibilityValue((["iCloud 视频", videoMetadataAccessibility(entry.id)].filter { !$0.isEmpty }).joined(separator: " · "))
                .accessibilityHint("从 iCloud 下载并播放")
            Menu {
                videoOrganizationActions(id: entry.id, title: entry.manifest.title)
                Button("下载后可选择封面", systemImage: "photo") {}.disabled(true)
                Divider()
                Button("从本机列表移除", systemImage: "minus.circle") { cloudToRemove = entry }
                Button("从所有设备删除", systemImage: "trash", role: .destructive) { cloudToDelete = entry.id }
                    .disabled(!cloud.isAvailable)
            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
            .buttonStyle(.borderless).accessibilityLabel("管理云端视频")
            .accessibilityIdentifier("manageCloudVideo")
        }
    }

    private func cloudSummary(_ entry: CloudVideoEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Color(uiColor: .tertiarySystemFill)
                if let data = entry.thumbnail, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFit()
                        .accessibilityLabel("视频预览图").accessibilityIdentifier("cloudVideoThumbnail")
                } else { Image(systemName: "film").font(.title2).foregroundStyle(.secondary) }
            }.frame(width: 112, height: 70).clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                videoTitle(entry.manifest.title, id: entry.id)
                Text(entry.manifest.sourceHost ?? "iCloud 视频").font(.caption).foregroundStyle(.secondary)
                Text(MediaDurationFormatter.string(seconds: entry.manifest.duration)).font(.caption).foregroundStyle(.secondary)
                Label(offlineSelection.isActive ? "云端视频，不参与批量操作" :
                        cloud.operations[entry.id] ?? (entry.transferError ? "iCloud 传输失败，请重试" : "轻点从 iCloud 下载并播放"),
                      systemImage: "icloud.and.arrow.down")
                    .font(.caption).foregroundStyle(.secondary)
                videoTags(entry.id)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func downloadRow(_ record: DownloadRecord) -> some View {
        if record.localCacheEvicted == true {
            unavailableCloudRow(record)
        } else {
        ZStack(alignment: .topTrailing) {
            if record.phase == .complete {
                Button { cloud.cancelPendingPlayback(); presentPlayer(record) } label: {
                    downloadSummary(record)
                        .padding(.trailing, 44)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(videoMetadata.displayTitle(for: record.id, fallback: record.candidate.title))
                .accessibilityValue(([sourceLabel(record), status(record), videoMetadataAccessibility(record.id)].filter { !$0.isEmpty }).joined(separator: " · "))
                .accessibilityHint("播放本机视频")
                .accessibilityIdentifier("offlineVideoRow")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    downloadSummary(record).padding(.trailing, 44)
                    if [.downloading, .queued, .validating].contains(record.phase) {
                        activeDownloadProgress(record)
                    } else {
                        Text(status(record)).font(.caption)
                            .foregroundStyle(record.phase == .failed ? .red : .secondary)
                            .accessibilityIdentifier("downloadStatus")
                    }
                    HStack {
                        if downloads.canPause(id: record.id) {
                            Button("暂停", systemImage: "pause") { downloads.pause(id: record.id) }.buttonStyle(.bordered)
                        }
                        if record.phase == .downloading || record.phase == .queued {
                            Button("取消", role: .destructive) { downloads.cancel(id: record.id) }.buttonStyle(.borderless)
                        } else if record.phase == .paused && !downloads.pendingResumeIDs.contains(record.id) {
                            Button("继续下载", systemImage: "play") { downloads.resume(id: record.id) }.buttonStyle(.bordered)
                                .disabled(!downloads.canResume(id: record.id))
                        } else if (record.phase == .failed || record.phase == .cancelled) &&
                                    record.candidate.source != "iCloud" && record.candidate.source != "localImport" {
                            Button("重试", systemImage: "arrow.clockwise") {
                                Task { await downloads.retry(id: record.id, cookies: await browser.webView.configuration.websiteDataStore.httpCookieStore.allCookies()) }
                            }.buttonStyle(.bordered)
                            Button("导入录屏") { showVideoImport = true }.buttonStyle(.borderless)
                        }
                    }
                }.padding(.vertical, 10)
            }
            // Keep management actions outside the playback button's hit target.
            Menu {
                videoOrganizationActions(id: record.id, title: record.candidate.title)
                if record.phase == .complete, let localURL = downloads.localURL(for: record), localURL.isFileURL {
                    Button("选择封面", systemImage: "photo") {
                        guard let current = downloads.records.first(where: { $0.id == record.id }),
                              current.phase == .complete, let currentURL = downloads.localURL(for: current) else {
                            metadataError = "本机副本已释放，请先从 iCloud 下载视频，再选择封面。"
                            return
                        }
                        if let token = coverLease { downloads.endUsingLocalVideo(token) }
                        coverLease = downloads.beginUsingLocalVideo(id: record.id)
                        storage.markUsed(record.id)
                        coverPresentation = VideoCoverPresentation(id: record.id,
                            title: videoMetadata.displayTitle(for: record.id, fallback: record.candidate.title), localURL: currentURL)
                    }.accessibilityIdentifier("chooseVideoCover")
                }
                Divider()
                if record.phase == .complete {
                    if downloads.localURL(for: record)?.pathExtension.lowercased() == "movpkg" {
                        Button("准备 iCloud 同步", systemImage: "icloud.and.arrow.up") {
                            downloads.prepareCloudCopy(id: record.id, retry: true)
                        }
                    }
                    Button("删除本机缓存", systemImage: "externaldrive.badge.minus", role: .destructive) { cloud.removeLocalCache(id: record.id) }
                }
                Button("移除视频记录", systemImage: "trash", role: .destructive) { recordToRemove = record }
                if cloud.entry(for: record.id) != nil {
                    Button("从所有设备删除", systemImage: "icloud.slash", role: .destructive) { cloudToDelete = record.id }.disabled(!cloud.isAvailable)
                }
                if record.candidate.source != "localImport", MediaCookiePolicy.validHTTPURL(record.candidate.pageURL),
                   record.candidate.pageURL.host != "icloud.invalid" {
                    Button(record.candidate.source == "iCloud" ? "打开来源站点" : "打开原网页", systemImage: "safari") { browser.open(record.candidate.pageURL.absoluteString); tab = 0 }
                }
            } label: {
                Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("管理视频")
            .accessibilityIdentifier("manageOfflineVideo")
        }
        }
    }

    private func presentPlayer(_ record: DownloadRecord) {
        guard let current = downloads.records.first(where: { $0.id == record.id }),
              current.phase == .complete, downloads.localURL(for: current) != nil else {
            if cloud.entry(for: record.id) != nil { Task { await cloud.restore(id: record.id) } }
            return
        }
        if let token = playerLease { downloads.endUsingLocalVideo(token) }
        playerLease = downloads.beginUsingLocalVideo(id: record.id)
        storage.markUsed(record.id)
        playerRecord = current
    }

    private func unavailableCloudRow(_ record: DownloadRecord) -> some View {
        HStack(alignment: .top, spacing: 12) {
            OfflineVideoThumbnail(record: record, localURL: nil, store: downloads.thumbnailStore,
                                  frameSeconds: videoMetadata.coverFrameSeconds(for: record.id))
            VStack(alignment: .leading, spacing: 4) {
                videoTitle(record.candidate.title, id: record.id)
                Text(MediaDurationFormatter.string(seconds: record.duration)).font(.caption).foregroundStyle(.secondary)
                Label("本机副本已释放，连接原 iCloud 账号后可下载播放", systemImage: "icloud.and.arrow.down")
                    .font(.caption).foregroundStyle(.secondary)
                videoTags(record.id)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                videoOrganizationActions(id: record.id, title: record.candidate.title)
                Button("从本机列表移除", systemImage: "minus.circle") { recordToRemove = record }
            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                .accessibilityLabel("管理云端视频")
        }.padding(.vertical, 10).accessibilityIdentifier("pendingCloudVideoRow")
    }

    private func downloadSummary(_ record: DownloadRecord) -> some View {
        HStack(alignment: .top, spacing: 12) {
            OfflineVideoThumbnail(record: record, localURL: downloads.localURL(for: record), store: downloads.thumbnailStore,
                                  frameSeconds: videoMetadata.coverFrameSeconds(for: record.id))
            VStack(alignment: .leading, spacing: 4) {
                videoTitle(record.candidate.title, id: record.id)
                Text(sourceLabel(record)).font(.caption).foregroundStyle(.secondary)
                if record.phase == .complete {
                    Text(status(record)).font(.caption).foregroundStyle(.secondary)
                    if let preparation = downloads.cloudPreparationStatus[record.id] {
                        Text(preparation).font(.caption).foregroundStyle(.secondary)
                    }
                    if let message = cloud.status(for: record) { Text(message).font(.caption).foregroundStyle(.secondary) }
                } else if record.candidate.source == "iCloud" {
                    Text("连接 iCloud 后可重新下载此视频").font(.caption).foregroundStyle(.secondary)
                }
                videoTags(record.id)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sourceLabel(_ record: DownloadRecord) -> String {
        if record.candidate.source == "localImport" { return "本机导入" }
        if record.candidate.pageURL.host == "icloud.invalid" { return "iCloud 视频" }
        return record.candidate.pageURL.host ?? "视频"
    }

    private func progressPresentation(_ record: DownloadRecord) -> DownloadProgressPresentation {
        DownloadProgressPresentation(phase: record.phase, bytesWritten: record.bytesWritten,
            expectedBytes: record.expectedBytes, reportedFraction: record.progress)
    }

    private func activeDownloadProgress(_ record: DownloadRecord) -> some View {
        let progress = progressPresentation(record)
        let needsForeground = downloads.isBrowserDownload(id: record.id) ||
            (record.candidate.kind == .hls && record.candidate.requestContext != nil)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                if progress.fraction == nil {
                    ProgressView().accessibilityLabel(progress.status)
                        .accessibilityIdentifier("downloadActivity")
                }
                Text(progress.status).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("downloadStatus")
                if let percentage = progress.percentage {
                    Text(percentage).font(.subheadline.monospacedDigit().weight(.medium))
                        .accessibilityIdentifier("downloadPercentage")
                }
            }
            if let fraction = progress.fraction {
                ProgressView(value: fraction).accessibilityIdentifier("downloadProgress")
                    .accessibilityValue(progress.percentage ?? "")
            }
            if needsForeground, record.phase != .validating {
                Text("请保持 App 在前台").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func status(_ record: DownloadRecord) -> String {
        if downloads.pendingResumeIDs.contains(record.id) { return "等待继续下载…" }
        switch record.phase {
        case .queued, .downloading, .validating: return progressPresentation(record).status
        case .paused: return downloads.resumeBlockReason(id: record.id) ?? record.failure ?? "已暂停，可继续下载"
        case .complete: return "\(record.hasAudio == true ? "含音轨" : "无音轨") · \(MediaDurationFormatter.string(seconds: record.duration))"
        case .failed: return record.failure ?? "下载失败，请返回网页重试"
        case .cancelled: return record.failure ?? "已取消，收藏和观看位置保留"
        }
    }

    private var addressSheet: some View {
        NavigationStack {
            Form {
                Section("网址") {
                    AddressInputControls(address: $address, openAddress: openAddress)
                }
                if !library.recent.isEmpty {
                    Section {
                        ForEach(library.recent.prefix(8)) { page in Button(page.title) { address = page.url.absoluteString; openAddress() } }
                    } header: {
                        HStack {
                            Text("最近访问")
                            Spacer()
                            HistoryButton(library: library, browser: browser, openPage: openHistoryPage)
                        }
                    }
                }
            }.navigationTitle("去一个站点").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { showAddress = false } } }
        }
    }
    private func openAddress() {
        let input = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        browser.open(input); showAddress = false; tab = 0
    }
    private func openHistoryPage(_ page: SavedPage) { address = page.url.absoluteString; openAddress() }
}

private struct AddressInputControls: View {
    @Binding var address: String
    let openAddress: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        // Read the binding in the presented view itself. The field, clear button
        // and submit state must all observe the address set while opening it.
        HStack(spacing: 8) {
            TextField("输入任意视频站点网址", text: $address)
                .textContentType(.URL).keyboardType(.URL).textInputAutocapitalization(.never)
                .autocorrectionDisabled().submitLabel(.go).onSubmit(openAddress)
                .focused($isFocused).frame(maxWidth: .infinity)
                .accessibilityIdentifier("urlInput")
            if !address.isEmpty {
                Button {
                    address = ""
                    isFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("清空网址")
                    .accessibilityIdentifier("clearURLInput")
            }
        }.accessibilityElement(children: .contain)
        Button("打开站点", action: openAddress)
            .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("navigate")
    }
}

struct BrowserSurface: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

extension WKHTTPCookieStore {
    func allCookies() async -> [HTTPCookie] { await withCheckedContinuation { continuation in getAllCookies { continuation.resume(returning: $0) } } }
}
