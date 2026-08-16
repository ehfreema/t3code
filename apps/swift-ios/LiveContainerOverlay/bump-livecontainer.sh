#!/bin/sh
# Advances the vendored LiveContainer pin to upstream main's HEAD and rebuilds
# the sideload IPA, so upstream fixes keep flowing into T3 Code Live.
#
# Usage:
#   ./bump-livecontainer.sh            # advance pin + rebuild
#   ./bump-livecontainer.sh --check    # report upstream status without touching the pin
#
# If the rebuild fails after a bump, revert by restoring the previous pin:
#   git -C "$(dirname "$0")" diff build-live-ipa.sh   # or edit the pin back and rebuild.
set -eu

SCRIPT_DIRECTORY=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BUILD_SCRIPT="$SCRIPT_DIRECTORY/build-live-ipa.sh"
BUILD_DIRECTORY=${T3_LIVE_BUILD_DIRECTORY:-"$SCRIPT_DIRECTORY/../.livecontainer"}
LIVECONTAINER_DIRECTORY="$BUILD_DIRECTORY/LiveContainer"
REPOSITORY="https://github.com/LiveContainer/LiveContainer.git"

if [ ! -d "$LIVECONTAINER_DIRECTORY/.git" ]; then
    git clone --filter=blob:none --no-checkout "$REPOSITORY" "$LIVECONTAINER_DIRECTORY"
fi

git -C "$LIVECONTAINER_DIRECTORY" fetch --depth=1 origin main
UPSTREAM_HEAD=$(git -C "$LIVECONTAINER_DIRECTORY" rev-parse FETCH_HEAD)

CURRENT_PIN=$(sed -n 's/^LIVECONTAINER_REVISION=${LIVECONTAINER_REVISION:-"\([0-9a-f]*\)"}$/\1/p' "$BUILD_SCRIPT")
if [ -z "$CURRENT_PIN" ]; then
    printf 'Could not read the current pin from %s\n' "$BUILD_SCRIPT" >&2
    exit 1
fi

if [ "$CURRENT_PIN" = "$UPSTREAM_HEAD" ]; then
    printf 'Already at upstream main: %s\n' "$UPSTREAM_HEAD"
    exit 0
fi

printf 'Current pin:   %s\n' "$CURRENT_PIN"
printf 'Upstream main: %s\n' "$UPSTREAM_HEAD"
git -C "$LIVECONTAINER_DIRECTORY" log --oneline -1 "$UPSTREAM_HEAD"

if [ "${1:-}" = "--check" ]; then
    exit 0
fi

python3 - "$BUILD_SCRIPT" "$UPSTREAM_HEAD" <<'PY'
import sys
path, new_pin = sys.argv[1], sys.argv[2]
text = open(path).read()
old = 'LIVECONTAINER_REVISION=${LIVECONTAINER_REVISION:-"'
assert old in text, "pin line not found"
idx = text.index(old)
end = text.index('"}', idx)
text = text[:idx] + old + new_pin + text[end:]
open(path, "w").write(text)
print(f"pin advanced to {new_pin}")
PY

printf 'Rebuilding with the new upstream revision...\n'
"$BUILD_SCRIPT"
