import Darwin
import Security
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct T3LiveContainerOverlayView: View {
    @EnvironmentObject private var sharedModel: SharedModel

    @State private var isRunningRequest = false
    @State private var pendingRun: PendingRun?
    @State private var certificateRequestState: String?
    @State private var certificateRequestStartedAt: Date?
    @State private var certificateTimeoutTask: Task<Void, Never>?
    @State private var isManualImportPresented = false
    @State private var isManualFilePickerPresented = false
    @State private var manualImportData: Data?
    @State private var manualImportFileName: String?
    @State private var manualImportPassword = ""
    @State private var manualImportError: String?

    private struct PendingRun {
        let artifactURL: URL
        let bundleName: String
        let artifactSHA256: String?
        let requestID: String
    }

    var body: some View {
        // The embedded UIKit navigation controller is forced full-bleed so its
        // system bar draws under the status bar. As an unconditional fallback,
        // paint the status strip from the host side with bar-like material so
        // the region can never appear as empty background.
        T3CodeDynamicRootView()
            .ignoresSafeArea(edges: .top)
            .background(alignment: .top) {
                Rectangle()
                    .fill(.bar)
                    .frame(height: 300)
                    .ignoresSafeArea(edges: .top)
            }
            .onAppear {
                UserDefaults.standard.set(true, forKey: "LCLaunchInMultitaskMode")
                LCUtils.appGroupUserDefault.set(
                    MultitaskMode.nativeWindow.rawValue,
                    forKey: "LCMultitaskMode"
                )
                LCUtils.appGroupUserDefault.set(true, forKey: "LCSkipTerminatedScreen")
                autoPromptCertificateIfNeeded()
            }
            .onOpenURL { url in
                handle(url, allowsRun: false)
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: Notification.Name("T3CodeEmbeddedLiveContainerRoute")
                )
            ) { notification in
                guard let route = notification.object as? URL else { return }
                handle(route, allowsRun: true)
            }
            .sheet(isPresented: $isManualImportPresented) {
                manualImportSheet
            }
    }

    private var manualImportSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Text(
                        "A signing certificate is required to install apps on this phone. Choose a .p12 certificate file and enter its password. T3 Code stores it in the app container and signs future installs with it."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                Section("Certificate") {
                    Button {
                        isManualFilePickerPresented = true
                    } label: {
                        Label(
                            manualImportFileName ?? "Choose .p12 file",
                            systemImage: "key.horizontal"
                        )
                    }
                    if let fileName = manualImportFileName {
                        LabeledContent("File", value: fileName)
                    }
                    SecureField("Certificate password", text: $manualImportPassword)
                    if let manualImportError {
                        Text(manualImportError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    Button("Import Certificate") {
                        importManualCertificate()
                    }
                    .disabled(manualImportData == nil || manualImportPassword.isEmpty)
                }
                Section {
                    Button("Cancel", role: .cancel) {
                        cancelManualImport()
                    }
                }
            }
            .navigationTitle("Signing Certificate")
            .navigationBarTitleDisplayMode(.inline)
            .fileImporter(
                isPresented: $isManualFilePickerPresented,
                allowedContentTypes: [.data]
            ) { result in
                switch result {
                case .success(let url):
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    do {
                        manualImportData = try Data(contentsOf: url)
                        manualImportFileName = url.lastPathComponent
                        manualImportError = nil
                    } catch {
                        manualImportError = "T3 Code could not read the selected file."
                    }
                case .failure(let error):
                    manualImportError = error.localizedDescription
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func importManualCertificate() {
        guard let data = manualImportData else { return }
        guard !manualImportPassword.isEmpty else {
            manualImportError = "Enter the certificate password."
            return
        }
        guard canImportPKCS12(data, password: manualImportPassword) else {
            manualImportError = "T3 Code could not read this certificate. Check the password and the file."
            return
        }
        storeCertificate(data, password: manualImportPassword)
        isManualImportPresented = false
        manualImportData = nil
        manualImportFileName = nil
        manualImportPassword = ""
        manualImportError = nil
        logEvent("manual certificate import completed")
        resumePendingRunIfPossible()
    }

    private func cancelManualImport() {
        isManualImportPresented = false
        manualImportData = nil
        manualImportFileName = nil
        manualImportPassword = ""
        manualImportError = nil
        if let pending = pendingRun {
            complete(requestID: pending.requestID, error: "Certificate import was canceled.")
        }
        pendingRun = nil
    }

    // When the app comes to the foreground without a certificate (e.g. the user tapped a
    // guest-app icon, which launches T3 Code Live directly), trigger the SideStore
    // certificate export automatically instead of dead-ending on the JITLess error.
    private func autoPromptCertificateIfNeeded() {
        guard !isCertificateReady else { return }
        let lastPrompt = UserDefaults.standard.object(forKey: "T3CertImportPromptedAt") as? Date
        if let lastPrompt, Date().timeIntervalSince(lastPrompt) < 300 {
            return
        }
        UserDefaults.standard.set(Date.now, forKey: "T3CertImportPromptedAt")
        if requestCertificateImport() != nil {
            isManualImportPresented = true
        }
    }

    private func handle(_ url: URL, allowsRun: Bool) {
        // Never log query strings: the certificate callback carries the certificate and
        // its password, and other URLs may carry tokens.
        logEvent("URL received: \(url.scheme ?? "(no scheme)")://\(url.host ?? "(no host)")")
        let scheme = url.scheme?.lowercased()
        guard scheme == "t3code-livecontainer" else {
            NotificationCenter.default.post(
                name: Notification.Name("T3CodeEmbeddedOpenURL"),
                object: url
            )
            return
        }

        // SideStore/AltStore certificate-export callback (mirrors LCSettingsView.handleURL).
        if url.host?.lowercased() == "certificate" {
            handleCertificateCallback(url)
            resumePendingRunIfPossible()
            return
        }

        // Guest relaunch: the stock UI forwards livecontainer-launch URLs to the app list,
        // which re-runs the matching guest. The T3 overlay must do the same or a second
        // launch of a running app silently does nothing.
        if url.host?.lowercased() == "livecontainer-launch" {
            handleGuestRelaunch(url)
            return
        }

        guard allowsRun else {
            logEvent("rejected an external app-run request")
            return
        }

        let queryItems = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        )?.queryItems ?? []
        let requestID = queryItems.first(where: { $0.name == "request-id" })?.value
        guard url.host?.lowercased() == "run",
              let requestID,
              let artifactValue = queryItems.first(where: { $0.name == "url" })?.value,
              let artifactURL = URL(string: artifactValue),
              let artifactScheme = artifactURL.scheme?.lowercased(),
              ["file", "http", "https"].contains(artifactScheme),
              let bundleName = queryItems.first(where: { $0.name == "bundle-name" })?.value else {
            complete(requestID: requestID, error: "T3 Code received an invalid app-run request.")
            return
        }
        let artifactSHA256 = queryItems.first(where: { $0.name == "artifact-sha256" })?.value

        guard isCertificateReady else {
            logEvent("run request received but certificate is missing (appGroup: \(LCSharedUtils.appGroupID() ?? "nil"))")
            if pendingRun == nil {
                pendingRun = PendingRun(
                    artifactURL: artifactURL,
                    bundleName: bundleName,
                    artifactSHA256: artifactSHA256,
                    requestID: requestID
                )
                if requestCertificateImport() != nil {
                    // No SideStore/AltStore to export from. Fall back to the in-app
                    // manual .p12 import; the pending run resumes when it completes.
                    logEvent("no store available for export, presenting manual import")
                    isManualImportPresented = true
                } else {
                    scheduleCertificateImportTimeout()
                }
            } else {
                // Another run is already waiting for the certificate import. Fail fast so
                // the caller is not left waiting forever.
                complete(
                    requestID: requestID,
                    error: "Another iPhone app run is already waiting for the SideStore certificate export. Approve it in SideStore, then try this run again. [t3-live-r10]"
                )
            }
            return
        }

        logEvent("certificate ready, starting run")
        startRun(
            artifactURL: artifactURL,
            bundleName: bundleName,
            artifactSHA256: artifactSHA256,
            requestID: requestID
        )
    }

    private func startRun(
        artifactURL: URL,
        bundleName: String,
        artifactSHA256: String?,
        requestID: String
    ) {
        guard !isRunningRequest else {
            complete(requestID: requestID, error: "Another iPhone app is already starting.")
            return
        }
        isRunningRequest = true
        Task { @MainActor in
            defer { isRunningRequest = false }
            do {
                try await T3HeadlessAppRuntime.installAndRun(
                    artifactURL: artifactURL,
                    expectedBundleName: bundleName,
                    expectedArtifactSHA256: artifactSHA256,
                    sharedModel: sharedModel
                )
                complete(requestID: requestID, error: nil)
            } catch {
                var message = error.localizedDescription
                if isCertificateSigningFailure(message) {
                    clearStoredCertificate()
                    message += " T3 Code removed the invalid certificate. Run the app again to import a new certificate."
                }
                logEvent("run FAILED: \(message)")
                complete(requestID: requestID, error: message)
            }
        }
    }

    private var isCertificateReady: Bool {
        guard let data = LCUtils.certificateData(),
              let password = LCSharedUtils.certificatePassword() else {
            return false
        }
        return canImportPKCS12(data, password: password)
    }

    private func canImportPKCS12(_ data: Data, password: String) -> Bool {
        var importedItems: CFArray?
        let status = SecPKCS12Import(
            data as CFData,
            [kSecImportExportPassphrase as String: password] as CFDictionary,
            &importedItems
        )
        guard status == errSecSuccess,
              let item = (importedItems as? [[String: Any]])?.first,
              let identityValue = item[kSecImportItemIdentity as String] else {
            return false
        }
        let identity = identityValue as! SecIdentity
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
              let certificate else {
            return false
        }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(
            certificate,
            SecPolicyCreateBasicX509(),
            &trust
        ) == errSecSuccess, let trust else { return false }
        SecTrustSetAnchorCertificates(trust, [certificate] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        return SecTrustEvaluateWithError(trust, nil)
    }

    private func storeCertificate(_ certData: Data, password: String) {
        LCUtils.appGroupUserDefault.set(certData, forKey: "LCCertificateData")
        LCUtils.appGroupUserDefault.set(password, forKey: "LCCertificatePassword")
        LCUtils.appGroupUserDefault.set(Date.now, forKey: "LCCertificateUpdateDate")
        UserDefaults.standard.set(certData, forKey: "LCCertificateData")
        UserDefaults.standard.set(password, forKey: "LCCertificatePassword")
        UserDefaults.standard.set(Date.now, forKey: "LCCertificateUpdateDate")
        UserDefaults.standard.synchronize()
    }

    private func isCertificateSigningFailure(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return ["certificate", "pkcs", "p12", "password", "signing identity", "expired"]
            .contains(where: normalized.contains)
    }

    private func clearStoredCertificate() {
        for defaults in [LCUtils.appGroupUserDefault, UserDefaults.standard] {
            defaults.removeObject(forKey: "LCCertificateData")
            defaults.removeObject(forKey: "LCCertificatePassword")
            defaults.removeObject(forKey: "LCCertificateUpdateDate")
        }
        UserDefaults.standard.synchronize()
        certificateRequestState = nil
        certificateRequestStartedAt = nil
    }

    @discardableResult
    private func requestCertificateImport() -> String? {
        let state = UUID().uuidString
        let callback = "t3code-livecontainer://certificate?cert=$(BASE64_CERT)&password=$(PASSWORD)&state=\(state)"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let encodedCallback = callback.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return "T3 Code could not create the certificate callback."
        }
        let importURLString = "certificate?callback_template=\(encodedCallback)"
        certificateRequestState = state
        certificateRequestStartedAt = .now
        // Try SideStore first, then AltStore, mirroring the stock LiveContainer
        // settings flow. The store is not detectable here (App Group Unknown), so both
        // schemes are attempted. An unavailable scheme is ignored by the system.
        let schemes = ["sidestore", "altstore", "altstore-classic"]
        for storeScheme in schemes {
            guard let url = URL(string: "\(storeScheme)://\(importURLString)") else { continue }
            let canOpen = UIApplication.shared.canOpenURL(url)
            logEvent("import attempt via \(storeScheme):// canOpenURL=\(canOpen)")
            guard canOpen else { continue }
            logEvent("opening \(storeScheme):// certificate export dialog")
            UIApplication.shared.open(url) { opened in
                self.logEvent("open result for \(storeScheme):// = \(opened)")
            }
            return nil
        }
        certificateRequestState = nil
        certificateRequestStartedAt = nil
        return "No supported store found. SideStore or AltStore is not installed, or its version does not support certificate export. Install the latest SideStore, sign in, then run this app again. [t3-live-r10]"
    }

    private func scheduleCertificateImportTimeout() {
        certificateTimeoutTask?.cancel()
        let requestID = pendingRun?.requestID
        certificateTimeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            guard !Task.isCancelled,
                  let pending = pendingRun,
                  pending.requestID == requestID else { return }
            pendingRun = nil
            certificateRequestState = nil
            certificateRequestStartedAt = nil
            certificateTimeoutTask = nil
            logEvent("certificate import timeout after 120s")
            complete(
                requestID: pending.requestID,
                error: "The certificate export from SideStore did not complete within 2 minutes. If SideStore showed \"Failed to find certificate or password\", sign in to SideStore with your Apple ID or import a .p12 certificate there first, then run this app again. [t3-live-r10]"
            )
        }
    }

    private func handleCertificateCallback(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let queryItems = (components.queryItems ?? []).reduce(into: [String: String]()) { $0[$1.name.lowercased()] = $1.value }
        guard let expectedState = certificateRequestState,
              queryItems["state"] == expectedState,
              let requestedAt = certificateRequestStartedAt,
              Date().timeIntervalSince(requestedAt) < 300,
              let encodedCert = queryItems["cert"]?.removingPercentEncoding,
              let password = queryItems["password"],
              let certData = Data(base64Encoded: encodedCert)
        else {
            logEvent("certificate callback was invalid or expired")
            return
        }

        certificateRequestState = nil
        certificateRequestStartedAt = nil
        certificateTimeoutTask?.cancel()
        certificateTimeoutTask = nil
        logEvent("certificate callback: cert \(certData.count) bytes, password \(password.count) chars")
        storeCertificate(certData, password: password)
        logEvent("certificate stored (app group + app defaults)")
    }

        private func handleGuestRelaunch(_ url: URL) {
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let bundleName = queryItems.first(where: { $0.name == "bundle-name" })?.value else {
            logEvent("relaunch URL missing bundle-name")
            return
        }
        let folderName = queryItems.first(where: { $0.name == "container-folder-name" })?.value
        guard let model = (sharedModel.apps + sharedModel.hiddenApps).first(where: {
            $0.appInfo.relativeBundlePath == bundleName
        }) else {
            logEvent("relaunch requested for unknown bundle \(bundleName)")
            return
        }
        logEvent("relaunching guest \(bundleName) container \(folderName ?? "default")")
        Task { @MainActor in
            do {
                try await model.runApp(multitask: true, containerFolderName: folderName)
                logEvent("guest relaunch completed")
            } catch {
                logEvent("guest relaunch FAILED: \(error.localizedDescription)")
            }
        }
    }

    private func resumePendingRunIfPossible() {
        guard let pending = pendingRun else {
            logEvent("certificate callback received but no pending run")
            return
        }
        guard isCertificateReady else {
            logEvent("certificate callback received but certificate still not readable")
            return
        }
        pendingRun = nil
        logEvent("certificate ready, resuming pending run")
        startRun(
            artifactURL: pending.artifactURL,
            bundleName: pending.bundleName,
            artifactSHA256: pending.artifactSHA256,
            requestID: pending.requestID
        )
    }

    private func complete(requestID: String?, error: String?) {
        guard let requestID else { return }
        var userInfo = ["request-id": requestID]
        if let error {
            userInfo["error"] = error
        }
        NotificationCenter.default.post(
            name: Notification.Name("T3CodeEmbeddedLiveContainerResult"),
            object: nil,
            userInfo: userInfo
        )
    }

    private func logEvent(_ message: String) {
        NSLog("[T3-import] %@", message)
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let logURL = docs.appendingPathComponent("t3-live-import-log.txt")
        // All throwing APIs only: NSFileHandle's non-throwing writes raise an
        // exception on a removed or invalid file, which would crash the app.
        if let handle = try? FileHandle(forWritingTo: logURL) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: line.data(using: .utf8) ?? Data())
            try? handle.close()
        } else {
            try? line.write(to: logURL, atomically: true, encoding: .utf8)
        }
    }
}

