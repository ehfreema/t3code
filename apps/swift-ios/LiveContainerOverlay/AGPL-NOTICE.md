# License notice for T3 Code Live

The generated T3 Code Live app combines T3 Code with LiveContainer. LiveContainer
uses the GNU Affero General Public License version 3.

The generated IPA is a combined work for distribution. Distribute that IPA and
`T3Code-Live-source.zip` under the GNU AGPL version 3.

Source locations:

- T3 Code: <https://github.com/pingdotgg/t3code>
- LiveContainer: <https://github.com/LiveContainer/LiveContainer>
  (pinned at `7e356bc3ab0e05584977281937da9308740b997b` in
  `build-live-ipa.sh`)

## Scope in this repository

The Objective-C sources in this directory (`AppSceneViewController.m`,
`LCAppInfo.m`, `LCBootstrap.m`, `LCMachOUtils.*`, `LCSharedUtils.*`,
`LCUtils.m`, `LiveProcessMain.m`, `UIKitHooks.m`, `zsign.mm`, `zsigner.h`)
are derived from LiveContainer at the pinned commit and are governed by the
GNU AGPL version 3, not by the MIT license at the repository root. Copyright
belongs to the LiveContainer contributors.

The standard T3 Code SwiftUI target contains no LiveContainer source or assets.
It keeps the MIT license of the repository root and its App Store distribution
path.

The build script adds the source archive name and SHA-256 value to
`T3-LIVE-SOURCE.txt` in the generated app bundle, and ships
`LICENSE-LIVECONTAINER-AGPL.txt` beside `LICENSE-T3CODE.txt`.
