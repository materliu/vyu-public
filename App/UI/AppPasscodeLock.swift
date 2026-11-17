import SwiftUI
import UIKit
import CryptoKit

/// A session-only content gate. The public surface never receives library data.
@MainActor
final class AppPasscodeLock: ObservableObject {
    @Published private(set) var isUnlocked = false
    @Published private(set) var isActive = false
    @Published private(set) var isPromptPresented = false
    @Published private(set) var hasError = false
    var visibilityChanged: ((Bool) -> Void)?

    private let phraseDigest: String

    init(phraseDigest: String? = nil) {
        self.phraseDigest = phraseDigest ?? Bundle.main.object(forInfoDictionaryKey: "VYuContentPhraseDigest") as? String ?? ""
    }

    private weak var appWindow: UIWindow?
    private var lockWindow: UIWindow?
    private var observers: [NSObjectProtocol] = []

    func showPrompt() {
        guard isActive, !isUnlocked else { return }
        hasError = false
        isPromptPresented = true
    }

    func cancelPrompt() {
        isPromptPresented = false
        hasError = false
    }

    func submit(_ phrase: String) {
        guard isActive, !isUnlocked, isPromptPresented else { return }
        // A fixed local phrase, as requested. Store no entered phrase or unlocked session.
        let normalized = phrase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.utf8.count <= 64 else { hasError = true; return }
        let digest = SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
        guard digest == phraseDigest else {
            hasError = true
            return
        }
        isUnlocked = true
        cancelPrompt()
        updateWindow()
    }

    func hideContent() {
        isUnlocked = false
        cancelPrompt()
        updateWindow()
    }

    func sceneChanged(to state: UIScene.ActivationState) {
        isActive = state == .foregroundActive
        if !isActive { cancelPrompt() }
        if state == .background || state == .unattached { isUnlocked = false }
        updateWindow()
    }

    func attach(to window: UIWindow) {
        guard appWindow !== window, let scene = window.windowScene else { return }
        detach()
        appWindow = window
        let cover = UIWindow(windowScene: scene)
        cover.windowLevel = .alert + 1
        let host = UIHostingController(rootView: ConcealedContentView(lock: self))
        host.view.accessibilityViewIsModal = true
        cover.rootViewController = host
        lockWindow = cover
        let notifications: [(Notification.Name, UIScene.ActivationState)] = [
            (UIScene.willDeactivateNotification, .foregroundInactive),
            (UIScene.didEnterBackgroundNotification, .background),
            (UIScene.didActivateNotification, .foregroundActive)
        ]
        for (name, state) in notifications {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: scene, queue: .main) { [weak self] _ in
                // UIKit delivers scene lifecycle notifications on the main thread.
                MainActor.assumeIsolated { self?.sceneChanged(to: state) }
            })
        }
        sceneChanged(to: scene.activationState)
    }

    func detach() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        appWindow?.accessibilityElementsHidden = false
        lockWindow?.isHidden = true
        lockWindow?.rootViewController = nil
        lockWindow = nil
        appWindow = nil
    }

    private func updateWindow() {
        let shouldCover = !isUnlocked || !isActive
        visibilityChanged?(!shouldCover)
        guard let appWindow, let lockWindow else { return }
        appWindow.accessibilityElementsHidden = shouldCover
        if shouldCover {
            if lockWindow.isHidden {
                appWindow.endEditing(true)
                lockWindow.makeKeyAndVisible()
            }
        } else if !lockWindow.isHidden {
            lockWindow.isHidden = true
            appWindow.makeKey()
        }
    }
}

/// A separate window covers sheets and players too, including the app-switcher snapshot.
struct AppPasscodeWindowAnchor: UIViewRepresentable {
    let lock: AppPasscodeLock

    func makeUIView(context: Context) -> AnchorView { AnchorView(lock: lock) }
    func updateUIView(_ uiView: AnchorView, context: Context) {}
    static func dismantleUIView(_ uiView: AnchorView, coordinator: ()) { uiView.lock.detach() }

    final class AnchorView: UIView {
        let lock: AppPasscodeLock
        init(lock: AppPasscodeLock) {
            self.lock = lock
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            // SwiftUI mounts this anchor during a view update. Creating a hosting
            // controller and publishing lock state here reenters that update.
            // Wait until mounting finishes, and ignore stale window attachments.
            guard let window else { return }
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                self.lock.attach(to: window)
            }
        }
    }
}

/// Independent empty pages: no records, cloud state, search suggestions or storage counts.
private struct ConcealedContentView: View {
    @ObservedObject var lock: AppPasscodeLock
    @State private var tab = 0
    private let labels = ["浏览", "收藏", "离线"]
    private let icons = ["safari", "bookmark", "arrow.down.circle"]
    private let emptyTitles = ["暂无内容", "暂无收藏", "暂无视频"]

    var body: some View {
        TabView(selection: $tab) {
            ForEach(0..<3) { index in
                NavigationStack {
                    ContentUnavailableView(emptyTitles[index], systemImage: icons[index])
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(uiColor: .systemGroupedBackground))
                        .toolbar {
                            ToolbarItem(placement: .principal) {
                                Text("V语").font(.headline)
                                    .padding(.horizontal, 32).padding(.vertical, 12)
                                    .contentShape(Rectangle())
                                    .onLongPressGesture(minimumDuration: 2) { lock.showPrompt() }
                                    .accessibilityAddTraits(.isButton)
                                    .accessibilityAction(named: Text("输入访问口令")) { lock.showPrompt() }
                                    .accessibilityIdentifier("concealedTitle")
                            }
                        }
                        .navigationBarTitleDisplayMode(.inline)
                }
                .tabItem { Label(labels[index], systemImage: icons[index]) }.tag(index)
            }
        }
        .tint(Color(red: 0.14, green: 0.37, blue: 0.27))
        .accessibilityIdentifier("concealedContent")
        .sheet(isPresented: Binding(get: { lock.isPromptPresented }, set: { if !$0 { lock.cancelPrompt() } })) {
            ContentPhraseSheet(lock: lock)
        }
        .onChange(of: lock.isUnlocked) { _, _ in tab = 0 }
    }
}

private struct ContentPhraseSheet: View {
    @ObservedObject var lock: AppPasscodeLock
    @State private var phrase = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                SecureField("输入口令", text: $phrase)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .submitLabel(.go)
                    .focused($focused)
                    .accessibilityIdentifier("contentPhraseInput")
                    .onSubmit(submit)
                Text(lock.hasError ? "未能打开，请重试" : " ")
                    .font(.footnote).foregroundStyle(.red)
                    .accessibilityIdentifier("contentPhraseError")
            }
            .padding(24)
            .navigationTitle("访问口令")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { phrase = ""; lock.cancelPrompt() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("打开", action: submit).disabled(phrase.isEmpty)
                        .accessibilityIdentifier("submitContentPhrase")
                }
            }
        }
        .presentationDetents([.height(220)])
        .onAppear { focused = true }
        .onDisappear { phrase = "" }
    }

    private func submit() {
        lock.submit(phrase)
        phrase = ""
    }
}
