import * as Duration from "effect/Duration";
import * as Effect from "effect/Effect";
import * as Schema from "effect/Schema";
import * as Scope from "effect/Scope";
import * as Stream from "effect/Stream";
import { ChildProcess, ChildProcessSpawner } from "effect/unstable/process";
import { IosBuildStartError } from "@t3tools/contracts";
import * as WorkspacePaths from "../workspace/WorkspacePaths.ts";

class IosBuildProcessError extends Schema.TaggedErrorClass<IosBuildProcessError>()(
  "IosBuildProcessError",
  {
    message: Schema.String,
  },
) {}

/**
 * Deterministic iOS app build for the on-device runtime. The client requests the
 * build; the server runs xcodebuild itself (no agent involvement, nothing in the
 * chat) and reports progress through `.t3/ios-build-status.json` in the workspace,
 * which the client polls.
 */

const BUILD_TIMEOUT = Duration.minutes(30);

let daemonScope: Scope.Scope | undefined;

const daemonScopeEffect: Effect.Effect<Scope.Scope, never, never> = Effect.suspend(() => {
  if (daemonScope) {
    return Effect.succeed(daemonScope);
  }
  return Effect.gen(function* () {
    const scope = yield* Scope.make();
    daemonScope = scope;
    return scope;
  });
});

