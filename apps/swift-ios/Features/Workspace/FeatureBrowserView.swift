import SwiftUI
import WebKit

struct FeatureBrowserView: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @StateObject private var controller = FeatureBrowserController()
    @State private var urlText = ""
    @State private var recentURLs: [String] = []
    @State private var localServers: [FeatureLocalServer] = []
    @State private var errorMessage: String?

    let client: any FeatureClient
    let threadID: String
    let initialURL: URL?

    init(
        client: any FeatureClient,
        threadID: String,
        initialURL: URL? = nil
    ) {
        self.client = client
        self.threadID = threadID
        self.initialURL = initialURL
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                browserToolbar
                Divider()

                if let url = controller.currentURL {
                    FeatureBrowserWebView(controller: controller, url: url)
                        .overlay {
                            if controller.isLoading {
                                ProgressView()
                                    .controlSize(.small)
                                    .padding(10)
                                    .background(.regularMaterial, in: Capsule())
                            }
                        }
                } else {
                    browserEmptyState
                }
            }
            .navigationTitle("Browser")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert(
                "Could not open URL",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "The URL could not be opened.")
            }
        }
        .task {
            recentURLs = loadRecentURLs()
            guard let initialURL else { return }
            await open(initialURL.absoluteString, record: true)
        }
        .task {
            for await servers in client.discoveredLocalServers(threadID: threadID, configuredURLs: []) {
                localServers = servers
            }
        }
    }

    private var browserToolbar: some View {
        HStack(spacing: 8) {
            Button {
                controller.goBack()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!controller.canGoBack)

            Button {
                controller.goForward()
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!controller.canGoForward)

            TextField("Open a local app or URL", text: $urlText)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { Task { await open(urlText, record: true) } }

            Button {
                Task { await open(urlText, record: true) }
            } label: {
                Image(systemName: "arrow.right.circle.fill")
            }
            .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button {
                controller.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(controller.currentURL == nil)
        }
        .font(.body.weight(.semibold))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var browserEmptyState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ContentUnavailableView(
                    "Open a local app or URL",
                    systemImage: "safari",
                    description: Text("Enter a URL above or choose a service running on the connected machine.")
                )

                if !localServers.isEmpty {
                    browserSection("Local servers", systemImage: "dot.radiowaves.left.and.right") {
                        ForEach(localServers) { server in
                            Button {
                                Task { await open(server.url, record: true) }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "network")
                                        .foregroundStyle(T3Colors.accent)
                                        .frame(width: 28)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(server.processName ?? "Local service")
                                            .font(T3Typography.supportingStrong)
                                            .foregroundStyle(T3Colors.textPrimary)
                                        Text("\(server.host):\(server.port)")
                                            .font(T3Typography.supporting)
                                            .foregroundStyle(T3Colors.textSecondary)
                                    }
                                    Spacer(minLength: 8)
                                    Image(systemName: "chevron.right")
                                        .foregroundStyle(T3Colors.textTertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 10)
                        }
                    }
                }

                if !recentURLs.isEmpty {
                    browserSection("Recently used", systemImage: "clock") {
                        ForEach(recentURLs, id: \.self) { url in
                            Button {
                                Task { await open(url, record: true) }
                            } label: {
                                Label(url, systemImage: "globe")
                                    .foregroundStyle(T3Colors.textPrimary)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 8)
                        }
                    }
                }
            }
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
            .padding(24)
        }
    }

    private func browserSection<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(T3Typography.supportingStrong)
                .foregroundStyle(T3Colors.textSecondary)
            VStack(alignment: .leading, spacing: 0, content: content)
                .padding(.horizontal, 14)
                .background(T3Colors.surfaceRaised, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func open(_ rawValue: String, record: Bool) async {
        do {
            let normalized = try normalizedURL(rawValue)
            let resolved: URL
            if let resolver = client as? any FeatureWebsitePreviewResolving {
                resolved = try resolver.websitePreviewURL(threadID: threadID, localURL: normalized)
            } else {
                resolved = normalized
            }
            controller.load(resolved)
            urlText = resolved.absoluteString
            if record {
                recordRecentURL(resolved.absoluteString)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func normalizedURL(_ rawValue: String) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FeatureBrowserError.invalidURL }
        let value = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else {
            throw FeatureBrowserError.invalidURL
        }
        return url
    }

    private var historyKey: String { "t3.browser.recent.\(threadID)" }

    private func loadRecentURLs() -> [String] {
        UserDefaults.standard.stringArray(forKey: historyKey) ?? []
    }

    private func recordRecentURL(_ url: String) {
        recentURLs.removeAll { $0 == url }
        recentURLs.insert(url, at: 0)
        recentURLs = Array(recentURLs.prefix(8))
        UserDefaults.standard.set(recentURLs, forKey: historyKey)
    }
}

private enum FeatureBrowserError: LocalizedError {
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter a valid http or https URL."
        }
    }
}

@MainActor
private final class FeatureBrowserController: NSObject, ObservableObject, WKNavigationDelegate {
    weak var webView: WKWebView?
    @Published var currentURL: URL?
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false

    func load(_ url: URL) {
        currentURL = url
        guard let webView,
              webView.url?.absoluteString != url.absoluteString else { return }
        webView.load(URLRequest(url: url))
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
        isLoading = true
        currentURL = webView.url
        updateNavigationState(webView)
    }

    func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
        isLoading = false
        currentURL = webView.url
        updateNavigationState(webView)
    }

    func webView(_ webView: WKWebView, didFail _: WKNavigation!, withError _: Error) {
        isLoading = false
        currentURL = webView.url
        updateNavigationState(webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError _: Error) {
        isLoading = false
        currentURL = webView.url
        updateNavigationState(webView)
    }

    private func updateNavigationState(_ webView: WKWebView) {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }
}

private struct FeatureBrowserWebView: UIViewRepresentable {
    @ObservedObject var controller: FeatureBrowserController
    let url: URL

    func makeUIView(context _: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = controller
        controller.webView = webView
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context _: Context) {
        guard webView.url?.absoluteString != url.absoluteString else { return }
        webView.load(URLRequest(url: url))
    }
}
