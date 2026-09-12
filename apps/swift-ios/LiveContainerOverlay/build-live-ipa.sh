#!/bin/sh
set -eu

LIVECONTAINER_REPOSITORY="https://github.com/LiveContainer/LiveContainer.git"
# Upstream pin. Override with LIVECONTAINER_REVISION=latest to build against
# upstream main's HEAD, or use bump-livecontainer.sh to advance the pin safely.
LIVECONTAINER_REVISION=${LIVECONTAINER_REVISION:-"7e356bc3ab0e05584977281937da9308740b997b"}
T3_LIVE_BUNDLE_IDENTIFIER=${T3_LIVE_BUNDLE_IDENTIFIER:-"codes.t3.t3code-live"}
T3_LIVE_URL_SCHEME="t3code-livecontainer"
T3_LIVE_DISPLAY_NAME=${T3_LIVE_DISPLAY_NAME:-"T3 Code Live"}
T3_LIVE_MARKETING_VERSION=${T3_LIVE_MARKETING_VERSION:-"0.1.0"}
T3_LIVE_BUILD_NUMBER=${T3_LIVE_BUILD_NUMBER:-"$(date -u +%s)"}

SCRIPT_DIRECTORY=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SWIFT_IOS_DIRECTORY=$(CDPATH= cd -- "$SCRIPT_DIRECTORY/.." && pwd)
REPOSITORY_ROOT=$(CDPATH= cd -- "$SWIFT_IOS_DIRECTORY/../.." && pwd)
T3_SWIFT_APP_ICON_PATH="$SWIFT_IOS_DIRECTORY/Resources/lct3.icon"
T3_SWIFT_APP_ICON_NAME="lct3"
BUILD_DIRECTORY=${T3_LIVE_BUILD_DIRECTORY:-"$SWIFT_IOS_DIRECTORY/.livecontainer"}
LIVECONTAINER_DIRECTORY="$BUILD_DIRECTORY/LiveContainer"
KIT_DERIVED_DATA="$BUILD_DIRECTORY/T3CodeKitDerivedData"
LIVE_DERIVED_DATA="$BUILD_DIRECTORY/LiveContainerDerivedData"
STAGING_DIRECTORY="$BUILD_DIRECTORY/staging"
OUTPUT_PATH=${T3_LIVE_OUTPUT_PATH:-"$BUILD_DIRECTORY/T3Code-Live.ipa"}
SOURCE_OUTPUT_PATH=${T3_LIVE_SOURCE_OUTPUT_PATH:-"${OUTPUT_PATH%.ipa}-source.zip"}
SOURCE_STAGING_DIRECTORY="$BUILD_DIRECTORY/corresponding-source"

for tool in date git xcodebuild python3 ditto plutil; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        printf 'Required tool is not available: %s\n' "$tool" >&2
        exit 1
    fi
done

remove_directory() {
    path=$1
    attempts=0
    while [ -e "$path" ]; do
        rm -rf "$path" 2>/dev/null || true
        attempts=$((attempts + 1))
        if [ "$attempts" -ge 5 ]; then
            printf 'Could not remove build directory: %s\n' "$path" >&2
            return 1
        fi
    done
}

mkdir -p "$BUILD_DIRECTORY"

if [ ! -d "$LIVECONTAINER_DIRECTORY/.git" ]; then
    git clone --filter=blob:none --no-checkout \
        "$LIVECONTAINER_REPOSITORY" \
        "$LIVECONTAINER_DIRECTORY"
fi

if [ "$LIVECONTAINER_REVISION" = "latest" ]; then
    git -C "$LIVECONTAINER_DIRECTORY" fetch --depth=1 origin main
    LIVECONTAINER_REVISION=$(git -C "$LIVECONTAINER_DIRECTORY" rev-parse FETCH_HEAD)
    printf 'Tracking upstream main: %s\n' "$LIVECONTAINER_REVISION"
fi

git -C "$LIVECONTAINER_DIRECTORY" fetch --depth=1 origin "$LIVECONTAINER_REVISION"
git -C "$LIVECONTAINER_DIRECTORY" checkout --detach "$LIVECONTAINER_REVISION"
git -C "$LIVECONTAINER_DIRECTORY" reset --hard "$LIVECONTAINER_REVISION"
git -C "$LIVECONTAINER_DIRECTORY" submodule sync --recursive
git -C "$LIVECONTAINER_DIRECTORY" submodule update --init --recursive --depth=1

python3 - "$LIVECONTAINER_DIRECTORY" "$T3_LIVE_BUNDLE_IDENTIFIER" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
replacement = sys.argv[2].encode()
needle = b"com.kdt.livecontainer"
replacements = 0

