#!/bin/zsh
# Runs the Swift tests and the TypeScript checks. Works with Xcode or with just the Command Line Tools
# (which ship Swift Testing outside the default search paths).
set -euo pipefail
cd "$(dirname "$0")"
bun check src/typescript/index.ts
bun fmt --check .
swift format lint --strict -r src/swift tests/swift
# Only when the Command Line Tools are the active toolchain: Xcode's has its own Swift Testing, and mixing in the
# Command Line Tools' copy breaks the test macros (`module 'Testing' has no member named '__SourceBounds'`).
CLT=/Library/Developer/CommandLineTools
DEV="$CLT/Library/Developer"
FLAGS=()
[[ "$(xcode-select -p 2>/dev/null)" == "$CLT" && -d "$DEV/Frameworks/Testing.framework" ]] && FLAGS=(
  -Xswiftc -F -Xswiftc "$DEV/Frameworks" -Xlinker -F -Xlinker "$DEV/Frameworks"
  -Xlinker -rpath -Xlinker "$DEV/Frameworks" -Xlinker -rpath -Xlinker "$DEV/usr/lib"
)
swift test "${FLAGS[@]}" 2>&1 | grep -E "✔|✘|error:|Test run"
