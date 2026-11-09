import SwiftUI
import UIKit

/// An in-memory app gate. It deliberately does not persist an unlocked session.
@MainActor
final class AppPasscodeLock: ObservableObject {
    @Published private(set) var digits = ""
    @Published private(set) var isUnlocked = false
    @Published private(set) var isActive = false
    @Published private(set) var hasError = false

    private weak var appWindow: UIWindow?
    private var lockWindow: UIWindow?
    private var observers: [NSObjectProtocol] = []

    func enter(_ digit: Int) {
        guard isActive, !isUnlocked, (0...9).contains(digit), digits.count < 6 else { return }
        hasError = false
        digits.append(String(digit))
        guard digits.count == 6 else { return }
        if digits == "654321" {
            isUnlocked = true
            digits = ""
            updateWindow()
        } else {
            digits = ""
            hasError = true
        }
    }

    func deleteLastDigit() {
        guard isActive, !isUnlocked else { return }
        hasError = false
        if !digits.isEmpty { digits.removeLast() }
    }

    func sceneChanged(to state: UIScene.ActivationState) {
        isActive = state == .foregroundActive
        if !isActive {
            digits = ""
            hasError = false
        }
        if state == .background || state == .unattached { isUnlocked = false }
        updateWindow()
    }

    func attach(to window: UIWindow) {
        guard appWindow !== window, let scene = window.windowScene else { return }
        detach()
        appWindow = window
        let cover = UIWindow(windowScene: scene)
        cover.windowLevel = .alert + 1
        let host = UIHostingController(rootView: AppPasscodeView(lock: self))
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
        guard let appWindow, let lockWindow else { return }
        let shouldCover = !isUnlocked || !isActive
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
            if let window { lock.attach(to: window) }
        }
    }
}

private struct AppPasscodeView: View {
    @ObservedObject var lock: AppPasscodeLock
    private let accent = Color(red: 0.14, green: 0.37, blue: 0.27)

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 12) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 28)).foregroundStyle(accent)
                            .accessibilityHidden(true)
                        Text("输入密码").font(.title2.weight(.semibold))
                        Text("输入六位数字密码以打开 V语")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    VStack(spacing: 14) {
                        HStack(spacing: 18) {
                            ForEach(0..<6) { index in
                                Circle()
                                    .fill(index < lock.digits.count ? accent : Color.clear)
                                    .frame(width: 13, height: 13)
                                    .overlay(Circle().strokeBorder(accent, lineWidth: 1.5))
                            }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("密码")
                        .accessibilityValue("已输入 \(lock.digits.count) 位，共 6 位")
                        .accessibilityIdentifier("appPasscodeProgress")
                        Text(lock.hasError ? "密码错误，请重新输入" : " ")
                            .font(.footnote).foregroundStyle(.red)
                            .accessibilityIdentifier("appPasscodeError")
                    }
                    Grid(horizontalSpacing: 26, verticalSpacing: 14) {
                        ForEach(0..<3) { row in
                            GridRow {
                                ForEach(1..<4) { column in digitButton(row * 3 + column) }
                            }
                        }
                        GridRow {
                            Color.clear.frame(width: 72, height: 60).accessibilityHidden(true)
                            digitButton(0)
                            Button(action: lock.deleteLastDigit) {
                                Image(systemName: "delete.left")
                                    .font(.title2).frame(width: 72, height: 60)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel("删除一位")
                            .accessibilityIdentifier("appPasscodeDelete")
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!lock.isActive)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
                .frame(minHeight: geometry.size.height)
            }
            .scrollIndicators(.hidden)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .tint(accent)
        .accessibilityIdentifier("appPasscodeLock")
    }

    private func digitButton(_ digit: Int) -> some View {
        Button { lock.enter(digit) } label: {
            Text(String(digit))
                .font(.system(size: 28, weight: .regular, design: .rounded))
                .frame(width: 72, height: 60)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
                .contentShape(Capsule())
        }
        .accessibilityLabel(String(digit))
        .accessibilityIdentifier("appPasscodeDigit\(digit)")
    }
}
