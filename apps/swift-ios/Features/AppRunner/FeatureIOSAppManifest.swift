import Foundation

public struct FeatureIOSAppManifest: Equatable, Sendable {
    public static let relativePath = ".t3/ios-app.json"

    public let schemaVersion: Int
    public let displayName: String
    public let bundleIdentifier: String
    public let artifactPath: String
    public let downloadPath: String?
    public let artifactChunks: [String]?

    public init(contents: String) throws {
        guard let data = contents.data(using: .utf8) else {
            throw FeatureIOSAppManifestError.invalidJSON
        }
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw FeatureIOSAppManifestError.invalidJSON
        }
        try self.init(
            schemaVersion: payload.schemaVersion,
            displayName: payload.displayName,
            bundleIdentifier: payload.bundleIdentifier,
            artifactPath: payload.artifactPath,
            downloadPath: payload.downloadPath,
            artifactChunks: payload.artifactChunks
        )
    }

    public init(
        schemaVersion: Int,
        displayName: String,
        bundleIdentifier: String,
        artifactPath: String,
        downloadPath: String? = nil,
        artifactChunks: [String]? = nil
    ) throws {
        guard schemaVersion == 1 else {
            throw FeatureIOSAppManifestError.unsupportedSchemaVersion(schemaVersion)
        }

        let displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty, displayName.count <= 120 else {
            throw FeatureIOSAppManifestError.invalidDisplayName
        }

        let bundleIdentifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidBundleIdentifier(bundleIdentifier) else {
            throw FeatureIOSAppManifestError.invalidBundleIdentifier
        }

        let artifactPath = artifactPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidArtifactPath(artifactPath) else {
            throw FeatureIOSAppManifestError.invalidArtifactPath
        }

        let downloadPath = downloadPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let downloadPath,
           downloadPath != FeatureIOSAppWorkspaceCommand.compatibilityPath(for: artifactPath) {
            throw FeatureIOSAppManifestError.invalidDownloadPath
        }

        if let artifactChunks {
            guard !artifactChunks.isEmpty, artifactChunks.count <= 512 else {
                throw FeatureIOSAppManifestError.invalidArtifactChunks
            }
            for (index, path) in artifactChunks.enumerated() {
                let expected = "\(artifactPath).b64.\(String(format: "%04d", index)).txt"
                guard path == expected else {
                    throw FeatureIOSAppManifestError.invalidArtifactChunks
                }
            }
        }

        self.schemaVersion = schemaVersion
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.artifactPath = artifactPath
        self.downloadPath = downloadPath
        self.artifactChunks = artifactChunks
    }

    var liveContainerBundleName: String {
        "\(bundleIdentifier).app"
    }

    private static func isValidBundleIdentifier(_ value: String) -> Bool {
        guard value.count <= 255 else { return false }
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        return components.allSatisfy { component in
            !component.isEmpty && component.unicodeScalars.allSatisfy(allowed.contains)
        }
    }

    private static func isValidArtifactPath(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.count <= 1_024,
              !value.hasPrefix("/"),
              !value.contains("\\"),
              !value.contains("\0"),
              value.lowercased().hasSuffix(".ipa") else {
            return false
        }
        return value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    private struct Payload: Decodable {
        let schemaVersion: Int
        let displayName: String
        let bundleIdentifier: String
        let artifactPath: String
        let downloadPath: String?
        let artifactChunks: [String]?
    }
}

public enum FeatureIOSAppManifestError: LocalizedError, Equatable, Sendable {
    case invalidJSON
    case unsupportedSchemaVersion(Int)
    case invalidDisplayName
    case invalidBundleIdentifier
    case invalidArtifactPath
    case invalidDownloadPath
    case invalidArtifactChunks

    public var errorDescription: String? {
        switch self {
        case .invalidJSON:
            "\(FeatureIOSAppManifest.relativePath) is not valid JSON."
        case let .unsupportedSchemaVersion(version):
            "iOS app manifest version \(version) is not supported."
        case .invalidDisplayName:
            "The iOS app manifest needs a valid displayName."
        case .invalidBundleIdentifier:
            "The iOS app manifest needs a valid bundleIdentifier."
        case .invalidArtifactPath:
            "The iOS app manifest artifactPath must be a relative IPA path."
        case .invalidDownloadPath:
            "The iOS app manifest downloadPath must identify its compatibility asset."
        case .invalidArtifactChunks:
            "The iOS app manifest artifactChunks are invalid or incomplete."
        }
    }
}

enum FeatureIOSAppBuildPrompt {
    static let visibleText = "Build and run this iPhone app. Follow the instructions in `\(FeatureIOSAppWorkspaceCommand.instructionPath)`."

    static let text = """
    Build the current project as a real arm64 iPhone app for T3 Code's on-device app runtime. Use the installed Xcode toolchain and do not target the Simulator. If signing is unavailable, build with code signing disabled; the on-device runtime prepares the app for launch.

    Package the resulting .app as an IPA with this layout: Payload/<AppName>.app. Put the IPA below .t3/builds/ in this thread's workspace. Verify that the archive contains Payload/<AppName>.app/Info.plist and an arm64 executable.

    Encode the IPA into independently decodable 256 KiB binary chunks. For chunk index 0, write base64(IPA bytes 0..<262144) to `<artifactPath>.b64.0000.txt`; continue with zero-padded sequential indexes until every IPA byte is encoded. Remove stale chunk files first. Each text file must contain only the base64 for that binary chunk.

    After verification, write .t3/ios-app.json with exactly these fields:
    {
      "schemaVersion": 1,
      "displayName": "<app display name>",
      "bundleIdentifier": "<app bundle identifier>",
      "artifactPath": ".t3/builds/<artifact name>.ipa",
      "artifactChunks": [
        ".t3/builds/<artifact name>.ipa.b64.0000.txt",
        ".t3/builds/<artifact name>.ipa.b64.0001.txt"
      ]
    }

    The array must list every generated chunk in order and can contain more or fewer entries than this example. Do not report success unless the IPA, all chunks, and manifest exist and match.
    """
}
