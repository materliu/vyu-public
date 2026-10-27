import SwiftUI
import AVFoundation

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        DownloadManager.handleBackgroundEvents(identifier: identifier, completionHandler: completionHandler)
    }
}

@main struct VYuApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var browser = BrowserModel()
    @StateObject private var downloads: DownloadManager
    @StateObject private var cloud: CloudVideoSync
    @StateObject private var library: LibraryStore
    @StateObject private var videoMetadata: VideoMetadataStore
    @StateObject private var storage: VideoStorageOptimizer
    @StateObject private var downloadIdleTimer = DownloadIdleTimerController()
    @Environment(\.scenePhase) private var scenePhase
    #if DEBUG
    private let offlineBatchFixtureURL: URL?
    private let observesDownloadActivity: Bool
    @State private var fixtureSeedStarted = false
    @State private var fixtureSeedStatus = "preparing"
    @State private var inactiveIdleRestorations = 0
    #endif
    init() {
        var fixtureRoot: URL?
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let argumentID = arguments.firstIndex(of: "--fixture-cloud-sync").flatMap { index in
            arguments.count > index + 1 ? UUID(uuidString: arguments[index + 1]) : nil
        }
        let environmentID = ProcessInfo.processInfo.environment["VYU_TEST_LIBRARY_ID"].flatMap(UUID.init(uuidString:))
        if let id = environmentID ?? argumentID {
            fixtureRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("VYuUITests/\(id.uuidString)", isDirectory: true)
        }
        let fixtureAddress = arguments.firstIndex(of: "--fixture-url").flatMap { index in
            arguments.count > index + 1 ? arguments[index + 1] : nil
        }
        offlineBatchFixtureURL = fixtureRoot != nil && arguments.contains("--fixture-offline-batch")
            ? OfflineBatchFixture.baseURL(fixtureAddress) : nil
        observesDownloadActivity = fixtureRoot != nil && arguments.contains("--fixture-observe-idle-timer")
        #endif
        let downloads = DownloadManager(rootDirectory: fixtureRoot)
        let videoMetadata = VideoMetadataStore(rootDirectory: downloads.rootDirectory)
        var storageBudget: Int64 = 1_000_000_000
        #if DEBUG
        if fixtureRoot != nil, let index = arguments.firstIndex(of: "--fixture-storage-budget"),
           arguments.count > index + 1, let bytes = Int64(arguments[index + 1]),
           (1...1_000_000_000).contains(bytes) { storageBudget = bytes }
        #endif
        _downloads = StateObject(wrappedValue: downloads)
        _library = StateObject(wrappedValue: LibraryStore(directory: fixtureRoot))
        _videoMetadata = StateObject(wrappedValue: videoMetadata)
        let cloud = CloudVideoSync(downloads: downloads, metadataStore: videoMetadata,
            containerOverride: fixtureRoot?.appendingPathComponent("FixtureCloud", isDirectory: true))
        _cloud = StateObject(wrappedValue: cloud)
        let storage = VideoStorageOptimizer(downloads: downloads, cloud: cloud, budgetBytes: storageBudget)
        storage.setAppActive(false)
        _storage = StateObject(wrappedValue: storage)
    }
    var body: some Scene {
        WindowGroup {
            ContentView(browser: browser, downloads: downloads, library: library, cloud: cloud,
                        videoMetadata: videoMetadata, storage: storage)
                .tint(Color(red: 0.14, green: 0.37, blue: 0.27))
                .task {
                    downloads.setAppInBackground(scenePhase == .background)
                    storage.setAppActive(scenePhase == .active)
                    downloadIdleTimer.update(isSceneActive: scenePhase == .active,
                                             hasActiveDownloads: downloads.hasActiveDownloads)
                    try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                    let args = ProcessInfo.processInfo.arguments
                    #if DEBUG
                    if let index = args.firstIndex(of: "--fixture-url"), args.count > index + 1 { browser.open(args[index + 1]) }
                    if let baseURL = offlineBatchFixtureURL, !fixtureSeedStarted {
                        fixtureSeedStarted = true
                        do {
                            try await OfflineBatchFixture.prepare(downloads: downloads, metadata: videoMetadata, baseURL: baseURL)
                            fixtureSeedStatus = "ready"
                        } catch { fixtureSeedStatus = "failed" }
                    }
                    #endif
                    await cloud.refreshAccount()
                    await storage.maintain()
                }
                .onChange(of: scenePhase) { _, phase in
                    storage.setAppActive(phase == .active)
                    downloadIdleTimer.update(isSceneActive: phase == .active,
                                             hasActiveDownloads: downloads.hasActiveDownloads)
                    #if DEBUG
                    if observesDownloadActivity, phase != .active, !UIApplication.shared.isIdleTimerDisabled {
                        inactiveIdleRestorations += 1
                    }
                    #endif
                    if phase == .active {
                        downloads.setAppInBackground(false)
                        Task { await cloud.refreshAccount() }
                    } else if phase == .background { downloads.setAppInBackground(true) }
                }
                .onChange(of: downloads.hasActiveDownloads) { _, active in
                    downloadIdleTimer.update(isSceneActive: scenePhase == .active, hasActiveDownloads: active)
                }
                .onDisappear { downloadIdleTimer.reset() }
                #if DEBUG
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading) {
                        if offlineBatchFixtureURL != nil {
                            Text("测试资料").accessibilityIdentifier("offlineBatchFixtureReady")
                                .accessibilityValue(fixtureSeedStatus)
                        }
                        if observesDownloadActivity {
                            Text("下载活动测试").accessibilityIdentifier("downloadActivityProbe")
                                .accessibilityValue("active=\(downloads.hasActiveDownloads);idle=\(UIApplication.shared.isIdleTimerDisabled);inactiveResets=\(inactiveIdleRestorations)")
                        }
                    }.font(.system(size: 8)).allowsHitTesting(false)
                }
                #endif
        }
    }
}
