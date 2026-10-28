#!/bin/bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
    printf 'UNKNOWN: this probe requires native arm64 macOS\n'
    exit 2
fi
if ! xcrun --find swiftc >/dev/null 2>&1; then
    printf 'UNKNOWN: install Xcode Command Line Tools (xcode-select --install)\n' >&2
    exit 2
fi

if ! source_dir="$(cd -- "$(dirname -- "$0")" && pwd)"; then
    printf 'UNKNOWN: could not locate the probe source\n' >&2
    exit 2
fi
if ! build_dir="$(mktemp -d "${TMPDIR:-/tmp}/apple-pv-detector.XXXXXX")"; then
    printf 'UNKNOWN: could not create a temporary build directory\n' >&2
    exit 2
fi
trap 'rm -f -- "$build_dir/probe"; rmdir -- "$build_dir"' EXIT

if ! xcrun swiftc -O -target arm64-apple-macos11.0 -framework Metal "$source_dir/probe.swift" -o "$build_dir/probe"; then
    printf 'UNKNOWN: could not build the probe\n' >&2
    exit 2
fi
if "$build_dir/probe"; then
    exit 0
else
    result=$?
    case "$result" in
        1|2) exit "$result" ;;
        *) printf 'UNKNOWN: probe could not run successfully (exit %s)\n' "$result" >&2; exit 2 ;;
    esac
fi
