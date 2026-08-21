import Foundation
import CryptoKit

enum T3LaunchLog {
    static func write(_ message: String) {
        NSLog("[T3-launch] %@", message)
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let logURL = docs.appendingPathComponent("t3-live-import-log.txt")
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8) ?? Data())
            try? handle.close()
        } else {
            try? line.write(to: logURL, atomically: true, encoding: .utf8)
        }
    }
}

@MainActor
enum T3HeadlessAppRuntime {
    static func installAndRun(
        artifactURL: URL,
        expectedBundleName: String,
        sharedModel: SharedModel
    ) async throws {
        let app = try await install(
            artifactURL: artifactURL,
            expectedBundleName: expectedBundleName,
            sharedModel: sharedModel
        )
        T3LaunchLog.write("install complete, running app (multitask)")
        do {
            try await app.runApp(multitask: true)
            T3LaunchLog.write("runApp completed")
        } catch {
            T3LaunchLog.write("runApp FAILED: \(error.localizedDescription)")
            throw error
        }
    }

    private static func install(
        artifactURL: URL,
        expectedBundleName: String,
        sharedModel: SharedModel
    ) async throws -> LCAppModel {
        let fileManager = FileManager.default
        let workingDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("t3-ios-run-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workingDirectory) }

        let ipaURL = workingDirectory.appendingPathComponent("App.ipa")
        if artifactURL.isFileURL {
            try fileManager.copyItem(at: artifactURL, to: ipaURL)
        } else {
            try await download(artifactURL: artifactURL, destinationURL: ipaURL)
        }

        let extractResult = await decompress(
            ipaPath: ipaURL.path,
            destinationPath: workingDirectory.path
        )
        guard extractResult == 0 else {
            throw T3HeadlessAppRuntimeError.invalidIPA
        }

        let payloadURL = workingDirectory.appendingPathComponent("Payload", isDirectory: true)
        let payloadContents = try fileManager.contentsOfDirectory(atPath: payloadURL.path)
        guard let appBundleName = payloadContents.first(where: { $0.hasSuffix(".app") }),
              let incomingInfo = LCAppInfo(
                  bundlePath: payloadURL.appendingPathComponent(appBundleName).path
              ),
              let bundleIdentifier = incomingInfo.bundleIdentifier() else {
            throw T3HeadlessAppRuntimeError.invalidIPA
        }

        let installedBundleName = "\(bundleIdentifier).app"
        guard installedBundleName == expectedBundleName else {
            throw T3HeadlessAppRuntimeError.bundleIdentifierMismatch(
                expected: String(expectedBundleName.dropLast(4)),
                actual: bundleIdentifier
            )
        }

        let artifactFingerprint = try sha256(of: ipaURL)

        let appFolderURL = payloadURL.appendingPathComponent(appBundleName)
        // Keep loose Godot/Unity resources with the guest before signing. A
        // stock installer moves only the .app and would otherwise drop them.
        let looseResources = [payloadURL, workingDirectory].flatMap { directory in
            (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ))?.filter {
                let ext = $0.pathExtension.lowercased()
                return ext == "pck" || ext == "zip"
            } ?? []
        }
        for sourceURL in looseResources {
            let destinationURL = appFolderURL.appendingPathComponent(sourceURL.lastPathComponent)
            if !fileManager.fileExists(atPath: destinationURL.path) {
                try? fileManager.copyItem(at: sourceURL, to: destinationURL)
                T3LaunchLog.write("copied loose \(sourceURL.lastPathComponent) into \(appBundleName)")
            }
        }

        let existingApps = (sharedModel.apps + sharedModel.hiddenApps).filter {
            $0.bundleIdentifier == bundleIdentifier
        }
        let previousApp = existingApps.first

        if let activeApp = existingApps.first(where: { app in
            guard let dataUUID = app.appInfo.dataUUID else { return app.isAppRunning }
            if #available(iOS 16.1, *), MultitaskManager.isUsing(container: dataUUID) {
                return true
            }
            return app.isAppRunning
        }) {
            let previousFingerprint = activeApp.appInfo.info()["T3ArtifactSHA256"] as? String
            if previousFingerprint == artifactFingerprint {
                T3LaunchLog.write("same guest build is already running; reusing its multitask window")
                return activeApp
            }
            T3LaunchLog.write("refusing to replace active guest before it exits")
            throw T3HeadlessAppRuntimeError.appIsRunning
        }

        for app in existingApps {
            if let path = app.appInfo.bundlePath(), fileManager.fileExists(atPath: path) {
                try fileManager.removeItem(atPath: path)
            }
        }

