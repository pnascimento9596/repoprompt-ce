#!/usr/bin/env bash
set -euo pipefail

# Strips the three #Preview { ... } blocks in KeyboardShortcuts 2.3.0's
# Recorder.swift. The SwiftUI Previews macro plugin (PreviewsMacros) is bundled
# with Xcode.app but absent from a Command Line Tools-only Swift toolchain, so
# the dependency fails to compile in release on CLT-only hosts. Removing the
# preview blocks is harmless on Xcode-equipped hosts too. Prefer an upstream
# fix, pinned fork, or vendored package over long-term mutation of SwiftPM's
# .build/checkouts state.

ROOT_DIR="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_WITHOUT_GITHUB_TOKENS="${REPOPROMPT_RUN_WITHOUT_GITHUB_TOKENS:-$SCRIPT_DIR/run_without_github_tokens.sh}"
SWIFTPM_SCRATCH_PATH="${REPOPROMPT_SWIFTPM_SCRATCH_PATH:-$ROOT_DIR/.build}"
CHECKOUT_DIR="$SWIFTPM_SCRATCH_PATH/checkouts/KeyboardShortcuts"
RECORDER_FILE="$CHECKOUT_DIR/Sources/KeyboardShortcuts/Recorder.swift"
PATCH_FILE="$SCRIPT_DIR/patches/keyboardshortcuts-2.3.0-preview-macros.patch"
EXPECTED_VERSION="2.3.0"
EXPECTED_REVISION="045cf174010beb335fa1d2567d18c057b8787165"
PATCH_MARKER="RepoPromptKeyboardShortcutsPreviewMacrosV1"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

run() {
    printf '+ '
    printf '%q ' "$@"
    printf '\n'
    "$@"
}

[[ -n "$ROOT_DIR" ]] || fail "Usage: $0 <repo-root>"
[[ -f "$PATCH_FILE" ]] || fail "Missing KeyboardShortcuts preview macros patch: $PATCH_FILE"

if [[ ! -f "$RECORDER_FILE" ]]; then
    run "$RUN_WITHOUT_GITHUB_TOKENS" swift package \
        --package-path "$ROOT_DIR" \
        --scratch-path "$SWIFTPM_SCRATCH_PATH" \
        resolve
fi
[[ -f "$RECORDER_FILE" ]] || fail "Could not locate KeyboardShortcuts Recorder.swift after package resolution: $RECORDER_FILE"

python3 - "$ROOT_DIR/Package.resolved" "$EXPECTED_VERSION" "$EXPECTED_REVISION" <<'PY'
import json
import sys
from pathlib import Path

resolved_path = Path(sys.argv[1])
expected_version = sys.argv[2]
expected_revision = sys.argv[3]
try:
    pins = json.loads(resolved_path.read_text(encoding="utf-8")).get("pins", [])
except FileNotFoundError:
    raise SystemExit(f"ERROR: Missing Package.resolved at {resolved_path}")
for pin in pins:
    if pin.get("identity") == "keyboardshortcuts":
        state = pin.get("state", {})
        actual_version = state.get("version")
        actual_revision = state.get("revision")
        if actual_version != expected_version or actual_revision != expected_revision:
            raise SystemExit(
                "ERROR: KeyboardShortcuts dependency version or revision changed; "
                f"expected {expected_version} @ {expected_revision}, "
                f"got {actual_version or '<missing>'} @ {actual_revision or '<missing>'}. "
                "Review Scripts/patches/keyboardshortcuts-2.3.0-preview-macros.patch before packaging."
            )
        break
else:
    raise SystemExit("ERROR: KeyboardShortcuts dependency pin is missing from Package.resolved")
PY

if grep -Fq "$PATCH_MARKER" "$RECORDER_FILE"; then
    printf 'KeyboardShortcuts preview macros patch already applied: %s\n' "$RECORDER_FILE"
    exit 0
fi

run chmod u+w "$RECORDER_FILE"
if ! (cd "$CHECKOUT_DIR" && git apply --unidiff-zero --check "$PATCH_FILE"); then
    fail "KeyboardShortcuts preview macros patch no longer applies cleanly. Review $PATCH_FILE against $RECORDER_FILE."
fi
run bash -c 'cd "$1" && git apply --unidiff-zero "$2"' bash "$CHECKOUT_DIR" "$PATCH_FILE"
printf 'Applied KeyboardShortcuts preview macros patch: %s\n' "$PATCH_FILE"
