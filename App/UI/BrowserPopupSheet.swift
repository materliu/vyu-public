import SwiftUI

struct BrowserPopupSheet: View {
    @ObservedObject var popup: BrowserPopup
    let canReturnToXLogin: Bool
    let onReturnToXLogin: () -> Void
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "globe").foregroundStyle(.secondary)
                    Text(popup.hostDisplay).font(.subheadline).lineLimit(1)
                        .accessibilityIdentifier("browserPopupHost")
                    Spacer()
                    if popup.isLoading {
                        ProgressView()
                        Button("停止") { popup.stop() }
                            .accessibilityIdentifier("stopBrowserPopup")
                    }
                }.padding(.horizontal).padding(.vertical, 10)
                Divider()

                if popup.isGoogleSignIn {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Google 不支持在应用内嵌浏览器中登录。")
                            .font(.subheadline.weight(.medium))
                        if canReturnToXLogin {
                            Text("请返回 X，使用 X 账号和密码登录。")
                                .font(.footnote).foregroundStyle(.secondary)
                            Button("返回 X 登录") { onReturnToXLogin() }
                                .accessibilityIdentifier("returnToXLogin")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding().background(Color.orange.opacity(0.10))
                    .accessibilityIdentifier("googleEmbeddedLoginNotice")
                }

                BrowserSurface(webView: popup.webView)
                    .accessibilityIdentifier("browserPopupWebView")

                if let error = popup.errorMessage {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(error).font(.subheadline)
                        if popup.canRetry {
                            Button("重试") { popup.retry() }
                                .accessibilityIdentifier("retryBrowserPopup")
                        } else {
                            Button("返回原网页") { onClose() }
                                .accessibilityIdentifier("returnFromBrowserPopup")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding().background(.regularMaterial)
                } else if !popup.statusText.isEmpty {
                    Text(popup.statusText).font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding()
                }
            }
            .navigationTitle("网页窗口").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { onClose() }
                        .accessibilityIdentifier("closeBrowserPopup")
                }
            }
        }
        .accessibilityIdentifier("browserPopup")
    }
}
