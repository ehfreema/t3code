# T3 Code Live

T3 Code Live is a sideload-only build of the native SwiftUI client. It uses
LiveContainer to run an iPhone app over the T3 Code interface.

The generated host uses bundle identifier `codes.t3.t3code-live`. It does not
replace or share the installed `com.kdt.livecontainer` host identity.
It uses the same app icon as T3 Swift.

T3 Code Live requires iOS 17 or later.

The app under test runs in a native app scene. Close that scene to return to the
same T3 Code thread. T3 Code Live does not expose the LiveContainer interface.

## Distribution limits

T3 Code Live cannot use App Store or TestFlight distribution. It loads code that
is not part of the installed host app.

The generated app combines T3 Code with LiveContainer. LiveContainer uses the
GNU AGPL version 3 license. Distribute the IPA and its source archive together.

The standard T3 Code SwiftUI target does not link LiveContainer. It keeps its
current license and App Store distribution path.

## Build

Install Xcode and its iPhoneOS platform. Then run:

```sh
./LiveContainerOverlay/build-live-ipa.sh
```

The script does these actions:

1. It gets the pinned LiveContainer source and its submodules.
2. It builds `T3CodeKit.framework` for an iPhone device.
3. It replaces the LiveContainer root view with the T3 Code root view.
4. It adds the T3 Code framework to the host app.
5. It makes an unsigned `.livecontainer/T3Code-Live.ipa` file.
6. It makes `.livecontainer/T3Code-Live-source.zip` from the build source.

Install the IPA with SideStore, AltStore, or another compatible signer.

Distribute `T3Code-Live-source.zip` with the IPA. The app bundle contains the
source archive name and its SHA-256 value.

The generated host uses the production T3 Connect public configuration by
default. Set these variables to use another Clerk or relay deployment:

```sh
T3CODE_CLERK_PUBLISHABLE_KEY="..." \
T3CODE_RELAY_URL="https://..." \
./LiveContainerOverlay/build-live-ipa.sh
```

`T3CODE_CLERK_JWT_TEMPLATE` is optional. Its default value is `t3-relay`.

## App artifact contract

The agent puts a physical-device IPA in `.t3/builds/`. The agent also writes
`.t3/ios-app.json` in the project or thread worktree:

```json
{
  "schemaVersion": 1,
  "displayName": "Example",
  "bundleIdentifier": "com.example.app",
  "artifactPath": ".t3/builds/Example.ipa"
}
```

Open a thread for an iOS application project. Select the **Run** toolbar button.
T3 Code builds the app when necessary, then installs and launches it.

## Upstream pin

The build script pins LiveContainer commit
`7e356bc3ab0e05584977281937da9308740b997b`. Update the overlay and repeat the
physical-device acceptance test before you change this pin.
