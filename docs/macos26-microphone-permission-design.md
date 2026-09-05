# macOS 26 Microphone Permission Compatibility

## Problem

PlayTools currently synchronizes the legacy `AVAudioSession` microphone
permission callback. On macOS 26, the supported application-level permission
API is `AVAudioApplication`, so games that reach the newer API—or games whose
legacy request is bridged through the newer API—can report a denied permission
without creating a TCC request for the translated app.

## Design

Keep the existing opt-in `checkMicPermissionSync` behavior and extend it at the
PlayTools boundary:

1. Add a class-method hook for
   `AVAudioApplication.requestRecordPermissionWithCompletionHandler:`.
2. When the new API is available, make the legacy
   `AVAudioSession.requestRecordPermission:` hook use the new API as its
   authorization source. A granted or denied state is returned synchronously;
   an undetermined state is forwarded to the real
   `AVAudioApplication.requestRecordPermissionWithCompletionHandler:` request
   so macOS can update TCC and invoke the game callback.
3. Keep the existing `AVAudioSession` fallback for older runtimes where
   `AVAudioApplication` is unavailable.
4. Install both hooks only when `checkMicPermissionSync` is enabled, matching
   the existing per-app opt-in behavior.

The hook does not fabricate permission. It delegates the decision to Apple's
permission API and only normalizes an already-determined result to synchronous
callback behavior required by affected games.

## Verification

- A source-level regression script checks that the new API header, hook,
  fallback, and registration are all present.
- The PlayTools Xcode project is built with the current macOS 26 SDK.
- The resulting framework is inspected for the new selectors and its
  signature is verified after Catalyst conversion.
