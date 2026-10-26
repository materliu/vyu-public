import SwiftUI

struct HistoryButton: View {
    @ObservedObject var library: LibraryStore
    let browser: BrowserModel
    var iconOnly = false
    let openPage: (SavedPage) -> Void
    @State private var isPresented = false
    @State private var selectedPage: SavedPage?

    var body: some View {
        Button { isPresented = true } label: {
            if iconOnly { Image(systemName: "clock") }
            else { Text("管理").font(.subheadline) }
        }
        .accessibilityLabel(iconOnly ? "访问历史" : "管理最近访问")
        .accessibilityIdentifier(iconOnly ? "showHistory" : "manageRecent")
        .sheet(isPresented: $isPresented, onDismiss: {
            if let page = selectedPage { selectedPage = nil; openPage(page) }
        }) {
            HistorySheet(library: library, browser: browser) { page in
                selectedPage = page; isPresented = false
            }
        }
    }
}

private struct HistorySheet: View {
    @ObservedObject var library: LibraryStore
    let browser: BrowserModel
    let openPage: (SavedPage) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClear = false
    @State private var showSaveError = false

    var body: some View {
        NavigationStack {
            Group {
                if library.recent.isEmpty {
                    ContentUnavailableView("还没有访问历史", systemImage: "clock",
                        description: Text("访问过的网页会显示在这里。"))
                        .accessibilityIdentifier("emptyHistory")
                } else {
                    List(library.recent) { page in
                        Button { openPage(page) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(page.title).foregroundStyle(.primary).lineLimit(2)
                                Text(page.url.host ?? "网页").font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .accessibilityIdentifier("historyRow")
                        .swipeActions(allowsFullSwipe: false) {
                            Button("删除", role: .destructive) { remove(page) }
                                .accessibilityIdentifier("deleteHistoryRow")
                        }
                    }
                }
            }
            .navigationTitle("访问历史").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }.accessibilityIdentifier("closeHistory")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("清空", role: .destructive) { confirmClear = true }
                        .disabled(library.recent.isEmpty).accessibilityIdentifier("clearHistory")
                }
            }
            .alert("清空访问历史？", isPresented: $confirmClear) {
                Button("清空全部历史", role: .destructive) {
                    do {
                        try library.clearRecent()
                        browser.suppressPendingHistory()
                    } catch { showSaveError = true }
                }.accessibilityIdentifier("confirmClearHistory")
                Button("取消", role: .cancel) {}.accessibilityIdentifier("cancelClearHistory")
            } message: {
                Text("将清空本机的最近访问和访问历史。网页收藏、离线视频和登录状态会保留。")
            }
            .alert("未能清理访问历史", isPresented: $showSaveError) {
                Button("知道了", role: .cancel) {}
            } message: { Text("本机记录未能保存，请稍后重试。") }
        }
    }

    private func remove(_ page: SavedPage) {
        do {
            try library.removeRecent(url: page.url)
            browser.suppressPendingHistory(url: page.url)
        } catch { showSaveError = true }
    }
}
