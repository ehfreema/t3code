import * as DateTime from "effect/DateTime";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Option from "effect/Option";
import * as Schema from "effect/Schema";
import { spawn } from "node:child_process";
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

const activeBuildRoots = new Set<string>();

const IOS_BUILD_SCRIPT = `
set -euo pipefail
ROOT="$1"
STATUS="$ROOT/.t3/ios-build-status.json"
BUILDS="$ROOT/.t3/builds"
DD="$BUILDS/dd"
PHASE_FILE="$BUILDS/phase"
PID_FILE="$BUILDS/runner.pid"
DONE=0
XB_PID=""
HEARTBEAT_PID=""

write_status() {
  mkdir -p "$ROOT/.t3" "$BUILDS"
  printf '%s|%s\\n' "$1" "$2" > "$PHASE_FILE"
  printf '{"phase":"%s","message":"%s","updatedAt":"%s"}' "$1" "$2" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$STATUS"
}

fail() {
  DONE=1
  write_status failed "$1"
  exit 1
}

clear_pid() {
  if [ -f "$PID_FILE" ]; then
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [ "$pid" = "$$" ]; then
      rm -f "$PID_FILE"
    fi
  fi
}

mkdir -p "$BUILDS"
exec >>"$BUILDS/runner.log" 2>&1
printf 'runner started pid=%s ppid=%s at=%s\\n' "$$" "$PPID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '%s\\n' "$$" > "$PID_FILE"

on_error() {
  status=$?
  printf 'runner error exit=%s line=%s command=%s\\n' "$status" "$LINENO" "$BASH_COMMAND"
  DONE=1
  write_status failed "Build failed (line $LINENO; see .t3/builds/runner.log)"
}

on_exit() {
  status=$?
  if [ -n "$HEARTBEAT_PID" ]; then
    kill "$HEARTBEAT_PID" 2>/dev/null || true
  fi
  clear_pid
  if [ "$DONE" -eq 0 ]; then
    write_status failed "Build stopped unexpectedly (exit $status; see .t3/builds/runner.log)"
  fi
}

on_signal() {
  signal="$1"
  DONE=1
  if [ -n "$XB_PID" ]; then
    kill -TERM -- "-$XB_PID" 2>/dev/null || true
  fi
  write_status failed "Build interrupted ($signal; tap Run to try again)"
  exit 1
}

trap on_exit EXIT
trap on_error ERR
trap 'on_signal TERM' TERM
trap 'on_signal INT' INT
trap 'on_signal HUP' HUP

# Refresh the current phase while a long Xcode operation runs. If the build
# process dies without running its trap, fail the status instead of leaving the
# client on stale progress forever.
MAIN_PID=$$
(
  while :; do
    sleep 15
    if ! kill -0 "$MAIN_PID" 2>/dev/null; then
      case "$(IFS='|' read -r P M < "$PHASE_FILE" 2>/dev/null && printf '%s' "$P")" in
        done|failed) exit 0 ;;
      esac
      write_status failed "Build stopped (the server restarted or was killed); tap Run to try again"
      exit 0
    fi
    if [ ! -f "$PHASE_FILE" ]; then
      write_status failed "Build stopped (build state was lost); tap Run to try again"
      exit 0
    fi
    IFS='|' read -r P M < "$PHASE_FILE" || exit 0
    case "$P" in done|failed) exit 0 ;; esac
    if [ -n "$P" ]; then
      printf '{"phase":"%s","message":"%s","updatedAt":"%s"}' "$P" "$M" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$STATUS"
    fi
  done
) &
HEARTBEAT_PID=$!

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
  # Read tracked project directories from Git's index without descending into
  # large Pods, DerivedData, node_modules, or prior build output.
  if git -C "$ROOT" rev-parse --git-dir > /dev/null 2>&1; then
    GIT_CANDIDATES=$(git -C "$ROOT" ls-files --cached 2>/dev/null | grep -E '\\.xcodeproj/|\\.xcworkspace/' | head -n 20) || GIT_CANDIDATES=""
    if [ -n "$GIT_CANDIDATES" ]; then
      while IFS= read -r line; do
        cand=$(printf '%s\n' "$line" | sed -E 's#\\.xcodeproj/.*#.xcodeproj#; s#\\.xcworkspace/.*#.xcworkspace#')
        case "$cand" in
          "$ROOT"/*) ;;
          *) cand="$ROOT/$cand" ;;
        esac
        case "$cand" in
          *.xcworkspace)
            case "$cand" in
              *.xcodeproj/*) ;;
              *) if [ -z "$WS" ]; then WS="$cand"; fi ;;
            esac
            ;;
          *.xcodeproj) if [ -z "$PROJ" ]; then PROJ="$cand"; fi ;;
        esac
      done <<EOF
$GIT_CANDIDATES
EOF
    fi
  fi
fi
if [ -z "$PROJ" ] && [ -z "$WS" ]; then
  # Non-Git or untracked projects use a bounded, pruned filesystem walk.
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
$(perl -e 'alarm 10; exec @ARGV' find "$ROOT" \\( -path "$ROOT/.t3" -o -path "*/.git" -o -path "*/Pods" -o -path "*/node_modules" -o -path "*/DerivedData" \\) -prune -o \\( -name "*.xcodeproj" -o -name "*.xcworkspace" \\) -print 2>/dev/null | sort)
EOF
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
    echo "--- git candidates ---"
    git -C "$ROOT" ls-files --cached 2>&1 | grep -E '\\.xcodeproj/|\\.xcworkspace/' | head -n 20
    echo "--- find maxdepth 6 filtered ---"
    find "$ROOT" -maxdepth 6 \\( -name "*.xcodeproj" -o -name "*.xcworkspace" \\) -not -path "*/Pods/*" -not -path "*/.t3/*" -not -path "*/node_modules/*" -not -path "*/DerivedData/*" 2>&1 | head -n 20
  } > "$BUILDS/discovery.log" 2>&1 || true
  fail "No Xcode project or workspace found in this thread (searched $ROOT; see .t3/builds/discovery.log)"
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

# Keep xcodebuild in its own process group. The interrupt trap can then stop
# the complete compiler tree instead of leaving clang and swiftc children.
run_xcodebuild() {
  local log="$1"; shift
  perl -e 'setpgrp(0, 0); exec @ARGV' "$@" > "$log" 2>&1 &
  XB_PID=$!
  while kill -0 "$XB_PID" 2>/dev/null; do
    sleep 1
  done
  wait "$XB_PID"
}

write_status dependencies "Resolving Swift packages"
if [ "$TARGET" = "$WS" ]; then
  run_xcodebuild "$BUILDS/packages.log" xcodebuild -workspace "$TARGET" -scheme "$SCHEME" \\
    -resolvePackageDependencies \\
    -clonedSourcePackagesDirPath "$PACKAGE_DIR" \\
    -derivedDataPath "$DD" || fail "Swift package resolution failed (see .t3/builds/packages.log)"
else
  run_xcodebuild "$BUILDS/packages.log" xcodebuild -project "$TARGET" -scheme "$SCHEME" \\
    -resolvePackageDependencies \\
    -clonedSourcePackagesDirPath "$PACKAGE_DIR" \\
    -derivedDataPath "$DD" || fail "Swift package resolution failed (see .t3/builds/packages.log)"
fi

write_status building "Building with Xcode (this can take several minutes)"
if [ "$TARGET" = "$WS" ]; then
  run_xcodebuild "$BUILDS/xcodebuild.log" xcodebuild -workspace "$TARGET" -scheme "$SCHEME" \\
    -configuration Release \\
    -sdk iphoneos \\
    -destination 'generic/platform=iOS' \\
    -derivedDataPath "$DD" \\
    -clonedSourcePackagesDirPath "$PACKAGE_DIR" \\
    -archivePath "$DD/archive.xcarchive" \\
    -skipPackagePluginValidation \\
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \\
    archive || true
else
  run_xcodebuild "$BUILDS/xcodebuild.log" xcodebuild -project "$TARGET" -scheme "$SCHEME" \\
    -configuration Release \\
    -sdk iphoneos \\
    -destination 'generic/platform=iOS' \\
    -derivedDataPath "$DD" \\
    -clonedSourcePackagesDirPath "$PACKAGE_DIR" \\
    -archivePath "$DD/archive.xcarchive" \\
    -skipPackagePluginValidation \\
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \\
    archive || true
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
# The manifest allows at most 512 chunk paths and each workspace read returns
# at most 1 MiB. A 768 KiB binary chunk encodes to exactly 1 MiB of base64.
ARTIFACT="$BUILDS/$ARTIFACT_NAME.ipa"
CHUNKS_JSON=$(python3 - "$ARTIFACT" "$ROOT" <<'PY'
import base64, json, os, pathlib, sys
artifact = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2])
for stale in artifact.parent.glob(artifact.name + ".b64.*.txt"):
    stale.unlink()
chunks = []
with artifact.open("rb") as source:
    index = 0
    while data := source.read(786432):
        path = pathlib.Path(f"{artifact}.b64.{index:04d}.txt")
        path.write_text(base64.b64encode(data).decode("ascii"))
        chunks.append(os.path.relpath(path, root))
        index += 1
print(json.dumps(chunks))
PY
) || fail "IPA chunking failed (see .t3/builds/xcodebuild.log)"
cat > "$ROOT/.t3/ios-app.json" <<JSON
{
  "schemaVersion": 1,
  "displayName": "$DISPLAY_NAME",
  "bundleIdentifier": "$BUNDLE_ID",
  "artifactPath": ".t3/builds/$ARTIFACT_NAME.ipa",
  "artifactChunks": $CHUNKS_JSON
}
JSON

write_status done "Build complete"
DONE=1
clear_pid
trap - EXIT TERM INT HUP
kill "$HEARTBEAT_PID" 2>/dev/null || true
`;