        // Install as a SHARED app in the store app group when available. The LiveProcess
        // extension runs the guest in its own sandbox and can only mmap executables that live
        // in containers it is entitled to: its own container or the shared app group. A guest
        // stored in the host app's private Documents is unreachable from the extension
        // ("file system sandbox blocked mmap()"), so prefer the group path. If the group was
        // not granted at install time, LCPath.lcGroupBundlePath falls back to Documents.
        let installBaseURL = LCPath.lcGroupBundlePath
        try fileManager.createDirectory(at: installBaseURL, withIntermediateDirectories: true)
        let destinationURL = installBaseURL.appendingPathComponent(installedBundleName)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: appFolderURL, to: destinationURL)

        guard let installedInfo = LCAppInfo(bundlePath: destinationURL.path) else {
            throw T3HeadlessAppRuntimeError.invalidIPA
        }
        installedInfo.relativeBundlePath = installedBundleName
        // Patch at the final location, matching LiveContainer's stock install order.
        T3LaunchLog.write("patching and signing \(bundleIdentifier) at \(destinationURL.path)")
        let signingResult = await patchAndSign(installedInfo)
        T3LaunchLog.write("signing result: success=\(signingResult.success) message=\(signingResult.message ?? "nil")")
        guard signingResult.success else {
            throw T3HeadlessAppRuntimeError.signingFailed(
                signingResult.message ?? "The app runtime could not prepare this build."
            )
        }
        copyRuntimeConfiguration(from: previousApp?.appInfo, to: installedInfo)
        installedInfo.isShared = true
        installedInfo.isHidden = false
        installedInfo.hideLiveContainer = true
        installedInfo.multitaskSpecified = .yes
        installedInfo.spoofSDKVersion = true
        installedInfo.installationDate = .now
        installedInfo.info()["T3ArtifactSHA256"] = artifactFingerprint
        installedInfo.save()

        let installedApp = LCAppModel(appInfo: installedInfo)
        sharedModel.apps.removeAll { $0.bundleIdentifier == bundleIdentifier }
        sharedModel.hiddenApps.removeAll { $0.bundleIdentifier == bundleIdentifier }
        sharedModel.apps.append(installedApp)

        if let schemes = installedInfo.urlSchemes() as? [String], !schemes.isEmpty {
            UserDefaults.lcShared()
                .mutableArrayValue(forKey: "LCGuestURLSchemes")
                .addObjects(from: schemes)
        }
        return installedApp
    }

    private static func download(
        artifactURL: URL,
        destinationURL: URL
    ) async throws {
        T3LaunchLog.write("downloading \(artifactURL.absoluteString.prefix(120))")
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 180
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        var resumeData: Data?
        var lastError: Error?
        for attempt in 0 ..< 2 {
            do {
                let result: (URL, URLResponse)
                if let resumeData {
                    result = try await session.download(resumeFrom: resumeData)
                } else {
                    result = try await session.download(from: artifactURL)
                }
                if let response = result.1 as? HTTPURLResponse,
                   !(200 ..< 300).contains(response.statusCode) {
                    T3LaunchLog.write("download failed HTTP \(response.statusCode)")
                    throw T3HeadlessAppRuntimeError.downloadFailed(response.statusCode)
                }
                T3LaunchLog.write("download complete, moving to \(destinationURL.path)")
                try FileManager.default.moveItem(at: result.0, to: destinationURL)
                return
            } catch let error as T3HeadlessAppRuntimeError {
                throw error
            } catch {
                lastError = error
                let nsError = error as NSError
                resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
                T3LaunchLog.write(
                    "download attempt \(attempt + 1) failed: \(error.localizedDescription); "
                        + (resumeData == nil ? "restarting" : "resuming")
                )
            }
        }
        throw lastError ?? T3HeadlessAppRuntimeError.downloadFailed(0)
    }

    nonisolated private static func decompress(
        ipaPath: String,
        destinationPath: String
    ) async -> Int32 {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    returning: extract(
                        ipaPath,
                        destinationPath,
                        Progress.discreteProgress(totalUnitCount: 100)
                    )
                )
            }
        }
    }

    private static func patchAndSign(
        _ appInfo: LCAppInfo
    ) async -> (success: Bool, message: String?) {
        await withCheckedContinuation { continuation in
            appInfo.patchExecAndSignIfNeed(
                completionHandler: { success, message in
                    continuation.resume(returning: (success, message))
                },
                progressHandler: { _ in },
                forceSign: false
            )
        }
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func copyRuntimeConfiguration(
        from previous: LCAppInfo?,
        to installed: LCAppInfo
    ) {
        guard let previous else { return }
        installed.autoSaveDisabled = true
        installed.isJITNeeded = previous.isJITNeeded
        installed.doSymlinkInbox = previous.doSymlinkInbox
        installed.containerInfo = previous.containerInfo
        installed.selectedLanguage = previous.selectedLanguage
        installed.dataUUID = previous.dataUUID
        installed.orientationLock = previous.orientationLock
        installed.dontInjectTweakLoader = previous.dontInjectTweakLoader
        installed.dontLoadTweakLoader = previous.dontLoadTweakLoader
        installed.doUseLCBundleId = previous.doUseLCBundleId
        installed.fixFilePickerNew = previous.fixFilePickerNew
        installed.fixLocalNotification = previous.fixLocalNotification
        installed.autoSaveDisabled = false
    }
}

private enum T3HeadlessAppRuntimeError: LocalizedError {
    case downloadFailed(Int)
    case invalidIPA
    case bundleIdentifierMismatch(expected: String, actual: String)
    case appIsRunning
    case signingFailed(String)

    var errorDescription: String? {
        switch self {
        case let .downloadFailed(statusCode):
            "The iPhone build download failed with HTTP \(statusCode)."
        case .invalidIPA:
            "The latest build is not a valid iPhone IPA."
        case let .bundleIdentifierMismatch(expected, actual):
            "The build uses bundle ID \(actual), but the manifest specifies \(expected)."
        case .appIsRunning:
            "The current iPhone app is still running. Close it, then tap Run again to install the new build safely."
        case let .signingFailed(message):
            message
        }
    }
}