for path in root.rglob("*"):
    if ".git" in path.parts or path.is_symlink() or not path.is_file():
        continue
    data = path.read_bytes()
    if needle not in data:
        continue
    path.write_bytes(data.replace(needle, replacement))
    replacements += 1

if replacements == 0:
    raise SystemExit("LiveContainer bundle identifier was not found.")

shared_model = root / "LiveContainerSwiftUI/Utilities/Shared.swift"
shared_source = shared_model.read_text()
old_status_check = 'if LCUtils.appUrlScheme()?.lowercased() != "livecontainer" {'
new_status_check = (
    'if let scheme = LCUtils.appUrlScheme()?.lowercased(), '
    'scheme != "livecontainer" && scheme != "t3code-livecontainer" {'
)
if shared_source.count(old_status_check) != 1:
    raise SystemExit("LiveContainer multi-instance status check changed.")
shared_model.write_text(shared_source.replace(old_status_check, new_status_check))

utils_extensions = root / "LiveContainerSwiftUI/Utilities/LCUtilsExtensions.swift"
utils_extensions_source = utils_extensions.read_text()
old_app_group_defaults = "public static let appGroupUserDefault = UserDefaults.init(suiteName: LCSharedUtils.appGroupID()) ?? UserDefaults.standard"
new_app_group_defaults = "public static let appGroupUserDefault = UserDefaults.standard"
if utils_extensions_source.count(old_app_group_defaults) != 1:
    raise SystemExit("LiveContainer app-group defaults declaration changed.")
utils_extensions.write_text(utils_extensions_source.replace(old_app_group_defaults, new_app_group_defaults))

app_entry = root / "LiveContainerSwiftUI/App/LiveContainerSwiftUIApp.swift"
app_entry_source = app_entry.read_text()
old_init = "    init() {\n"
new_init = "    init() {\n        LCSharedUtils.migrateLegacyT3Data()\n"
if app_entry_source.count(old_init) != 1:
    raise SystemExit("LiveContainer SwiftUI app initializer changed.")
app_entry.write_text(app_entry_source.replace(old_init, new_init))

shared_utils = root / "LiveContainer/LCSharedUtils.m"
shared_utils_source = shared_utils.read_text()
old_schemes = '@[@"livecontainer", @"livecontainer2", @"livecontainer3"]'
new_schemes = '@[@"t3code-livecontainer", @"livecontainer", @"livecontainer2", @"livecontainer3"]'
if shared_utils_source.count(old_schemes) != 1:
    raise SystemExit("LiveContainer URL scheme list changed.")
shared_utils.write_text(shared_utils_source.replace(old_schemes, new_schemes))

settings_view = root / "LiveContainerSwiftUI/Views/Settings/LCSettingsView.swift"
settings_source = settings_view.read_text()
old_cert_url = "livecontainer%3A%2F%2Fcertificate"
new_cert_url = "t3code-livecontainer%3A%2F%2Fcertificate"
if settings_source.count(old_cert_url) != 1:
    raise SystemExit("LiveContainer certificate callback URL changed.")
settings_view.write_text(settings_source.replace(old_cert_url, new_cert_url))

# Patch internal livecontainer:// URLs that the host generates for self-launch so they use T3's scheme.
# The app's CFBundleURLSchemes is now only t3code-livecontainer, so livecontainer:// URLs would not be handled.
for sub_path in [
    "LiveContainerSwiftUI/Models/LCAppInfo.m",
    "ShareExtension/ShareExtensionViewModel.swift",
    "LiveContainerSwiftUI/Views/AppList/LCAppBanner/LCAppBannerViewController.swift",
]:
    target = root / sub_path
    if target.exists():
        text = target.read_text()
        orig = text
        text = text.replace("livecontainer://livecontainer-launch", "t3code-livecontainer://livecontainer-launch")
        text = text.replace("livecontainer://install", "t3code-livecontainer://install")
        if text != orig:
            target.write_text(text)

multitask_window = root / "MultitaskSupport/MultitaskAppWindow.swift"
multitask_source = multitask_window.read_text()
old_terminated_branch = (
    "        let isVirtualWindowMode = multitaskMode == .virtualWindow\n"
    "        if show, let appInfo {"
)
new_terminated_branch = "        if show, let appInfo {"
old_auto_close = (
    "        } else if skipTerminatedScreen && isVirtualWindowMode, appInfo != nil {"
)
new_auto_close = "        } else if skipTerminatedScreen, appInfo != nil {"
if multitask_source.count(old_terminated_branch) != 1 or multitask_source.count(old_auto_close) != 1:
    raise SystemExit("LiveContainer terminated-app screen changed.")
