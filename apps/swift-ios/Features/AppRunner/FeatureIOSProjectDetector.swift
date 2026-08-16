import Foundation

enum FeatureIOSProjectDetector {
    /// True only when a valid `.t3/ios-app.json` build manifest exists. This is the
    /// deterministic capability check for the Run action: Run executes the existing
    /// artifact and never triggers a build or contacts the agent.
    @MainActor
    static func hasIOSAppBuild(
        client: any FeatureClient,
        threadID: String
    ) async -> Bool {
        guard let content = try? await client.readFile(
            threadID: threadID,
            path: FeatureIOSAppManifest.relativePath
        ), !content.isTruncated,
           (try? FeatureIOSAppManifest(contents: content.text)) != nil else {
            return false
        }
        return true
    }

    @MainActor
    static func isIOSAppProject(
        client: any FeatureClient,
        threadID: String
    ) async -> Bool {
        if let content = try? await client.readFile(
            threadID: threadID,
            path: FeatureIOSAppManifest.relativePath
        ), !content.isTruncated,
           (try? FeatureIOSAppManifest(contents: content.text)) != nil {
            return true
        }

        guard let entries = try? await client.searchThreadFiles(
            threadID: threadID,
            query: "project.pbxproj",
            limit: 12
        ) else {
            return false
        }

        for path in candidateProjectPaths(in: entries) {
            guard let content = try? await client.readFile(threadID: threadID, path: path),
                  !content.isTruncated else { continue }
            if isIOSApplicationProject(contents: content.text) {
                return true
            }
        }
        return false
    }

    static func candidateProjectPaths(in entries: [FeatureFileEntry]) -> [String] {
        entries.compactMap { entry in
            guard entry.kind == .file,
                  entry.path.lowercased().hasSuffix(".xcodeproj/project.pbxproj") else {
                return nil
            }
            return entry.path
        }
    }

    static func isIOSApplicationProject(contents: String) -> Bool {
        guard contents.contains("com.apple.product-type.application") else { return false }
        return contents.contains("SDKROOT = iphoneos")
            || contents.contains("IPHONEOS_DEPLOYMENT_TARGET")
            || contents.contains("TARGETED_DEVICE_FAMILY")
    }
}
