import Foundation

@MainActor
enum FeatureIOSAppWorkspaceCommand {
    static let instructionPath = ".t3/ios-app-build.md"

    static func writeBuildInstructions(
        client: any FeatureClient,
        threadID: String
    ) async throws {
        let encoded = Data(FeatureIOSAppBuildPrompt.text.utf8).base64EncodedString()
        let script = """
        import base64,pathlib
        p=pathlib.Path("\(instructionPath)")
        p.parent.mkdir(parents=True,exist_ok=True)
        p.write_bytes(base64.b64decode("\(encoded)"))
        """
        try await run(
            client: client,
            threadID: threadID,
            command: "python3 -c \(shellQuote(script))"
        )
    }

    static func createCompatibilityAsset(
        client: any FeatureClient,
        threadID: String,
        artifactPath: String
    ) async throws -> String {
        let compatibilityPath = compatibilityPath(for: artifactPath)
        try await run(
            client: client,
            threadID: threadID,
            command: "cp -- \(shellQuote(artifactPath)) \(shellQuote(compatibilityPath))"
        )
        return compatibilityPath
    }

    static func createArtifactChunks(
        client: any FeatureClient,
        threadID: String,
        artifactPath: String
    ) async throws {
        let script = """
        import base64,json,pathlib,sys
        artifact=pathlib.Path(sys.argv[1])
        for stale in artifact.parent.glob(artifact.name+".b64.*.txt"):
            stale.unlink()
        chunks=[]
        with artifact.open("rb") as source:
            index=0
            while data := source.read(524288):
                path=pathlib.Path(f"{artifact}.b64.{index:04d}.txt")
                path.write_text(base64.b64encode(data).decode("ascii"))
                chunks.append(str(path))
                index+=1
        manifest_path=pathlib.Path("\(FeatureIOSAppManifest.relativePath)")
        manifest=json.loads(manifest_path.read_text())
        manifest["artifactChunks"]=chunks
        manifest_path.write_text(json.dumps(manifest,indent=2)+"\\n")
        """
        try await run(
            client: client,
            threadID: threadID,
            command: "python3 -c \(shellQuote(script)) \(shellQuote(artifactPath))"
        )
    }

    nonisolated static func compatibilityPath(for artifactPath: String) -> String {
        // Older servers only expose browser-preview file types through signed
        // workspace URLs. The runtime consumes the response bytes, not its
        // filename or content type.
        artifactPath + ".t3asset.pdf"
    }

    private static func run(
        client: any FeatureClient,
        threadID: String,
        command: String
    ) async throws {
        let terminalID = "t3-ios-run-\(UUID().uuidString)"
        let updates = client.terminalEvents(threadID: threadID, terminalID: terminalID)
        var iterator = updates.makeAsyncIterator()

        do {
            try await client.openTerminal(
                threadID: threadID,
                terminalID: terminalID,
                columns: 80,
                rows: 24
            )
            try await client.writeTerminal(
                threadID: threadID,
                terminalID: terminalID,
                data: "\(command); t3_status=$?; exit $t3_status\n"
            )

            while let update = await iterator.next() {
                if update.state == .exited, update.exitCode == 0 {
                    try? await client.closeTerminal(threadID: threadID, terminalID: terminalID)
                    return
                }
                if update.state == .failed || update.state == .exited {
                    throw FeatureIOSAppWorkspaceCommandError.commandFailed
                }
            }
            throw FeatureIOSAppWorkspaceCommandError.commandFailed
        } catch {
            try? await client.closeTerminal(threadID: threadID, terminalID: terminalID)
            throw error
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

private enum FeatureIOSAppWorkspaceCommandError: LocalizedError {
    case commandFailed

    var errorDescription: String? {
        "T3 Code could not prepare the iPhone build workspace."
    }
}
