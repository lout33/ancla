#!/bin/bash
# Build and run the rule checks for the scheduling logic.
# Usage: ./test.sh
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
swiftc src/Store.swift src/Scheduler.swift src/Overlay.swift src/Media.swift \
       tests/RulesTests.swift -o build/rules-tests
build/rules-tests