multitask_window.write_text(
    multitask_source
        .replace(old_terminated_branch, new_terminated_branch)
        .replace(old_auto_close, new_auto_close)
)
PY

cp \
    "$SCRIPT_DIRECTORY/T3LiveContainerOverlayView.swift" \
    "$LIVECONTAINER_DIRECTORY/LiveContainerSwiftUI/T3LiveContainerOverlayView.swift"
cp \
    "$SCRIPT_DIRECTORY/T3LiveContainerAppDelegateBridge.swift" \
    "$LIVECONTAINER_DIRECTORY/LiveContainerSwiftUI/T3LiveContainerAppDelegateBridge.swift"
cp \
    "$SCRIPT_DIRECTORY/T3HeadlessAppRuntime.swift" \
    "$LIVECONTAINER_DIRECTORY/LiveContainerSwiftUI/T3HeadlessAppRuntime.swift"
cp \
    "$SCRIPT_DIRECTORY/LCUtils.m" \
    "$LIVECONTAINER_DIRECTORY/LiveContainerSwiftUI/Utilities/LCUtils.m"
cp \
    "$SCRIPT_DIRECTORY/LCSharedUtils.m" \
    "$LIVECONTAINER_DIRECTORY/LiveContainer/LCSharedUtils.m"
cp \
    "$SCRIPT_DIRECTORY/LCSharedUtils.h" \
    "$LIVECONTAINER_DIRECTORY/LiveContainer/LCSharedUtils.h"
cp \
    "$SCRIPT_DIRECTORY/LCBootstrap.m" \
    "$LIVECONTAINER_DIRECTORY/LiveContainer/LCBootstrap.m"
cp \
    "$SCRIPT_DIRECTORY/AppSceneViewController.m" \
    "$LIVECONTAINER_DIRECTORY/MultitaskSupport/AppSceneViewController.m"
cp \
    "$SCRIPT_DIRECTORY/UIKitHooks.m" \
    "$LIVECONTAINER_DIRECTORY/MultitaskSupport/UIKitHooks.m"
cp \
    "$SCRIPT_DIRECTORY/LiveProcessMain.m" \
    "$LIVECONTAINER_DIRECTORY/LiveProcess/main.m"
cp \
    "$SCRIPT_DIRECTORY/LCMachOUtils.m" \
    "$LIVECONTAINER_DIRECTORY/LiveContainer/LCMachOUtils.m"
cp \
    "$SCRIPT_DIRECTORY/LCMachOUtils.h" \
    "$LIVECONTAINER_DIRECTORY/LiveContainer/LCMachOUtils.h"
cp \
    "$SCRIPT_DIRECTORY/LCAppInfo.m" \
    "$LIVECONTAINER_DIRECTORY/LiveContainerSwiftUI/Models/LCAppInfo.m"
cp \
    "$SCRIPT_DIRECTORY/zsigner.h" \
    "$LIVECONTAINER_DIRECTORY/ZSign/zsigner.h"
cp \
    "$SCRIPT_DIRECTORY/zsign.mm" \
    "$LIVECONTAINER_DIRECTORY/ZSign/zsign.mm"

if [ ! -d "$T3_SWIFT_APP_ICON_PATH" ]; then
    printf 'T3 Swift app icon was not found: %s\n' "$T3_SWIFT_APP_ICON_PATH" >&2
    exit 1
fi
remove_directory "$LIVECONTAINER_DIRECTORY/Resources/Assets.xcassets/AppIcon.appiconset"
ditto \
    "$T3_SWIFT_APP_ICON_PATH" \
    "$LIVECONTAINER_DIRECTORY/$T3_SWIFT_APP_ICON_NAME.icon"
remove_directory "$LIVECONTAINER_DIRECTORY/Resources/Assets.xcassets/AppIconGrey.appiconset"

python3 - "$LIVECONTAINER_DIRECTORY/LiveContainer.xcodeproj/project.pbxproj" "$T3_SWIFT_APP_ICON_NAME" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
icon_name = sys.argv[2]
source = path.read_text()
needle = "ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;"
if needle not in source:
    raise SystemExit("LiveContainer app icon build setting changed. Update the icon integration patch.")
source = source.replace(needle, f"ASSETCATALOG_COMPILER_APPICON_NAME = {icon_name};")

