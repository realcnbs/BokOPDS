#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

# Keep the familiar command pointed at the active implementation. The old C++
# This is the canonical desktop emulator entry point.
exec "${project_dir}/scripts/run-reader-shell-emulator.sh" "$@"
