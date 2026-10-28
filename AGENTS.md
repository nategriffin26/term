# Working on Term

The README holds the build, test and layout details; this is the map.

- Toolchain: Xcode 27.1 (`export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`), Rust with the iOS targets, XcodeGen. `scripts/build-core.sh` builds `build/TermCore.xcframework` and must run before the app builds after a core change.
- The Xcode project is generated: edit `app/project.yml`, then `cd app && xcodegen generate`. Never edit `Term.xcodeproj`.
- Simulators: use the `Term …` simulators (`Term Duo` first, `Term iPhone` for a standard phone, `Term Tests` for the app tests), addressed by UDID or by name plus OS; shut down what you boot.
- Tests: `cd core && cargo test --workspace`; app tests with `xcodebuild test` on a `Term …` simulator (read the "Executed N tests" count); the formal checks and ScreenHost tests in the README's Tests section when you touch the code they cover.
- Installing on a phone: use the `ios-install` tool when the machine has it (its `ios-dev` skill covers devices and signing); otherwise the README's Build section.
- Device logs: the app logs its decisions (taps, swipes, keyboard, grid, menu, connections, voice, Screen, badges; never terminal text or input) to `Library/Logs/term.log` in its container. `scripts/pull-device-log.sh <device>` (or `$TERM_DEVICE`) copies it from an awake phone into `local/device-logs/` and prints the tail; on a simulator, read it under `xcrun simctl get_app_container <udid> <bundle id> data`.
- `local/` is git-ignored: ledgers, archives and build output go there, never in tracked paths.
