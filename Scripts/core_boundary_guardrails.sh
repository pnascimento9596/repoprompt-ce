#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CORE_ROOT="Sources/RepoPromptCore"
findings=0
temporary_file=""

cleanup() {
  if [[ -n "$temporary_file" ]]; then
    rm -f "$temporary_file"
  fi
}
trap cleanup EXIT

report_matches() {
  local label="$1"
  local pattern="$2"
  shift 2
  local output status

  set +e
  output="$(grep -n -E -- "$pattern" "$@" 2>&1)"
  status=$?
  set -e

  if [[ "$status" -eq 0 ]]; then
    printf 'ADVISORY: %s\n' "$label"
    printf '%s\n' "$output"
    findings=$((findings + 1))
  elif [[ "$status" -ne 1 ]]; then
    printf 'ERROR: core boundary grep failed while checking: %s\n' "$label" >&2
    printf '%s\n' "$output" >&2
    exit "$status"
  fi
}

printf 'Core boundary guardrails are report-only until the physical RepoPromptCore boundary lands.\n'

if [[ -d "$CORE_ROOT" ]]; then
  core_swift_files=()
  temporary_file="$(mktemp "${TMPDIR:-/tmp}/repoprompt-core-boundary.XXXXXX")"
  if ! find "$CORE_ROOT" -type f -name '*.swift' -print0 > "$temporary_file"; then
    printf 'ERROR: failed to enumerate Swift files under %s\n' "$CORE_ROOT" >&2
    exit 1
  fi
  while IFS= read -r -d '' file; do
    core_swift_files+=("$file")
  done < "$temporary_file"

  if [[ "${#core_swift_files[@]}" -eq 0 ]]; then
    printf 'ADVISORY: %s exists but contains no Swift files to scan.\n' "$CORE_ROOT"
  else
    report_matches \
      "forbidden Apple UI/platform import found under $CORE_ROOT" \
      '^[[:space:]]*(@[[:alnum:]_]+[[:space:]]+)*import([[:space:]]+(class|struct|enum|protocol|func|var|let|typealias))?[[:space:]]+(AppKit|SwiftUI|Sparkle|KeyboardShortcuts|CoreServices|Security|Darwin)([.]|[[:space:]]|$)' \
      "${core_swift_files[@]}"
    report_matches \
      "app-owned runtime reference found under $CORE_ROOT" \
      '(^|[^[:alnum:]_])(WindowState|WindowStatesManager|NSApplication|NSWorkspace)([^[:alnum:]_]|$)' \
      "${core_swift_files[@]}"
  fi
else
  printf 'OK: %s is absent as expected before the physical-boundary item; skipping core source scan.\n' "$CORE_ROOT"
fi

report_matches \
  "app packaging mentions a standalone headless command; keep the standalone host independently packaged" \
  'repoprompt-headless|rpce-headless' \
  Scripts/package_app.sh

if [[ "$findings" -eq 0 ]]; then
  printf 'OK: advisory core boundary scan found no policy findings.\n'
else
  printf 'ADVISORY: core boundary scan reported %s finding%s; Item 0 does not enforce them yet.\n' \
    "$findings" "$([[ "$findings" == 1 ]] && printf '' || printf 's')"
fi