const IOS_BUILD_SCRIPT = `
set -euo pipefail
ROOT="$1"
STATUS="$ROOT/.t3/ios-build-status.json"
BUILDS="$ROOT/.t3/builds"
DD="$BUILDS/dd"
FAILED=0

write_status() {
  mkdir -p "$ROOT/.t3"
  printf '{"phase":"%s","message":"%s","updatedAt":"%s"}' "$1" "$2" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$STATUS"
}

fail() {
  FAILED=1
  printf '{"phase":"failed","message":"%s","updatedAt":"%s"}' "$1" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$STATUS"
  exit 1
}

trap 'status=$?; if [ "$FAILED" -eq 0 ] && [ "$status" -ne 0 ]; then write_status failed "Build step failed; see .t3/builds/xcodebuild.log"; fi' EXIT

mkdir -p "$BUILDS"
write_status locating "Locating Xcode project"

PROJ=""
WS=""
# Fast path: project at workspace root is the common case (Harbour, etc.).
for d in "$ROOT"/*.xcodeproj "$ROOT"/*.xcworkspace; do
  [ -e "$d" ] || continue
  case "$d" in
    *.xcworkspace)
      case "$d" in
        *.xcodeproj/*) ;;
        *) if [ -z "$WS" ]; then WS="$d"; fi ;;
      esac
      ;;
    *.xcodeproj) if [ -z "$PROJ" ]; then PROJ="$d"; fi ;;
  esac
done
if [ -z "$PROJ" ] && [ -z "$WS" ]; then
  # Worktrees can be at varying depths and may have large Pods trees.
  # Prefer Git's index (instant, no filesystem walk) and fall back to a
  # pruned find only when not inside a Git worktree.
  GIT_CANDIDATES=$(git -C "$ROOT" ls-files --cached --others --exclude-standard 2>/dev/null | grep -E '\.xcodeproj$|\.xcworkspace$' | head -n 20)
  if [ -n "$GIT_CANDIDATES" ]; then
    while IFS= read -r line; do
      case "$line" in
        *.xcworkspace)
          case "$line" in
            *.xcodeproj/*) ;;
            *) if [ -z "$WS" ]; then WS="$ROOT/$line"; fi ;;
          esac
          ;;
        *.xcodeproj) if [ -z "$PROJ" ]; then PROJ="$ROOT/$line"; fi ;;
      esac
    done <<EOF
$GIT_CANDIDATES
EOF
  else
    while IFS= read -r line; do
      case "$line" in
        *.xcworkspace)
          case "$line" in
            *.xcodeproj/*) ;;
            *) if [ -z "$WS" ]; then WS="$line"; fi ;;
          esac
          ;;
        *.xcodeproj) if [ -z "$PROJ" ]; then PROJ="$line"; fi ;;
      esac
    done <<EOF
$(perl -e 'alarm 10; exec @ARGV' find "$ROOT" \( -path "$ROOT/.t3" -o -path "*/.git" -o -path "*/Pods" -o -path "*/node_modules" -o -path "*/DerivedData" \) -prune -o \( -name "*.xcodeproj" -o -name "*.xcworkspace" \) -print 2>/dev/null | sort)
EOF
  fi
fi

 TARGET=""
 if [ -n "$WS" ]; then
   TARGET="$WS"
 elif [ -n "$PROJ" ]; then
   TARGET="$PROJ"
 else
   {
     echo "searched: $ROOT"
     ls -la "$ROOT" 2>&1 | head -n 20
     echo "--- find maxdepth 6 raw ---"
     find "$ROOT" -maxdepth 6 \( -name "*.xcodeproj" -o -name "*.xcworkspace" \) 2>&1 | head -n 20
     echo "--- find maxdepth 6 filtered ---"
     find "$ROOT" -maxdepth 6 \( -name "*.xcodeproj" -o -name "*.xcworkspace" \) -not -path "*/Pods/*" -not -path "*/.t3/*" -not -path "*/node_modules/*" -not -path "*/DerivedData/*" 2>&1 | head -n 20
   } > "$BUILDS/discovery.log" 2>&1 || true
   fail "No Xcode project or workspace found in this thread (searched $ROOT; see .t3/builds/discovery.log)"
 fi
 fi

 write_status scheme "Reading Xcode schemes"
 if [ "$TARGET" = "$WS" ]; then
   SCHEMES_JSON=$(xcodebuild -workspace "$TARGET" -list -json 2>/dev/null) || fail "xcodebuild -list failed"
 else
   SCHEMES_JSON=$(xcodebuild -project "$TARGET" -list -json 2>/dev/null) || fail "xcodebuild -list failed"
 fi
SCHEME=$(TARGET="$TARGET" python3 - "$SCHEMES_JSON" <<'PY'
import json, sys, os
try:
    data = json.loads(sys.argv[1])
    schemes = data["workspace"]["schemes"] if "workspace" in data else data["project"]["schemes"]
except Exception:
    sys.exit(1)
if not schemes:
    sys.exit(1)
# Prefer the iOS app scheme. Heuristics in order:
# 1) scheme name mentioning iOS
# 2) scheme matching the project basename (Harbour.xcodeproj -> Harbour)
# 3) skip library-like schemes (Common*) when a non-Common alternative exists
# 4) first scheme
target_base = os.path.splitext(os.path.basename(os.environ.get("TARGET", "")))[0]
ios = [s for s in schemes if "ios" in s.lower()]
if ios:
    print(ios[0])
elif target_base in schemes:
    print(target_base)
else:
    non_common = [s for s in schemes if not s.lower().startswith("common")]
    print(non_common[0] if non_common else schemes[0])
PY
) || fail "No buildable scheme found"

write_status building "Building with Xcode (this can take several minutes)"
write_status dependencies "Initializing dependencies"
# Submodules commonly contain local Swift packages. Initialize them before
# asking Xcode to resolve the package graph; otherwise Xcode reports a
# misleading missing-product error for an empty submodule directory. A
# non-Git workspace simply has no submodules to initialize.
if git -C "$ROOT" rev-parse --show-toplevel > /dev/null 2>&1; then
  git -C "$ROOT" submodule update --init --recursive > "$BUILDS/submodules.log" 2>&1 || fail "Git submodule initialization failed (see .t3/builds/submodules.log)"
fi

# Derived data is disposable, but resolved package checkouts are reusable.
# Keep them in their own .t3 cache and pass that path to every Xcode command.
PACKAGE_DIR="$BUILDS/source-packages"
rm -rf "$DD"
mkdir -p "$DD" "$PACKAGE_DIR"

write_status dependencies "Resolving Swift packages"
if [ "$TARGET" = "$WS" ]; then
  xcodebuild -workspace "$TARGET" -scheme "$SCHEME" \\
    -resolvePackageDependencies \\
    -clonedSourcePackagesDirPath "$PACKAGE_DIR" \\
    -derivedDataPath "$DD" > "$BUILDS/packages.log" 2>&1 || fail "Swift package resolution failed (see .t3/builds/packages.log)"
else
  xcodebuild -project "$TARGET" -scheme "$SCHEME" \\
    -resolvePackageDependencies \\
    -clonedSourcePackagesDirPath "$PACKAGE_DIR" \\
    -derivedDataPath "$DD" > "$BUILDS/packages.log" 2>&1 || fail "Swift package resolution failed (see .t3/builds/packages.log)"
fi

if [ "$TARGET" = "$WS" ]; then
  xcodebuild -workspace "$TARGET" -scheme "$SCHEME" \\
    -configuration Release \\
    -sdk iphoneos \\
    -destination 'generic/platform=iOS' \\
    -derivedDataPath "$DD" \\
    -clonedSourcePackagesDirPath "$PACKAGE_DIR" \\
    -archivePath "$DD/archive.xcarchive" \\
    -skipPackagePluginValidation \\
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \\
    archive > "$BUILDS/xcodebuild.log" 2>&1 || true
else
  xcodebuild -project "$TARGET" -scheme "$SCHEME" \\
    -configuration Release \\
    -sdk iphoneos \\
    -destination 'generic/platform=iOS' \\
    -derivedDataPath "$DD" \\
    -clonedSourcePackagesDirPath "$PACKAGE_DIR" \\
    -archivePath "$DD/archive.xcarchive" \\
    -skipPackagePluginValidation \\
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \\
    archive > "$BUILDS/xcodebuild.log" 2>&1 || true
fi

# A build plugin may return failure after Xcode has produced a valid app. The
# archive is usable for Run-for-testing in that case, so inspect its products
# instead of treating the process exit code as the only signal.
APP=$(find "$DD/archive.xcarchive/Products/Applications" -maxdepth 1 -name "*.app" 2>/dev/null | sort | head -n 1)
if [ -z "$APP" ]; then
  APP=$(find "$DD/Build/Products/Release-iphoneos" -maxdepth 1 -name "*.app" 2>/dev/null | sort | head -n 1)
fi
if [ -z "$APP" ]; then
  APP=$(find "$DD/Build/Intermediates.noindex/ArchiveIntermediates" -maxdepth 8 -name "*.app" 2>/dev/null | sort | head -n 1)
fi
if [ -z "$APP" ]; then
  # Still no app — surface the real xcodebuild failure.
  cat "$BUILDS/xcodebuild.log" 2>/dev/null | tail -n 20 >&2 || true
  fail "xcodebuild failed (see .t3/builds/xcodebuild.log)"
fi

BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Info.plist" 2>/dev/null || echo "")
[ -n "$BUNDLE_ID" ] || fail "Could not read the app bundle identifier"

DISPLAY_NAME=$(/usr/libexec/PlistBuddy -c "Print :CFBundleDisplayName" "$APP/Info.plist" 2>/dev/null || echo "")
if [ -z "$DISPLAY_NAME" ]; then
  DISPLAY_NAME=$(/usr/libexec/PlistBuddy -c "Print :CFBundleName" "$APP/Info.plist" 2>/dev/null || basename "$APP" .app)
fi

ARTIFACT_NAME=$(echo "$DISPLAY_NAME" | tr ' ' '-')
write_status packaging "Packaging IPA"

rm -rf "$BUILDS/Payload"
mkdir -p "$BUILDS/Payload"
cp -R "$APP" "$BUILDS/Payload/$DISPLAY_NAME.app"
rm -f "$BUILDS/$ARTIFACT_NAME.ipa"
(cd "$BUILDS" && zip -qr "$ARTIFACT_NAME.ipa" Payload)

write_status manifest "Writing build manifest"
cat > "$ROOT/.t3/ios-app.json" <<JSON
{
  "schemaVersion": 1,
  "displayName": "$DISPLAY_NAME",
  "bundleIdentifier": "$BUNDLE_ID",
  "artifactPath": ".t3/builds/$ARTIFACT_NAME.ipa"
}
JSON

write_status done "Build complete"
trap - EXIT
`;

