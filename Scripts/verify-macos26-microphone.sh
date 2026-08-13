#!/usr/bin/env bash
set -euo pipefail

source_file="PlayTools/Controls/PTFakeTouch/NSObject+Swizzle.m"
settings_file="PlayTools/PlaySettings.swift"

test -f "$source_file"
test -f "$settings_file"
rg -q '#import <AVFAudio/AVAudioApplication.h>' "$source_file"
rg -q 'hook_requestRecordPermissionWithCompletionHandler:' "$source_file"
rg -q 'requestRecordPermissionWithCompletionHandler:' "$source_file"
rg -q 'AVAudioApplicationRecordPermissionGranted' "$source_file"
rg -q 'AVAudioApplicationRecordPermissionDenied' "$source_file"
rg -q 'AVAudioSessionRecordPermissionGranted' "$source_file"
rg -q 'swizzleClassMethod:applicationRequestSelector' "$source_file"
rg -q 'Bundle\.main\.bundlePath' "$settings_file"
rg -q '/Library/Containers/io\.playcover\.PlayCover/' "$settings_file"

echo "macOS 26 microphone compatibility checks passed"
