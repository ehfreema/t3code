import Foundation
import Testing
@testable import T3Code

@Suite("iPhone app runner")
struct IOSAppRunnerTests {
    @Test
    func manifestAcceptsOneRelativeIPA() throws {
        let manifest = try FeatureIOSAppManifest(contents: """
        {
          "schemaVersion": 1,
          "displayName": "Pocket Studio",
          "bundleIdentifier": "codes.t3.pocket-studio",
          "artifactPath": ".t3/builds/Pocket Studio.ipa"
        }
        """)

        #expect(manifest.displayName == "Pocket Studio")
        #expect(manifest.bundleIdentifier == "codes.t3.pocket-studio")
        #expect(manifest.artifactPath == ".t3/builds/Pocket Studio.ipa")
        #expect(manifest.liveContainerBundleName == "codes.t3.pocket-studio.app")
    }

    @Test
    func manifestAcceptsCompatibilityDownloadPath() throws {
        let manifest = try FeatureIOSAppManifest(contents: """
        {
          "schemaVersion": 1,
          "displayName": "Pocket Studio",
          "bundleIdentifier": "codes.t3.pocket-studio",
          "artifactPath": ".t3/builds/Pocket Studio.ipa",
          "downloadPath": ".t3/builds/Pocket Studio.ipa.t3asset.pdf"
        }
        """)

        #expect(manifest.downloadPath == ".t3/builds/Pocket Studio.ipa.t3asset.pdf")
    }