function runBuildScript(root: string) {
  return Effect.gen(function* () {
    const commandSpawner = yield* ChildProcessSpawner.ChildProcessSpawner;
    const command = ChildProcess.make("bash", ["-c", IOS_BUILD_SCRIPT, "t3-ios-build", root], {
      shell: false,
    });
    const child = yield* commandSpawner.spawn(command).pipe(
      Effect.mapError(
        (cause) =>
          new IosBuildProcessError({
            message: `Failed to spawn build: ${String(cause)}`,
          }),
      ),
    );

    const result = yield* Effect.all(
      [Stream.runDrain(child.stdout), Stream.runDrain(child.stderr), child.exitCode],
      { concurrency: 3 },
    ).pipe(
      Effect.mapError((cause) => new IosBuildProcessError({ message: String(cause) })),
      Effect.timeout(BUILD_TIMEOUT),
    );

    const exitCode = result[2];
    if (exitCode !== 0) {
      return yield* new IosBuildProcessError({
        message: `Build exited with code ${exitCode}`,
      });
    }
  });
}

export const startIOSBuild = (input: { workspaceRoot: string; threadId: string }) =>
  Effect.gen(function* () {
    const paths = yield* WorkspacePaths.WorkspacePaths;
    const root = yield* paths.normalizeWorkspaceRoot(input.workspaceRoot).pipe(
      Effect.mapError(
        (cause) =>
          new IosBuildStartError({
            message: `Workspace root is not valid: ${cause._tag}`,
          }),
      ),
    );

    const scope = yield* daemonScopeEffect;
    yield* runBuildScript(root).pipe(
      Effect.provideService(Scope.Scope, scope),
      Effect.forkIn(scope),
    );
    return { started: true };
  }).pipe(
    // Any unexpected failure (missing services, spawner defects) becomes a
    // readable IosBuildStartError so the client can surface the real reason
    // instead of a generic RPC rejection.
    Effect.catchDefect(
      (defect) =>
        new IosBuildStartError({
          message: `iPhone build request failed: ${String(defect)}`,
        }),
    ),
  );