file_ref_id = "F30000000000000000000001"
build_file_id = "F30000000000000000000002"
file_ref = f'\t\t{file_ref_id} /* {icon_name}.icon */ = {{isa = PBXFileReference; lastKnownFileType = wrapper.icon; path = {icon_name}.icon; sourceTree = "<group>"; }};'
build_file = f'\t\t{build_file_id} /* {icon_name}.icon in Resources */ = {{isa = PBXBuildFile; fileRef = {file_ref_id} /* {icon_name}.icon */; }};'
if f"{file_ref_id} /* {icon_name}.icon */" not in source:
    source = source.replace(
        "/* End PBXBuildFile section */",
        f"{build_file}\n/* End PBXBuildFile section */",
        1,
    )
    source = source.replace(
        "/* End PBXFileReference section */",
        f"{file_ref}\n/* End PBXFileReference section */",
        1,
    )
    root_group = "\t\t17DCE9942C7067EC00731D42 = {"
    root_children = "\t\t\tchildren = (\n"
    root_start = source.index(root_group)
    children_start = source.index(root_children, root_start) + len(root_children)
    source = source[:children_start] + f"\t\t\t\t{file_ref_id} /* {icon_name}.icon */,\n" + source[children_start:]
    resources_phase = "\t\t17DCE99B2C7067EC00731D42 /* Resources */ = {"
    phase_start = source.index(resources_phase)
    resource_files = "\t\t\tfiles = (\n"
    files_start = source.index(resource_files, phase_start) + len(resource_files)
    source = source[:files_start] + f"\t\t\t\t{build_file_id} /* {icon_name}.icon in Resources */,\n" + source[files_start:]
path.write_text(source)
PY

python3 - "$LIVECONTAINER_DIRECTORY/LiveContainerSwiftUI/App/LiveContainerSwiftUIApp.swift" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
needle = "            LCTabView()\n"
replacement = "            T3LiveContainerOverlayView()\n"
if source.count(needle) != 1:
    raise SystemExit("LiveContainer entry point changed. Update the T3 overlay patch.")
path.write_text(source.replace(needle, replacement))
PY

rm -rf "$KIT_DERIVED_DATA"
xcodebuild \
    -project "$SWIFT_IOS_DIRECTORY/T3Code.xcodeproj" \
    -scheme T3CodeKit \
    -configuration Release \
    -sdk iphoneos \
    -derivedDataPath "$KIT_DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    IPHONEOS_DEPLOYMENT_TARGET=17.0 \
    build

rm -rf "$LIVE_DERIVED_DATA"
xcodebuild \
    -project "$LIVECONTAINER_DIRECTORY/LiveContainer.xcodeproj" \
    -scheme LiveContainer \
    -configuration Release \
    -sdk iphoneos \
    -derivedDataPath "$LIVE_DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    IPHONEOS_DEPLOYMENT_TARGET=17.0 \
    build

KIT_PRODUCTS="$KIT_DERIVED_DATA/Build/Products/Release-iphoneos"
KIT_FRAMEWORK="$KIT_PRODUCTS/T3CodeKit.framework"
LIVE_APP="$LIVE_DERIVED_DATA/Build/Products/Release-iphoneos/LiveContainer.app"

if [ ! -d "$KIT_FRAMEWORK" ]; then
    printf 'T3CodeKit build product was not found: %s\n' "$KIT_FRAMEWORK" >&2
    exit 1
fi
if [ ! -d "$LIVE_APP" ]; then
    printf 'LiveContainer build product was not found: %s\n' "$LIVE_APP" >&2
    exit 1
fi

rm -rf "$STAGING_DIRECTORY"
mkdir -p "$STAGING_DIRECTORY/Payload"
APP_PATH="$STAGING_DIRECTORY/Payload/$T3_LIVE_DISPLAY_NAME.app"
ditto "$LIVE_APP" "$APP_PATH"
remove_directory "$APP_PATH/PlugIns/ShareExtension.appex"
remove_directory "$APP_PATH/PlugIns/LaunchAppExtension.appex"
remove_directory "$APP_PATH/Settings.bundle"
rm -f "$APP_PATH"/AppIconGrey*.png "$APP_PATH/DefaultIcon.png"
mkdir -p "$APP_PATH/Frameworks"
ditto "$KIT_FRAMEWORK" "$APP_PATH/Frameworks/T3CodeKit.framework"