    @Test
    func manifestRejectsUnrelatedDownloadPath() {
        #expect(throws: FeatureIOSAppManifestError.invalidDownloadPath) {
            try FeatureIOSAppManifest(
                schemaVersion: 1,
                displayName: "App",
                bundleIdentifier: "codes.t3.app",
                artifactPath: ".t3/builds/App.ipa",
                downloadPath: ".t3/builds/Other.pdf"
            )
        }
    }

    @Test
    func manifestAcceptsOrderedArtifactChunks() throws {
        let manifest = try FeatureIOSAppManifest(
            schemaVersion: 1,
            displayName: "App",
            bundleIdentifier: "codes.t3.app",
            artifactPath: ".t3/builds/App.ipa",
            artifactChunks: [
                ".t3/builds/App.ipa.b64.0000.txt",
                ".t3/builds/App.ipa.b64.0001.txt",
            ]
        )

        #expect(manifest.artifactChunks?.count == 2)
    }

    @Test
    func manifestRejectsSkippedArtifactChunk() {
        #expect(throws: FeatureIOSAppManifestError.invalidArtifactChunks) {
            try FeatureIOSAppManifest(
                schemaVersion: 1,
                displayName: "App",
                bundleIdentifier: "codes.t3.app",
                artifactPath: ".t3/builds/App.ipa",
                artifactChunks: [".t3/builds/App.ipa.b64.0001.txt"]
            )
        }
    }

    @Test(
        "Manifest rejects unsafe or non-IPA paths",
        arguments: [
            "/tmp/App.ipa",
            "../App.ipa",
            ".t3/../App.ipa",
            #".t3\builds\App.ipa"#,
            ".t3/builds/App.zip",
        ]
    )
    func manifestRejectsInvalidArtifactPath(_ path: String) {
        #expect(throws: FeatureIOSAppManifestError.invalidArtifactPath) {
            try FeatureIOSAppManifest(
                schemaVersion: 1,
                displayName: "App",
                bundleIdentifier: "codes.t3.app",
                artifactPath: path
            )
        }
    }

    @Test
    func runRouteCarriesTheArtifactAndInstalledBundle() throws {
        let artifact = URL(
            string: "https://studio.example/api/assets/token/Pocket%20Studio.ipa"
        )!
        let manifest = try FeatureIOSAppManifest(
            schemaVersion: 1,
            displayName: "Pocket Studio",
            bundleIdentifier: "codes.t3.pocket-studio",
            artifactPath: ".t3/builds/App.ipa"
        )
        let route = try FeatureLiveContainerRoute.run(
            manifest: manifest,
            artifactURL: artifact,
            requestID: "request-1"
        )
        let components = URLComponents(url: route, resolvingAgainstBaseURL: false)

        #expect(components?.scheme == "t3code-livecontainer")
        #expect(components?.host == "run")
        #expect(components?.queryItems == [
            URLQueryItem(name: "url", value: artifact.absoluteString),
            URLQueryItem(name: "bundle-name", value: "codes.t3.pocket-studio.app"),
            URLQueryItem(name: "request-id", value: "request-1"),
        ])
    }

    @Test
    func projectDetectorAcceptsOnlyIOSApplicationProjects() {
        #expect(FeatureIOSProjectDetector.isIOSApplicationProject(contents: """
        productType = "com.apple.product-type.application";
        SDKROOT = iphoneos;
        """))
        #expect(!FeatureIOSProjectDetector.isIOSApplicationProject(contents: """
        productType = "com.apple.product-type.framework";
        SDKROOT = iphoneos;
        """))
        #expect(!FeatureIOSProjectDetector.isIOSApplicationProject(contents: """
        productType = "com.apple.product-type.application";
        SDKROOT = macosx;
        """))
    }

    @Test
    func projectDetectorUsesOnlyXcodeProjectFiles() {
        let candidates = FeatureIOSProjectDetector.candidateProjectPaths(in: [
            FeatureFileEntry(
                path: "Pocket.xcodeproj/project.pbxproj",
                name: "project.pbxproj",
                kind: .file
            ),
            FeatureFileEntry(
                path: "vendor/project.pbxproj",
                name: "project.pbxproj",
                kind: .file
            ),
            FeatureFileEntry(
                path: "Example.xcodeproj/project.pbxproj",
                name: "project.pbxproj",
                kind: .directory
            ),
        ])

        #expect(candidates == ["Pocket.xcodeproj/project.pbxproj"])
    }

    @Test
    func buildPromptDefinesTheArtifactHandshake() {
        #expect(FeatureIOSAppBuildPrompt.text.contains(FeatureIOSAppManifest.relativePath))
        #expect(FeatureIOSAppBuildPrompt.text.contains("Payload/<AppName>.app"))
        #expect(FeatureIOSAppBuildPrompt.text.contains("arm64"))
        #expect(FeatureIOSAppBuildPrompt.text.contains("artifactChunks"))
        #expect(FeatureIOSAppBuildPrompt.text.contains("524288"))
        #expect(FeatureIOSAppBuildPrompt.visibleText.contains("Build and run this iPhone app"))
        #expect(!FeatureIOSAppBuildPrompt.visibleText.contains("Payload/"))
    }

    @Test
    @MainActor
    func compatibilityArtifactUsesAnOlderServerPreviewExtension() {
        #expect(
            FeatureIOSAppWorkspaceCommand.compatibilityPath(for: ".t3/builds/App.ipa")
                == ".t3/builds/App.ipa.t3asset.pdf"
        )
    }

    @Test
    func completedTurnWithoutWorkspaceChangesReusesTheExistingArtifact() {
        let builtAt = Date(timeIntervalSince1970: 100)
        let thread = FeatureThread(
            id: "thread-1",
            projectID: "project-1",
            title: "App",
            state: .completed,
            latestTurnCompletedAt: Date(timeIntervalSince1970: 200),
            latestWorkspaceChangeAt: Date(timeIntervalSince1970: 50),
            workspaceChangeTrackingAvailable: true
        )

        #expect(FeatureIOSAppBuildFreshness.canReuseArtifact(builtAt: builtAt, thread: thread))
    }

    @Test
    func workspaceChangeAfterTheBuildRequiresANewArtifact() {
        let builtAt = Date(timeIntervalSince1970: 100)
        let thread = FeatureThread(
            id: "thread-1",
            projectID: "project-1",
            title: "App",
            state: .completed,
            latestTurnCompletedAt: Date(timeIntervalSince1970: 200),
            latestWorkspaceChangeAt: Date(timeIntervalSince1970: 200),
            workspaceChangeTrackingAvailable: true
        )

        #expect(!FeatureIOSAppBuildFreshness.canReuseArtifact(builtAt: builtAt, thread: thread))
    }

    @Test
    func olderSnapshotsFallBackToTheLatestTurnTime() {
        let builtAt = Date(timeIntervalSince1970: 100)
        let thread = FeatureThread(
            id: "thread-1",
            projectID: "project-1",
            title: "App",
            state: .completed,
            latestTurnCompletedAt: Date(timeIntervalSince1970: 200)
        )

        #expect(!FeatureIOSAppBuildFreshness.canReuseArtifact(builtAt: builtAt, thread: thread))
    }

    @Test
    func activeBuildStatusNeverReusesThePreviousArtifact() {
        let thread = FeatureThread(
            id: "thread-1",
            projectID: "project-1",
            title: "App",
            state: .completed,
            latestWorkspaceChangeAt: Date(timeIntervalSince1970: 50),
            workspaceChangeTrackingAvailable: true
        )

        #expect(
            !FeatureIOSAppBuildFreshness.canReuseArtifact(
                buildPhase: "building",
                builtAt: Date(timeIntervalSince1970: 100),
                thread: thread
            )
        )
    }

    @Test
    func nextWebsiteConfigurationUsesItsPackageDirectoryAndRemoteBinding() {
        let configuration = FeatureWebsiteProjectDetector.configuration(
            packageJSON: """
            {
              "name": "policy-viewer",
              "scripts": { "dev": "next dev" },
              "dependencies": { "next": "14.2.21" }
            }
            """,
            packagePath: "policy-viewer/t3/package.json"
        )

        #expect(configuration?.command == "cd 'policy-viewer/t3' && npm run dev -- --hostname 0.0.0.0")
        #expect(configuration?.localPreviewURL.absoluteString == "http://localhost:3000")
    }

    @Test
    func viteWebsiteConfigurationKeepsAnExplicitPort() {
        let configuration = FeatureWebsiteProjectDetector.configuration(
            packageJSON: """
            {
              "packageManager": "pnpm@9.0.0",
              "scripts": { "dev": "vite --port 4173" },
              "devDependencies": { "vite": "6.0.0" }
            }
            """,
            packagePath: "package.json"
        )

        #expect(configuration?.command == "pnpm run dev -- --host 0.0.0.0")
        #expect(configuration?.localPreviewURL.absoluteString == "http://localhost:4173")
    }

    @Test
    func websitePreviewUsesTheConnectedEnvironmentHost() throws {
        let url = try FeatureWebsitePreviewURL.reachableURL(
            URL(string: "http://localhost:3000/dashboard")!,
            environmentBaseURL: URL(string: "https://macbook-pro.example.ts.net:5733")!
        )

        #expect(url.absoluteString == "http://macbook-pro.example.ts.net:3000/dashboard")
    }

    @Test
    func websitePreviewRewritesAnAllInterfacesHost() throws {
        let url = try FeatureWebsitePreviewURL.reachableURL(
            URL(string: "http://0.0.0.0:5173")!,
            environmentBaseURL: URL(string: "https://macbook-pro.example.ts.net:5733")!
        )

        #expect(url.absoluteString == "http://macbook-pro.example.ts.net:5173")
    }

    @Test
    func websitePreviewRequiresADirectEnvironmentHost() {
        #expect(
            FeatureWebsitePreviewURL.supportsDirectPortAccess(
                URL(string: "https://macbook-pro.example.ts.net:5733")!
            )
        )
        #expect(
            !FeatureWebsitePreviewURL.supportsDirectPortAccess(
                URL(string: "https://relay.t3.codes")!
            )
        )
    }
}
