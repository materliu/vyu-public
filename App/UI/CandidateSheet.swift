import SwiftUI

struct CandidateSheet: View {
    @ObservedObject var browser: BrowserModel
    @ObservedObject var downloads: DownloadManager
    let initialCandidate: MediaCandidate?
    let didStart: (MediaCandidate) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: MediaCandidate?
    @State private var inspection: MediaInspection?
    @State private var variant: MediaVariant?
    @State private var isInspecting = false
    @State private var isStarting = false
    @State private var inspectionTask: Task<Void, Never>?
    @State private var startingTask: Task<Void, Never>?
    @State private var selectionID = UUID()
    @State private var hlsOrigin: MediaCandidate?
    @State private var hasRefreshed = false

    private var candidates: [MediaCandidate] {
        if let initialCandidate, !hasRefreshed { return [selected ?? initialCandidate] }
        if let selected, !browser.candidates.contains(where: { $0.id == selected.id }) {
            return [selected] + browser.candidates
        }
        return browser.candidates
    }

    var body: some View {
        NavigationStack {
            List {
                if candidates.isEmpty {
                    Section {
                        ContentUnavailableView("还未发现可保存的视频", systemImage: "video.badge.ellipsis", description: Text("先在网页播放视频，再检查。需要登录的站点，请先在网页完成登录。"))
                        Text(browser.statusText).font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    Section(initialCandidate == nil || hasRefreshed ? "选择视频来源" : "选中的视频") {
                        if (initialCandidate == nil || hasRefreshed) && candidates.count > 1 {
                            Text("这些地址可能是不同视频、画质或旧链接。建议返回网页，点对应视频旁的“下载此视频”。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        ForEach(candidates) { candidate in
                            Button { select(candidate) } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(candidate.title.isEmpty ? "视频" : candidate.title).foregroundStyle(.primary).lineLimit(2)
                                        Text("\(kindName(candidate.kind)) · \(candidate.url.host ?? "未知来源")").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if selected?.id == candidate.id { Image(systemName: "checkmark.circle.fill") }
                                }
                            }.disabled(isStarting).accessibilityIdentifier("candidate-\(candidate.kind.rawValue)")
                        }
                    }
                }
                Section {
                    Button("重新识别当前来源") {
                        resetSelection()
                        browser.refreshCandidates(resetHistory: true)
                    }.disabled(isStarting).accessibilityIdentifier("refreshCandidates")
                }
                if isInspecting { Section { ProgressView("正在检查画质与音轨…") } }
                if let origin = hlsOrigin, selected?.kind == .hls, !browser.alternatives(for: origin).isEmpty {
                    Section("同一视频的 MP4 来源") {
                        Text("网页同时提供了这些版本。HLS 无法下载时可改选 MP4，保存后也可同步到 iCloud。")
                            .font(.footnote).foregroundStyle(.secondary)
                        ForEach(Array(browser.alternatives(for: origin).enumerated()), id: \.element.id) { index, candidate in
                            Button("检查 MP4 版本 \(index + 1)") { select(candidate) }
                                .disabled(isStarting).accessibilityIdentifier("selectMP4Alternative")
                        }
                    }
                } else if let origin = hlsOrigin, selected?.kind == .file {
                    Section { Button("返回 HLS 来源") { select(origin) }.disabled(isStarting) }
                }
                if let inspection {
                    Section("下载前确认") {
                        Text(inspection.summary).accessibilityIdentifier("inspectionSummary")
                        if inspection.requiresForeground {
                            Text("下载期间请保持 App 在前台。切到后台会暂停，继续时将重新下载。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Text(inspection.expectedBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "文件大小未知").font(.subheadline).foregroundStyle(.secondary)
                        Text(inspection.audioTracks.isEmpty ? "音轨信息待下载后检查" : "音轨：" + inspection.audioTracks.joined(separator: "、")).font(.subheadline)
                        if selected?.kind == .file { Text("画质信息未知，将保存原文件").font(.subheadline).foregroundStyle(.secondary) }
                        ForEach(inspection.variants) { option in
                            Button { variant = option } label: { HStack { Text(option.label); Spacer(); if variant?.id == option.id { Image(systemName: "checkmark") } } }
                                .disabled(isStarting)
                        }
                        if inspection.downloadable {
                            Button {
                                guard let selected else { return }
                                let chosenVariant = variant, chosenID = selectionID, documentID = browser.documentID
                                let discoveryID = browser.discoveryID
                                isStarting = true
                                startingTask = Task {
                                    guard let prepared = await browser.prepareForDownload(selected) else {
                                        isStarting = false; dismiss(); return
                                    }
                                    let candidate = MediaCandidate(url: chosenVariant?.url ?? prepared.url, pageURL: prepared.pageURL, frameURL: prepared.frameURL, title: prepared.title, kind: prepared.kind, source: prepared.source, mimeType: prepared.mimeType, userAgent: prepared.userAgent, requestContext: prepared.requestContext)
                                    let cookies = await browser.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                                    guard !Task.isCancelled, browser.documentID == documentID,
                                          browser.discoveryID == discoveryID, selectionID == chosenID,
                                          browser.isCurrentCandidate(prepared) else {
                                        isStarting = false; return
                                    }
                                    if let existing = BrowserDownloadPolicy.existingDownload(candidate, in: downloads) {
                                        if existing.phase == .paused { downloads.resume(id: existing.id) }
                                        isStarting = false; didStart(candidate); return
                                    }
                                    await downloads.start(candidate: candidate, cookies: cookies)
                                    isStarting = false
                                    guard !Task.isCancelled else { return }
                                    didStart(candidate)
                                }
                            } label: { Label(isStarting ? "准备下载…" : "开始下载", systemImage: "arrow.down.circle.fill").frame(maxWidth: .infinity) }
                            .buttonStyle(.borderedProminent).disabled(isStarting).accessibilityIdentifier("startDownload")
                        }
                        if inspection.webSessionRetryAllowed {
                            Text("可用当前网页会话再试一次，下载期间请保持 App 在前台。")
                                .font(.footnote).foregroundStyle(.secondary)
                            Button(isStarting ? "准备下载…" : "用网页会话重试") {
                                guard let selected else { return }
                                let chosenID = selectionID, documentID = browser.documentID
                                let discoveryID = browser.discoveryID
                                isStarting = true
                                startingTask = Task {
                                    guard let prepared = await browser.prepareForDownload(selected) else {
                                        isStarting = false; dismiss(); return
                                    }
                                    guard !Task.isCancelled, browser.documentID == documentID,
                                          browser.discoveryID == discoveryID, selectionID == chosenID,
                                          browser.isCurrentCandidate(prepared) else {
                                        isStarting = false; return
                                    }
                                    if let existing = BrowserDownloadPolicy.existingDownload(prepared, in: downloads) {
                                        if existing.phase == .paused { downloads.resume(id: existing.id) }
                                        isStarting = false; didStart(prepared); return
                                    }
                                    downloads.startUsingBrowser(candidate: prepared, webView: browser.webView)
                                    isStarting = false; didStart(prepared)
                                }
                            }.disabled(isStarting).accessibilityIdentifier("startBrowserDownload")
                        }
                    }
                }
                Section {
                    Text("下载完成后会检查视频是否可播放。网页播放使用的临时链接可能失效；失败时可返回原网页重新识别。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("下载到本机").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task {
                if let initialCandidate { select(initialCandidate) }
                else if candidates.count == 1, let first = candidates.first { select(first) }
            }
            .onChange(of: browser.discoveryID) { _, _ in resetSelection() }
            .onDisappear { inspectionTask?.cancel(); startingTask?.cancel() }
        }
    }
    private func resetSelection() {
        inspectionTask?.cancel(); startingTask?.cancel()
        selectionID = UUID(); selected = nil; inspection = nil; variant = nil; hlsOrigin = nil
        hasRefreshed = true; isInspecting = false; isStarting = false
    }
    private func finishUnavailableInspection() {
        isInspecting = false; variant = nil
        if browser.protectedContentDetected {
            inspection = MediaInspection(summary: DownloadIssue.protectedContent.localizedDescription,
                variants: [], audioTracks: [], expectedBytes: nil, downloadable: false)
        } else {
            selected = nil; inspection = nil; hlsOrigin = nil; hasRefreshed = true
        }
    }
    private func select(_ candidate: MediaCandidate) {
        inspectionTask?.cancel()
        let requestID = UUID(); selectionID = requestID
        let discoveryID = browser.discoveryID
        selected = candidate; inspection = nil; variant = nil; isInspecting = true
        if candidate.kind == .hls { hlsOrigin = candidate }
        if candidate.kind == .protected || browser.protectedContentDetected {
            inspection = MediaInspection(summary: DownloadIssue.protectedContent.localizedDescription,
                variants: [], audioTracks: [], expectedBytes: nil, downloadable: false)
            isInspecting = false; return
        }
        inspectionTask = Task {
            let prepared = await browser.prepareForDownload(candidate)
            guard selectionID == requestID, browser.discoveryID == discoveryID, !Task.isCancelled else { return }
            guard let prepared else { finishUnavailableInspection(); return }
            let cookies = await browser.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            guard selectionID == requestID, browser.discoveryID == discoveryID,
                  !Task.isCancelled else { return }
            guard browser.isCurrentCandidate(prepared) else { finishUnavailableInspection(); return }
            let result = await downloads.inspect(candidate: prepared, cookies: cookies)
            guard selectionID == requestID, browser.discoveryID == discoveryID,
                  !Task.isCancelled else { return }
            guard browser.isCurrentCandidate(prepared) else { finishUnavailableInspection(); return }
            selected = prepared
            inspection = result; variant = result.variants.first; isInspecting = false
        }
    }
    private func kindName(_ kind: MediaKind) -> String {
        switch kind { case .file: return "视频文件"; case .hls: return "HLS 分段视频"; case .dash: return "DASH 分段视频"; case .blob: return "网页临时媒体"; case .protected: return "受保护的视频" }
    }
}

@MainActor enum BrowserDownloadPolicy {
    static func existingDownload(_ candidate: MediaCandidate, in downloads: DownloadManager) -> DownloadRecord? {
        downloads.records.first {
            guard $0.candidate.id == candidate.id else { return false }
            if $0.phase == .complete { return downloads.localURL(for: $0) != nil }
            return [.queued, .downloading, .paused, .validating].contains($0.phase)
        }
    }
}