for framework in "$KIT_PRODUCTS"/*.framework; do
    if [ -d "$framework" ] && [ "$(basename "$framework")" != "T3CodeKit.framework" ]; then
        ditto "$framework" "$APP_PATH/Frameworks/$(basename "$framework")"
    fi
done

for bundle in "$KIT_PRODUCTS"/*.bundle; do
    if [ -d "$bundle" ]; then
        ditto "$bundle" "$APP_PATH/$(basename "$bundle")"
    fi
done

python3 - \
    "$APP_PATH/Info.plist" \
    "$T3_LIVE_BUNDLE_IDENTIFIER" \
    "$T3_LIVE_URL_SCHEME" \
    "$T3_LIVE_MARKETING_VERSION" \
    "$T3_LIVE_BUILD_NUMBER" \
    "$T3_LIVE_DISPLAY_NAME" \
    "$T3_SWIFT_APP_ICON_NAME" <<'PY'
import os
import plistlib
from pathlib import Path
import sys

path = Path(sys.argv[1])
bundle_identifier = sys.argv[2]
url_scheme = sys.argv[3]
marketing_version = sys.argv[4]
build_number = sys.argv[5]
display_name = sys.argv[6]
icon_name = sys.argv[7]
with path.open("rb") as stream:
    info = plistlib.load(stream)

info["CFBundleDisplayName"] = display_name
info["CFBundleName"] = "T3CodeLive"
info["CFBundleIdentifier"] = bundle_identifier
info["CFBundleIconName"] = icon_name
info["CFBundleShortVersionString"] = marketing_version
info["CFBundleVersion"] = build_number
info.pop("CFBundleIconUsesAutomaticDarkModeVariant", None)
for icon_key in ["CFBundleIcons", "CFBundleIcons~ipad"]:
    info.get(icon_key, {}).pop("CFBundleAlternateIcons", None)
info["MinimumOSVersion"] = "17.0"
info["T3EmbeddedLiveContainerRuntime"] = True
info["BGTaskSchedulerPermittedIdentifiers"] = [
    f'{info["CFBundleIdentifier"]}.refresh'
]
info["NSCameraUsageDescription"] = (
    "Scan pairing QR codes and attach photos to T3 Code tasks."
)
info["NSLocalNetworkUsageDescription"] = (
    "Allow T3 Code to connect to T3 Code servers on your local network or tailnet."
)

url_types = info.setdefault("CFBundleURLTypes", [])
for item in url_types:
    schemes = item.get("CFBundleURLSchemes", [])
    if any(scheme in {"livecontainer", "livecontainer2", "livecontainer3"} for scheme in schemes):
        item["CFBundleURLName"] = f"{bundle_identifier}.urlscheme"
        item["CFBundleURLSchemes"] = [url_scheme]
if not any(
    "t3code-swiftui" in item.get("CFBundleURLSchemes", [])
    for item in url_types
):
    url_types.append({
        "CFBundleTypeRole": "Editor",
        "CFBundleURLName": "T3 Code Live Routes",
        "CFBundleURLSchemes": ["t3code-swiftui"],
    })
# SideStore backup URL scheme, mirrored from the stock LiveContainer release IPA
# (sidestore-com.com.kdt.livecontainer -> renamed for this bundle). SideStore opens
# this scheme to hand control back to LiveContainer.
if not any(
    "sidestore-com" in item.get("CFBundleURLSchemes", [])
    for item in url_types
):
    url_types.append({
        "CFBundleTypeRole": "Editor",
        "CFBundleURLName": f"{bundle_identifier}.sidestorebackupurlscheme",
        "CFBundleURLSchemes": [f"sidestore-com.{bundle_identifier}"],
    })
# Primary SideStore scheme, as the stock LiveContainer+SideStore release declares
# it: the embedded SideStore and external stores both address the host with it.
if not any(
    "sidestore" in item.get("CFBundleURLSchemes", [])
    for item in url_types
):
    url_types.append({
        "CFBundleTypeRole": "Editor",
        "CFBundleURLName": f"{bundle_identifier}.sidestoreurlscheme",
        "CFBundleURLSchemes": ["sidestore"],
    })
intents = info.setdefault("INIntentsSupported", [])
for intent in ["RefreshAllIntent", "ViewAppIntent"]:
    if intent not in intents:
        intents.append(intent)
activities = info.setdefault("NSUserActivityTypes", [])
for activity in ["RefreshAllIntent", "ViewAppIntent"]:
    if activity not in activities:
        activities.append(activity)

# Mirror stock LiveContainer release IPA: declare the store app groups so
# SideStore/AltStore grant them in the provisioning profile at install time
# (the store appends its team ID, e.g. group.com.SideStore.SideStore.<TEAM>).
# Without this, the host cannot access the shared group and can never read
# the imported signing certificate.
info.setdefault("ALTAppGroups", ["group.com.SideStore.SideStore", "group.com.rileytestut.AltStore"])

query_schemes = info.setdefault("LSApplicationQueriesSchemes", [])
for scheme in ["livecontainer", "livecontainer2", "livecontainer3", "t3code-livecontainer", "sidestore", "altstore", "altstore-classic"]:
    if scheme not in query_schemes:
        query_schemes.append(scheme)

# Expose the app's Documents folder in the Files app so diagnostics written there
# (t3-live-diagnose.txt) can be retrieved without a debugger.
info["UIFileSharingEnabled"] = True
info["LSSupportsOpeningDocumentsInPlace"] = True

clerk_key = os.environ.get(
    "T3CODE_CLERK_PUBLISHABLE_KEY",
    "pk_live_Y2xlcmsudDMuY29kZXMk",
).strip()
relay_url = os.environ.get(
    "T3CODE_RELAY_URL",
    "https://relay.t3.codes",
).strip()
if clerk_key and relay_url:
    info["T3ConnectClerkPublishableKey"] = clerk_key
    info["T3ConnectClerkJWTTemplate"] = os.environ.get(
        "T3CODE_CLERK_JWT_TEMPLATE",
        "t3-relay",
    ).strip() or "t3-relay"
    info["T3ConnectRelayHTTPURL"] = relay_url

with path.open("wb") as stream:
    plistlib.dump(info, stream, fmt=plistlib.FMT_BINARY)
PY

# Ad-hoc sign the staged app with placeholder entitlements in the EXACT shape of the
# stock LiveContainer release IPA (verified against LiveContainer+SideStore.ipa):
#   team                 AAAAA11111 (SideStore/AltStore placeholder)
#   application-groups   group.com.SideStore.SideStore, group.com.rileytestut.AltStore
#                        (no team suffix - the store appends its real team ID at install)
#   keychain-access-groups AAAAA11111.<bundle>.shared.{0..127}
# SideStore/AltStore read these entitlements from the signature and grant the
# corresponding app groups + keychain groups in the provisioning profile.
# Embed SideStore (LiveContainer fork) as Frameworks/SideStoreApp.framework so
# T3 Code Live can mint and renew its signing certificate in-app with an Apple
# ID sign-in, independent of any externally installed store app. Mirrors the
# stock LiveContainer+SideStore release build (.github/build_github.sh).
T3_LIVE_EMBED_SIDESTORE=${T3_LIVE_EMBED_SIDESTORE:-1}
if [ "$T3_LIVE_EMBED_SIDESTORE" = "1" ]; then
    SIDESTORE_CACHE="$BUILD_DIRECTORY/cache"
    SIDESTORE_IPA="$SIDESTORE_CACHE/SideStore.ipa"
    DYLIBIFY_BIN="$SIDESTORE_CACHE/dylibify"
    mkdir -p "$SIDESTORE_CACHE"
    if [ ! -f "$SIDESTORE_IPA" ]; then
        wget -q -O "$SIDESTORE_IPA" \
            "https://github.com/LiveContainer/SideStore/releases/download/nightly/SideStore.ipa"
    fi
    if [ ! -f "$SIDESTORE_IPA" ]; then
        printf 'SideStore.ipa download failed; building without embedded SideStore.\n' >&2
    else
        SIDESTORE_EXTRACT="$SIDESTORE_CACHE/extract"
        remove_directory "$SIDESTORE_EXTRACT"
        mkdir -p "$SIDESTORE_EXTRACT"
        unzip -q "$SIDESTORE_IPA" -x "__MACOSX/*" -d "$SIDESTORE_EXTRACT"
        if [ -d "$SIDESTORE_EXTRACT/Payload/SideStore.app" ]; then
            ditto "$SIDESTORE_EXTRACT/Payload/SideStore.app" \
                "$APP_PATH/Frameworks/SideStoreApp.framework"
            if [ ! -f "$DYLIBIFY_BIN" ]; then
                curl -fsSL -o "$DYLIBIFY_BIN" \
                    "https://github.com/LiveContainer/dylibify/releases/download/1.0/dylibify" \
                    && chmod +x "$DYLIBIFY_BIN"
            fi
            if [ -f "$DYLIBIFY_BIN" ]; then
                "$DYLIBIFY_BIN" \
                    "$APP_PATH/Frameworks/SideStoreApp.framework/SideStore" \
                    "$APP_PATH/Frameworks/SideStoreApp.framework/SideStore.dylib"
                rm -f "$APP_PATH/Frameworks/SideStoreApp.framework/SideStore"
                ldid -S "$APP_PATH/Frameworks/SideStoreApp.framework/SideStore.dylib" 2>/dev/null || true
                SS_LICENSE="$APP_PATH/Frameworks/SideStoreApp.framework/LICENSE-SIDESTORE-AGPL.txt"
                if [ ! -f "$SS_LICENSE" ]; then
                    curl -fsSL -o "$SS_LICENSE" \
                        "https://raw.githubusercontent.com/LiveContainer/SideStore/develop/LICENSE" \
                        || true
                fi
                echo "Embedded SideStore into $APP_PATH"
            else
                echo "dylibify unavailable; removing unusable SideStoreApp.framework." >&2
                rm -rf "$APP_PATH/Frameworks/SideStoreApp.framework"
            fi
        else
            echo "SideStore.app not found in the downloaded IPA; skipping embedding." >&2
        fi
        remove_directory "$SIDESTORE_EXTRACT"
    fi
fi

ENTITLEMENTS_TMP="$(mktemp /tmp/t3-live-entitlements.XXXXXX.plist)"
python3 - "$LIVECONTAINER_DIRECTORY/entitlements.xml" "$ENTITLEMENTS_TMP" "$T3_LIVE_BUNDLE_IDENTIFIER" <<'PY'
import sys
from pathlib import Path
import plistlib

src = Path(sys.argv[1])
dst = Path(sys.argv[2])
bundle_identifier = sys.argv[3]
text = src.read_text()
# Expand Xcode variables with the same placeholder team the stock LiveContainer IPA uses.
text = text.replace("$(AppIdentifierPrefix)", "AAAAA11111.")
text = text.replace("$(DEVELOPMENT_TEAM)", "AAAAA11111")
text = text.replace("$(APP_GROUP_SIDESTORE)", "group.com.SideStore.SideStore")
text = text.replace("$(APP_GROUP_ALTSTORE)", "group.com.rileytestut.AltStore")
text = text.replace("$(PRODUCT_BUNDLE_IDENTIFIER)", bundle_identifier)
try:
    data = text.encode()
    plist = plistlib.loads(data)
    with dst.open("wb") as f:
        plistlib.dump(plist, f)
except Exception as e:
    # Fallback to raw text if plist parsing fails
    dst.write_text(text)
    print(f"warning: entitlements plist parse failed: {e}", file=sys.stderr)
PY
if [ -f "$ENTITLEMENTS_TMP" ]; then
    # Only ad-hoc sign if we have a valid entitlements file; failure is non-fatal (IPA will remain unsigned)
    if ! codesign -f -s - --entitlements "$ENTITLEMENTS_TMP" "$APP_PATH" 2>&1; then
        echo "warning: ad-hoc signing with entitlements failed (IPA will remain unsigned)" >&2
    fi
    rm -f "$ENTITLEMENTS_TMP"
fi

# Sign the LiveProcess extension with its own placeholder entitlements too. SideStore/AltStore
# read the extension's signature entitlements when generating the extension's profile, so the
# extension must ship signed with the same app groups + keychain groups. Otherwise the extension
# gets a profile without the store app group and cannot access the shared group (App Group:
# Unknown inside the extension), which blocks both the certificate check and guest executables
# stored in the group.
LIVEPROCESS_APPEX_PATH="$APP_PATH/PlugIns/LiveProcess.appex"
if [ -d "$LIVEPROCESS_APPEX_PATH" ] && [ -f "$LIVECONTAINER_DIRECTORY/LiveProcess/LiveProcess.entitlements" ]; then
    ENTITLEMENTS_TMP="$(mktemp /tmp/t3-liveprocess-entitlements.XXXXXX.plist)"
    python3 - "$LIVECONTAINER_DIRECTORY/LiveProcess/LiveProcess.entitlements" "$ENTITLEMENTS_TMP" "$T3_LIVE_BUNDLE_IDENTIFIER" <<'PY'
import sys
from pathlib import Path
import plistlib

src = Path(sys.argv[1])
dst = Path(sys.argv[2])
bundle_identifier = sys.argv[3]
text = src.read_text()
text = text.replace("$(AppIdentifierPrefix)", "AAAAA11111.")
text = text.replace("$(DEVELOPMENT_TEAM)", "AAAAA11111")
text = text.replace("$(APP_GROUP_SIDESTORE)", "group.com.SideStore.SideStore")
text = text.replace("$(APP_GROUP_ALTSTORE)", "group.com.rileytestut.AltStore")
text = text.replace("$(PRODUCT_BUNDLE_IDENTIFIER)", bundle_identifier)
try:
    plist = plistlib.loads(text.encode())
    with dst.open("wb") as f:
        plistlib.dump(plist, f)
except Exception as e:
    dst.write_text(text)
    print(f"warning: LiveProcess entitlements plist parse failed: {e}", file=sys.stderr)
PY
    if [ -f "$ENTITLEMENTS_TMP" ]; then
        if ! codesign -f -s - --entitlements "$ENTITLEMENTS_TMP" "$LIVEPROCESS_APPEX_PATH" 2>&1; then
            echo "warning: ad-hoc signing LiveProcess.appex failed (extension will remain unsigned)" >&2
        fi
        rm -f "$ENTITLEMENTS_TMP"
    fi
fi

T3_REVISION=$(git -C "$REPOSITORY_ROOT" rev-parse HEAD)
remove_directory "$SOURCE_STAGING_DIRECTORY"
mkdir -p "$SOURCE_STAGING_DIRECTORY"
python3 - "$REPOSITORY_ROOT" "$LIVECONTAINER_DIRECTORY" "$SOURCE_STAGING_DIRECTORY" <<'PY'
from pathlib import Path
import shutil
import subprocess
import sys

t3_root = Path(sys.argv[1])
live_root = Path(sys.argv[2])
destination = Path(sys.argv[3])

def git_paths(root: Path) -> list[str]:
    tracked = subprocess.check_output(
        ["git", "-C", str(root), "ls-files", "-z"]
    )
    untracked = subprocess.check_output([
        "git", "-C", str(root), "ls-files", "--others", "--exclude-standard", "-z",
    ])
    paths = set((tracked + untracked).decode().rstrip("\0").split("\0"))
    return sorted(
        path for path in paths
        if path != ".repos" and not path.startswith(".repos/")
    )

def copy_git_worktree(root: Path, output: Path) -> None:
    for relative in git_paths(root):
        if not relative:
            continue
        source = root / relative
        target = output / relative
        if not source.exists() and not source.is_symlink():
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        if source.is_symlink():
            target.symlink_to(source.readlink())
        elif source.is_file():
            shutil.copy2(source, target)

copy_git_worktree(t3_root, destination / "t3code")
shutil.copytree(
    live_root,
    destination / "LiveContainer",
    symlinks=True,
    ignore=shutil.ignore_patterns(".git", ".DS_Store", "DerivedData"),
)
(destination / "BUILD.txt").write_text(
    "Build T3 Code Live with t3code/apps/swift-ios/LiveContainerOverlay/"
    "build-live-ipa.sh.\n"
    "The archive omits t3code/.repos because those reference sources are not "
    "build inputs.\n"
)
PY

rm -f "$SOURCE_OUTPUT_PATH"
ditto -c -k --sequesterRsrc --keepParent \
    "$SOURCE_STAGING_DIRECTORY" \
    "$SOURCE_OUTPUT_PATH"
SOURCE_SHA256=$(python3 - "$SOURCE_OUTPUT_PATH" <<'PY'
from pathlib import Path
import hashlib
import sys

digest = hashlib.sha256()
with Path(sys.argv[1]).open("rb") as stream:
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        digest.update(chunk)
print(digest.hexdigest())
PY
)
SOURCE_FILE_NAME=$(basename "$SOURCE_OUTPUT_PATH")
remove_directory "$SOURCE_STAGING_DIRECTORY"

cp "$REPOSITORY_ROOT/LICENSE" "$APP_PATH/LICENSE-T3CODE.txt"
cp "$LIVECONTAINER_DIRECTORY/LICENSE" "$APP_PATH/LICENSE-LIVECONTAINER-AGPL.txt"
cp "$SCRIPT_DIRECTORY/AGPL-NOTICE.md" "$APP_PATH/T3-LIVE-AGPL-NOTICE.md"
cat > "$APP_PATH/T3-LIVE-SOURCE.txt" <<EOF
T3 Code base revision: $T3_REVISION
LiveContainer revision: $LIVECONTAINER_REVISION
Complete corresponding source: $SOURCE_FILE_NAME
Corresponding source SHA-256: $SOURCE_SHA256
Distribute the source archive with this IPA under GNU AGPL version 3.
EOF

rm -f "$OUTPUT_PATH"
ditto -c -k --sequesterRsrc --keepParent "$STAGING_DIRECTORY/Payload" "$OUTPUT_PATH"

printf 'Created unsigned sideload IPA:\n%s\n' "$OUTPUT_PATH"
printf 'Created complete corresponding source:\n%s\n' "$SOURCE_OUTPUT_PATH"
printf 'Install this IPA with SideStore, AltStore, or another compatible signer.\n'
