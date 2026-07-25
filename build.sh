#!/bin/bash
# Build the Tugboat menubar app. Single-file swiftc, same as claude_monitor.
set -e
cd "$(dirname "$0")"
swiftc -O -o Tugboat Tugboat.swift \
    -framework Cocoa -framework SwiftUI -framework Combine
echo "built: $(pwd)/Tugboat"
