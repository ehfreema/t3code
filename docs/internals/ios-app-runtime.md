# iOS App Runtime

The SwiftUI mobile client can turn a thread workspace into a runnable iPhone
artifact. The coding agent performs the build on the T3 environment. The iPhone
downloads and runs the result.

## Artifact Handshake

The agent writes `.t3/ios-app.json` in the active workspace or thread worktree.
The schema has four fields:

```json
{
  "schemaVersion": 1,
  "displayName": "Example",
  "bundleIdentifier": "com.example.app",
  "artifactPath": ".t3/builds/Example.ipa"
}
```

`artifactPath` must be relative. It must identify an `.ipa` file in the same
workspace. The archive must contain an arm64 iPhone app below `Payload/`.

## Data Flow

1. `ThreadDetailView` detects an iOS application project from its Xcode project.
2. The toolbar action reads the manifest through the workspace file API.
3. `NativeFeatureClient` maps the UI thread ID to the wire thread ID.
4. The client requests an `ios-app-artifact` URL from `assets.createUrl`.
5. `AssetAccess` resolves the thread worktree or the project workspace.
6. The server signs an exact-file capability with a one-hour lifetime.
7. The embedded runtime downloads, replaces, prepares, and launches the IPA.

The asset route does not permit sibling files. It rejects non-IPA paths before
it creates a token. Canonical-path checks keep symlinks and path traversal
outside the workspace.

## Runtime Boundary

The standard SwiftUI client does not expose the run action. The action appears
only in T3 Code Live and only for detected iOS application projects.

The host Info.plist sets `T3EmbeddedLiveContainerRuntime`. One internal request
downloads, installs, and launches the selected build. The runtime management UI
is not part of the T3 Code Live view hierarchy.

The guest uses a native app scene. The host closes that scene after the guest
exits, which returns the user to the same T3 Code thread.

The generated host uses bundle identifier `codes.t3.t3code-live`. The build
patches LiveContainer's host identity and private storage paths so an installed
standard LiveContainer remains a separate app.

The generated host loads `T3CodeKit.framework` at startup. This keeps the normal
App Store target separate from the sideload runtime. The host also embeds the
static Ghostty runtime in `T3CodeKit.framework`.

## Build and License Boundary

`apps/swift-ios/LiveContainerOverlay/build-live-ipa.sh` gets a pinned
LiveContainer revision. It builds the T3 Code framework and an unsigned device
IPA. A compatible sideload tool signs the complete app.

The script also makes `T3Code-Live-source.zip`. This archive contains the T3 Code
build source and the patched LiveContainer source. Distribute both files.

The normal SwiftUI target does not link LiveContainer. The generated combined
app uses the GNU AGPL version 3 license because LiveContainer uses that license.

## Surface Decisions

- SwiftUI mobile: manifest, build request, artifact installation, and runtime.
- React Native mobile: not implemented.
- Web and desktop: the agent can create artifacts, but these clients do not run them.
- Server connection modes: local, remote, relay, and tunnel use the same signed asset route.
- Providers: all providers use the same build prompt and workspace contract.