const BuildStatusSchema = Schema.Struct({
  phase: Schema.String,
  message: Schema.String,
  updatedAt: Schema.String,
});

const BuildStatusJsonCodec = Schema.fromJsonString(BuildStatusSchema);
const decodeBuildStatus = Schema.decodeUnknownOption(BuildStatusJsonCodec);
const encodeBuildStatus = Schema.encodeUnknownEffect(BuildStatusJsonCodec);

function hasFreshActiveBuildStatus(
  root: string,
): Effect.Effect<boolean, never, FileSystem.FileSystem> {
  return Effect.gen(function* () {
    const fileSystem = yield* FileSystem.FileSystem;
    const status = yield* fileSystem
      .readFileString(`${root}/.t3/ios-build-status.json`)
      .pipe(Effect.option, Effect.map(Option.flatMap(decodeBuildStatus)));
    if (Option.isNone(status) || status.value.phase === "done" || status.value.phase === "failed") {
      return false;
    }
    const updatedAt = Date.parse(status.value.updatedAt);
    if (!Number.isFinite(updatedAt) || Date.now() - updatedAt > 60_000) {
      return false;
    }

    const runnerPID = yield* fileSystem
      .readFileString(`${root}/.t3/builds/runner.pid`)
      .pipe(Effect.option);
    return Option.isNone(runnerPID) || isProcessAlive(runnerPID.value);
  }).pipe(Effect.catch(() => Effect.succeed(false)));
}

