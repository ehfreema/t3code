import Foundation

struct FeatureWebsiteRunConfiguration: Equatable, Sendable {
    let name: String
    let command: String
    let localPreviewURL: URL
}

enum FeatureWebsiteProjectDetector {
    private struct PackageFile: Decodable {
        let name: String?
        let packageManager: String?
        let scripts: [String: String]?
        let dependencies: [String: String]?
        let devDependencies: [String: String]?
    }

    @MainActor
    static func configuration(
        client: any FeatureClient,
        threadID: String,
        project: FeatureProject?
    ) async -> FeatureWebsiteRunConfiguration? {
        if let configured = project?.scripts?.first(where: {
            !$0.runOnWorktreeCreate
                && !$0.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.previewURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }),
           let previewURL = normalizedPreviewURL(configured.previewURL ?? "") {
            return FeatureWebsiteRunConfiguration(
                name: configured.name,
                command: configured.command,
                localPreviewURL: previewURL
            )
        }

        guard let files = try? await client.searchThreadFiles(
            threadID: threadID,
            query: "package.json",
            limit: 20
        ) else { return nil }

        let packageFiles = files
            .filter {
                $0.kind == .file
                    && ($0.path == "package.json" || $0.path.hasSuffix("/package.json"))
                    && !$0.path.contains("node_modules/")
                    && !$0.path.contains(".t3/")
                    && !$0.path.contains("DerivedData/")
            }
            .sorted {
                let leftDepth = $0.path.filter { $0 == "/" }.count
                let rightDepth = $1.path.filter { $0 == "/" }.count
                return leftDepth == rightDepth
                    ? $0.path.localizedStandardCompare($1.path) == .orderedAscending
                    : leftDepth < rightDepth
            }

        for file in packageFiles {
            guard let content = try? await client.readFile(threadID: threadID, path: file.path),
                  !content.isTruncated,
                  let configuration = configuration(
                      packageJSON: content.text,
                      packagePath: file.path
                  ) else { continue }
            return configuration
        }
        return nil
    }

    static func configuration(
        packageJSON: String,
        packagePath: String
    ) -> FeatureWebsiteRunConfiguration? {
        guard let data = packageJSON.data(using: .utf8),
              let package = try? JSONDecoder().decode(PackageFile.self, from: data),
              let scripts = package.scripts else { return nil }

        let scriptName = ["dev", "start", "preview"].first { name in
            scripts[name]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        guard let scriptName, let script = scripts[scriptName] else { return nil }

        let dependencies = Set((package.dependencies ?? [:]).keys)
            .union((package.devDependencies ?? [:]).keys)
        let framework = framework(for: script, dependencies: dependencies)
        guard framework != .unsupported else { return nil }

        let packageManager = commandName(package.packageManager)
        var command = "\(packageManager) run \(scriptName)"
        switch framework {
        case .next:
            command += " -- --hostname 0.0.0.0"
        case .vite, .astro:
            command += " -- --host 0.0.0.0"
        case .generic:
            command = "HOST=0.0.0.0 \(command)"
        case .unsupported:
            return nil
        }

        let directory = (packagePath as NSString).deletingLastPathComponent
        if !directory.isEmpty {
            command = "cd \(shellQuote(directory)) && \(command)"
        }

        let port = explicitPort(in: script) ?? framework.defaultPort
        guard let previewURL = URL(string: "http://localhost:\(port)") else { return nil }
        return FeatureWebsiteRunConfiguration(
            name: package.name ?? "Website",
            command: command,
            localPreviewURL: previewURL
        )
    }

    private enum Framework: Equatable {
        case next
        case vite
        case astro
        case generic
        case unsupported

        var defaultPort: Int {
            switch self {
            case .next, .generic: 3000
            case .vite: 5173
            case .astro: 4321
            case .unsupported: 0
            }
        }
    }

    private static func framework(
        for script: String,
        dependencies: Set<String>
    ) -> Framework {
        let command = script.lowercased()
        if command.contains("next") || dependencies.contains("next") { return .next }
        if command.contains("vite") || dependencies.contains("vite") { return .vite }
        if command.contains("astro") || dependencies.contains("astro") { return .astro }
        if dependencies.contains("react-scripts") || command.contains("react-scripts") {
            return .generic
        }
        if command.contains("serve") || command.contains("http-server") {
            return .generic
        }
        return .unsupported
    }

    private static func commandName(_ packageManager: String?) -> String {
        guard let packageManager else { return "npm" }
        let name = packageManager.split(separator: "@").first.map(String.init) ?? "npm"
        return ["npm", "pnpm", "yarn", "bun"].contains(name) ? name : "npm"
    }

    private static func explicitPort(in script: String) -> Int? {
        let patterns = [
            #"(?:--port|-p)\s*[= ]\s*(\d{2,5})"#,
            #"\bPORT\s*=\s*(\d{2,5})"#,
        ]
        let range = NSRange(script.startIndex..., in: script)
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(in: script, range: range),
                  let capture = Range(match.range(at: 1), in: script),
                  let port = Int(script[capture]),
                  (1 ... 65_535).contains(port) else { continue }
            return port
        }
        return nil
    }

    private static func normalizedPreviewURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("://") { return URL(string: trimmed) }
        return URL(string: "http://\(trimmed)")
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }
}

enum FeatureWebsitePreviewURL {
    enum Error: LocalizedError {
        case invalidEnvironmentHost
        case invalidPreviewURL

        var errorDescription: String? {
            switch self {
            case .invalidEnvironmentHost:
                "The connected environment has no reachable host."
            case .invalidPreviewURL:
                "The website preview URL is invalid."
            }
        }
    }

    static func reachableURL(_ localURL: URL, environmentBaseURL: URL) throws -> URL {
        guard let localHost = localURL.host?.lowercased(),
              ["localhost", "127.0.0.1", "::1", "0.0.0.0"].contains(localHost) else {
            return localURL
        }
        guard let environmentHost = environmentBaseURL.host, !environmentHost.isEmpty else {
            throw Error.invalidEnvironmentHost
        }
        guard var components = URLComponents(url: localURL, resolvingAgainstBaseURL: false) else {
            throw Error.invalidPreviewURL
        }
        components.host = environmentHost
        guard let url = components.url else { throw Error.invalidPreviewURL }
        return url
    }

    static func supportsDirectPortAccess(_ environmentBaseURL: URL) -> Bool {
        guard let host = environmentBaseURL.host?.lowercased(), !host.isEmpty else {
            return false
        }
        if host == "localhost" || host == "0.0.0.0" || host == "::1" {
            return true
        }
        if host.hasSuffix(".local") || host.hasSuffix(".ts.net") || !host.contains(".") {
            return true
        }
        if host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe80:") {
            return true
        }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0 ... 255).contains($0) }) else {
            return false
        }
        return octets[0] == 10
            || octets[0] == 127
            || (octets[0] == 100 && (64 ... 127).contains(octets[1]))
            || (octets[0] == 169 && octets[1] == 254)
            || (octets[0] == 172 && (16 ... 31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
    }
}
