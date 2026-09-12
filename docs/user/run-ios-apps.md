# Build and Run an iPhone App From T3 Code

T3 Code Live can build an iPhone app on a connected Mac. It then installs and runs the app on your iPhone.

This feature is available only in the sideloaded SwiftUI mobile client named T3 Code Live.

The App Store and TestFlight clients do not include this runtime. The React Native mobile client does not include this feature.

## Requirements

- Connect T3 Code to a Mac that has the required build tools.
- Install T3 Code Live on an iPhone with iOS 17 or later.
- Provide a signing certificate for the apps T3 Code installs. Import a .p12 certificate in T3 Code Live, or install SideStore or AltStore and use its certificate export.
- Use an iOS app that produces an arm64 device build.

CAUTION: Run iPhone builds only in trusted workspaces. Xcode build phases, package plugins, submodules, and custom recipes can run code on the Mac.

Install T3 Code Live and your store app only from sources that you trust. Certificate export uses the store callback on your iPhone. A .p12 imported in T3 Code Live signs every app that T3 Code installs; use a certificate that you trust.

## Supported Build Systems

T3 Code detects a single Xcode project or workspace automatically. It selects an iOS app scheme and makes an unsigned Release archive.

Use a build recipe for these conditions:

- The project uses a different build system.
- The project generates its Xcode files.
- The workspace contains more than one Xcode build container.
- The automatic scheme does not identify the required app.

Add `.t3/ios-build.json` to the workspace:

```json
{
  "schemaVersion": 1,
  "command": "./scripts/build-ios-device.sh",
  "workingDirectory": ".",
  "appPath": ".t3/build-products/MyApp.app"
}
```

The `command` value must fit on one line. Use a script for a command that needs multiple steps.

The `workingDirectory` and `appPath` values are relative to the workspace root. They must not resolve outside the workspace.

The command must make the app at `appPath`. The app must be a complete iPhone device app with an arm64 executable.

The recipe can use Xcode, Tuist, XcodeGen, Bazel, Buck2, CMake, Godot, Unity, or another native build system.

## Build the App

1. Open a thread for the iOS app project.
2. Open the thread menu.
3. Select **Run iOS App**.

T3 Code runs the build on the environment for that thread. The selected coding provider does not affect the build.

The progress panel shows the current phase. Select **Hide** to close the panel without stopping the build.

The server stops a build that runs for more than 30 minutes. Select **Run iOS App** again to retry a stopped build.

T3 Code stores build data below `.t3/builds/`. These files include the app artifact, status, and build logs.

T3 Code uses an existing artifact only when the server reports complete workspace-change tracking. Otherwise, T3 Code makes a new build.

Legacy version 1 manifests without a status file remain runnable. T3 Code cannot determine if these legacy artifacts contain the latest source.

## Artifact Safety

T3 Code accepts only an iPhone app bundle with these properties:

- The bundle stays inside the workspace.
- The bundle contains one app and one valid `Info.plist`.
- The app identifies the iPhoneOS platform.
- The app executable contains arm64.
- App-bundle symbolic links stay inside the app bundle.

T3 Code calculates a SHA-256 digest for each new IPA. T3 Code Live compares this digest before it extracts or runs the app.

T3 Code keeps the previous installed app if preparation or signing of a replacement fails.

## Return to T3 Code

The built app opens in an iPhone app scene. Close that scene to return to the same T3 Code thread.

Close the running guest app before you install a different build of the same bundle identifier.

## Connection Notes

Local, direct remote, relay, and tunnel connections use the same build request and artifact rules.

T3 Code makes a signed URL for one IPA file. The URL expires after one hour.

If an old server cannot make an IPA URL, the client can reconstruct a compatible artifact from workspace chunks.

The compatibility path supports IPA files up to 384 MiB. Current servers use the signed URL for larger artifacts.

## Troubleshooting

If discovery selects the wrong app, add `.t3/ios-build.json` with an explicit build script and output path.

If the build fails, read these workspace logs:

- `.t3/builds/runner.log`
- `.t3/builds/build.log` for a recipe
- `.t3/builds/xcodebuild.log` for an automatic Xcode build
- `.t3/builds/packages.log` for Swift package resolution

If certificate import fails, import a .p12 certificate in T3 Code Live again, or sign in to SideStore or AltStore. Then select **Run iOS App** again.

## Distribution Limits

T3 Code Live is a sideload-only app. Apple does not permit this runtime in App Store or TestFlight builds.

LiveContainer uses the GNU AGPL version 3 license. A T3 Code Live distribution must include its generated source archive.
