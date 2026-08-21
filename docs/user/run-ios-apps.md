# Build and Run an iPhone App From T3 Code

T3 Code Live can build an iPhone app on the connected Mac. It then installs and
runs the build on the same iPhone.

This feature applies to the SwiftUI mobile client. The React Native mobile
client does not include this feature.

## Requirements

- Connect T3 Code to a Mac that has Xcode and the iPhoneOS platform.
- Install the sideload-only T3 Code Live app on an iPhone with iOS 17 or later.
- Use a project that contains an iOS app.

The App Store SwiftUI client does not show this action. Other project types do
not show it either.

## Build the App

1. Open a thread for the iOS app project.
2. Open the thread menu.
3. Select **Run** or **Run iOS App**.

If no build exists, T3 Code makes an arm64 device IPA. T3 Code also makes a new
IPA after a workspace file changes.

If no workspace file changed, T3 Code uses the existing IPA.

T3 Code stores the IPA in `.t3/builds/`. It writes the app information to
`.t3/ios-app.json`.

The progress panel shows each build phase. Select **Hide** to close the panel.
The build continues, and its status remains next to the thread menu.

## Return to T3 Code

The built app opens as an iPhone app scene. Close that scene to return to the
same T3 Code thread.

## Connection Notes

T3 Code makes a signed URL for one IPA file. The URL expires after one hour.
Select **Run** again to make a new URL.

T3 Connect is available by default. Direct pairing links can include alternate
local-network and tailnet endpoints when the first endpoint is not reachable.

## Distribution Limits

T3 Code Live is a sideload-only app. Apple does not permit this runtime in App
Store or TestFlight builds.

LiveContainer uses the GNU AGPL version 3 license. A distributed T3 Code Live
build must include the generated corresponding-source archive.
