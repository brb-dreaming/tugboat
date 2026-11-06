#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
# Exercise the app's definitions without launching its menu bar entry point.
awk '/^\/\/ MARK: - Headless mode/ { exit } { print }' Tugboat.swift > "$work_dir/Tugboat.swift"
swiftc -O -parse-as-library -o "$work_dir/tests" \
    "$work_dir/Tugboat.swift" RegressionTests.swift -framework Cocoa -framework SwiftUI -framework Combine
"$work_dir/tests"