private struct T3CodeDynamicRootView: UIViewControllerRepresentable {
    func makeUIViewController(context _: Context) -> UIViewController {
        T3CodeDynamicLoader.makeRootViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context _: Context) {}
}



private enum T3CodeDynamicLoader {
    private static var frameworkHandle: UnsafeMutableRawPointer?

    static func makeRootViewController() -> UIViewController {
        let path = "@executable_path/Frameworks/T3CodeKit.framework/T3CodeKit"
        guard let handle = dlopen(path, RTLD_NOW | RTLD_GLOBAL) else {
            return errorViewController("T3CodeKit could not load: \(dynamicLoaderError())")
        }
        frameworkHandle = handle

        guard let symbol = dlsym(handle, "T3CodeCreateRootViewController") else {
            return errorViewController("T3CodeKit does not contain its root-view factory.")
        }
        typealias Factory = @convention(c) () -> UInt
        let factory = unsafeBitCast(symbol, to: Factory.self)
        guard let pointer = UnsafeMutableRawPointer(bitPattern: factory()) else {
            return errorViewController("T3CodeKit returned an invalid root view.")
        }
        return Unmanaged<UIViewController>.fromOpaque(pointer).takeRetainedValue()
    }

    private static func dynamicLoaderError() -> String {
        guard let message = dlerror() else { return "Unknown loader error" }
        return String(cString: message)
    }

    private static func errorViewController(_ message: String) -> UIViewController {
        UIHostingController(
            rootView: VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                Text("T3 Code is unavailable")
                    .font(.headline)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
        )
    }
}