function isProcessAlive(rawPID: string): boolean {
  const pid = Number.parseInt(rawPID.trim(), 10);
  if (!Number.isInteger(pid) || pid <= 0) {
    return false;
  }
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error instanceof Error && "code" in error && error.code === "EPERM";
  }
}

/** Marks a non-terminal build as failed when its process exits unexpectedly. */
export function writeFailedStatusIfActive(
  root: string,
  message: string,
): Effect.Effect<void, never, FileSystem.FileSystem> {
  return Effect.gen(function* () {
    const fileSystem = yield* FileSystem.FileSystem;
    const statusPath = `${root}/.t3/ios-build-status.json`;
    const existing = yield* fileSystem
      .readFileString(statusPath)
      .pipe(Effect.option, Effect.map(Option.flatMap(decodeBuildStatus)));
    if (
      Option.isSome(existing) &&
      (existing.value.phase === "done" || existing.value.phase === "failed")
    ) {
      return;
    }
    const encoded = yield* encodeBuildStatus({
      phase: "failed",
      message,
      updatedAt: DateTime.toDateUtc(DateTime.nowUnsafe()).toISOString(),
    });
    yield* fileSystem.writeFileString(statusPath, encoded);
  }).pipe(Effect.ignore);
}

function runBuildScript(root: string) {
  return Effect.gen(function* () {
    const child = yield* Effect.try({
      try: () =>
        spawn("bash", ["-c", IOS_BUILD_SCRIPT, "t3-ios-build", root], {
          detached: true,
          stdio: "ignore",
        }),
      catch: (cause) =>
        new IosBuildProcessError({
          message: `Failed to spawn build: ${String(cause)}`,
        }),
    });
    child.unref();
  }).pipe(
    Effect.catchTag("IosBuildProcessError", (error) =>
      writeFailedStatusIfActive(root, error.message),
    ),
  );
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

    if (activeBuildRoots.has(root)) {
      return { started: false };
    }
    activeBuildRoots.add(root);
    const hasExistingBuild = yield* hasFreshActiveBuildStatus(root).pipe(
      Effect.onInterrupt(() =>
        Effect.sync(() => {
          activeBuildRoots.delete(root);
        }),
      ),
    );
    if (hasExistingBuild) {
      activeBuildRoots.delete(root);
      return { started: false };
    }

    yield* runBuildScript(root).pipe(
      Effect.ensuring(
        Effect.sync(() => {
          activeBuildRoots.delete(root);
        }),
      ),
      Effect.forkDetach,
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
