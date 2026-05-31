#!/usr/bin/env bash
set -euo pipefail

exec env \
    -u GH_TOKEN \
    -u GITHUB_TOKEN \
    -u SOURCE_GH_TOKEN \
    "$@"
