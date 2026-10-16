#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

swiftc -swift-version 5 \
    "$repo_root/PlayTools/AppSettingsData.swift" \
    "$repo_root/PlayTools/DiscordActivity/DiscordActivity.swift" \
    "$repo_root/Tests/SettingsDecodingTests.swift" \
    -o "$test_dir/settings-tests"
"$test_dir/settings-tests"
