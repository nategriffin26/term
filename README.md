# Term

Term is a terminal for iPhone. It speaks mosh and SSH, keeps your tmux sessions one swipe away, and lets you work on the remote machine's files without leaving the app.

<p align="center">
  <img src="docs/screens-terminal.png" alt="Term on iPhone: vim and cargo test in a tmux session, the Sessions overview, and the Files tab in a Rust project">
</p>

Term takes [Blink Shell](https://blink.sh) as its model and rebuilds it on [Ghostty](https://ghostty.org)'s terminal engine, with a mosh client written from scratch in Rust.

## What it does

- **mosh that survives iOS.** Local echo prediction, roaming between Wi-Fi and cellular, and sessions that come back after iOS kills the app in the background.
- **SSH** with Ed25519 keys made or imported in the app. Host keys are pinned on first use.
- **tmux, native.** A session picker, a scrollable history viewer, a Mission Control style overview (three fingers up), and a swipe between sessions that names where you're going.
- **Reconnect in place.** When a tmux session's mosh-server dies, Term starts a new one and swaps it in under the same screen. Nothing to tap.
- **Files on the host**, over SFTP: git status in the listing, search, upload and download, a code editor with syntax highlighting, and viewers for Markdown, images, PDF and video. Saves check that nobody changed the file on the host first.
- **A floating menu** for Sessions, Files and Settings: double-tap ⌘ on the Smart Keys bar, or tap with three fingers.
- **Smart Keys** for Esc, Ctrl, Alt, symbols and arrows, with configurable key repeat.
- **Pinch to resize.** JetBrains Mono and Iosevka Nerd Fonts are built in.
- **iPhone Duo layouts** for both displays, two windows side by side, and a menu dock in the inner display's status band.

<p align="center">
  <img src="docs/screens-files.png" alt="Swiping between tmux sessions, a Rust file in the code viewer, and a README rendered from the host">
</p>

<p align="center">
  <img src="docs/screens-duo.png" alt="Term on the iPhone Duo's inner display: two tmux sessions side by side under the menu dock in the status band, and the Sessions panel opened from the dock">
</p>

## How it works

The app is Swift and UIKit with its own Metal renderer. Everything that touches the network or the terminal state lives in a Rust core. The two meet in one C header, [`term.h`](core/termcore/include/term.h), and nothing else crosses.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/architecture-dark.svg">
    <img src="docs/architecture-light.svg" width="640" alt="The Swift app talks to the Rust core through term.h. The core holds termcore, vt (libghostty-vt), mosh and ssh. mosh reaches mosh-server over UDP, ssh reaches sshd over TCP 22, and mosh-server runs tmux on the host.">
  </picture>
</p>

`vt` wraps libghostty-vt, Ghostty's terminal emulator as a library, built from a pinned Ghostty commit with Zig. Swift never calls it. The core resolves every cell's colors and hands the app a flat frame to draw.

`mosh` is a sans-IO client for the mosh 1.4 protocol: time and datagrams go in, datagrams come out. That shape is why the same code can run in unit tests, against a real mosh-server, and under a model checker.

`ssh` is [russh](https://github.com/Eugeny/russh). It starts mosh-server, runs the commands behind the tmux picker and history, and carries SFTP for Files.

tmux on the host is the session store. Term doesn't replace it. The phone lists sessions with `tmux list-sessions`, reads history with `tmux capture-pane`, and attaches with `tmux new -A -s NAME`, so the same sessions open on the phone and on the computer.

### Connecting

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/connect-dark.svg">
    <img src="docs/connect-light.svg" width="640" alt="Term opens SSH, starts mosh-server with the startup command, reads MOSH CONNECT with a port and key, then talks to the server over encrypted UDP. After a network change, the next packet re-homes the server.">
  </picture>
</p>

SSH only starts the server. From then on it's encrypted UDP, and the server follows the phone to whatever address its packets come from next.

mosh-server exits on its own after a day without hearing from the phone when the session lives in tmux, and after a week for a plain shell. Inside tmux nothing is lost when it goes, and Term reconnects in place the next time you look.

### Surviving iOS

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/lifecycle-dark.svg">
    <img src="docs/lifecycle-light.svg" width="640" alt="When the app goes to the background, Term stops the network and saves a checkpoint. If iOS kills the app, the next launch reads and deletes the checkpoint and resumes on a new socket. When the server goes silent, Term probes the host and reconnects in place with a new mosh-server.">
  </picture>
</p>

iOS suspends background apps and kills them when it needs the memory. So when Term goes to the background, it stops the network and writes each mosh session's protocol state to disk. On the next launch it reads the checkpoint, deletes it, and resumes on a fresh socket with the same mosh-server.

The order matters, and it's where the bugs hide: a reused encryption nonce, or a checkpoint that names a server a reconnect already ended. So that part is formally checked, below.

The other path handles a server that's gone. Once a session has been silent for about 6 seconds, Term probes the host over SSH. If the host answers, it starts a new mosh-server and ends the old one, and you're back in the same tmux session. In the simulator, after `kill -9` on the server, the session came back on its own, without a tap.

## Build

You need Xcode 27.1 (the iOS 27.1 SDK has the iPhone Duo APIs), Rust with the iOS targets, and [XcodeGen](https://github.com/yonaskolb/XcodeGen). The Ghostty step downloads its own pinned Zig.

```sh
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
brew install xcodegen
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

scripts/build-core.sh          # libghostty-vt (pinned Ghostty + Zig, ~2.5 min the first time, then cached)
                               # and the Rust core -> build/TermCore.xcframework
cd app && xcodegen generate
```

Simulator builds need no signing:

```sh
xcodebuild -project Term.xcodeproj -scheme Term \
  -destination 'platform=iOS Simulator,name=<simulator name>' build
```

To install on a phone, put your bundle ID and team in `app/Config/Local.xcconfig`. It's git-ignored, and [`Signing.xcconfig`](app/Config/Signing.xcconfig) includes it:

```
TERM_BUNDLE_ID = com.yourname.term
DEVELOPMENT_TEAM = ABCDE12345
```

Then build, install and launch:

```sh
xcodebuild -project Term.xcodeproj -scheme Term -destination 'generic/platform=iOS' \
  -derivedDataPath ../local/DerivedDataDevice build
xcrun devicectl device install app --device <udid> ../local/DerivedDataDevice/Build/Products/Debug-iphoneos/Term.app
xcrun devicectl device process launch --device <udid> com.yourname.term
```

The computer you connect to needs `mosh-server` (mosh 1.4) on its PATH or in Homebrew's usual place. tmux is optional, but it's what makes sessions shared and reconnects seamless.

## Tests and formal checks

```sh
cd core && cargo test --workspace          # includes runs against a real sshd and mosh-server on 127.0.0.1
cd app && xcodebuild test -project Term.xcodeproj -scheme Term \
  -destination 'platform=iOS Simulator,name=<simulator name>'
python3 formal/mosh-resume.py              # TLA+ models, about 20 s
python3 formal/mosh-fragment.py fallback   # property tests, about 2 s (25 s on a cold build)
```

`mosh-resume.py` runs two TLA+ models with TLC. The first checks that suspend, save, kill and restore, run twice with lost, duplicated and reordered packets within small bounds, never reuses an encryption nonce or loses the state needed to apply the server's next update. The second checks that a reconnect racing a suspend never leaves a checkpoint pointing at a server it ended. Before TLC runs, the script executes a probe against the real mosh crate and checks fingerprints of the Rust functions the models describe, so a model can't quietly drift from the code. It needs Java 21 and downloads a checksum-pinned TLC.

`mosh-fragment.py fallback` runs property tests on the real fragment reassembly code: arbitrary bytes never panic, and fragments in any order, duplicated, reassemble to exactly the original. These are sampled checks, not an exhaustive proof. An attempt with Kani timed out.

Both checks were seen to fail on deliberate bugs planted in a scratch copy of the code. The details, bounds and assumptions are in [`.omp/skills`](.omp/skills).

## Status

Term is installed and tested end to end on an iPhone 11. A few things are not proven yet:

- There is no App Store or TestFlight build. You build it yourself.
- iPhone Duo layouts are verified in the simulator, not on Duo hardware.
- Roaming between networks is covered by the formal model and the interop tests, not by long field use on cellular.
- Composed input (CJK, dead-key accents) is untested.

## Layout

```
app/                    Swift app (UIKit + Metal), XcodeGen project in project.yml
  Sources/Terminal      renderer, input, gestures, Smart Keys
  Sources/Shell         tabs, hosts, keys, tmux picker and history, reconnect
  Sources/Menu          floating menu, Sessions overview, swipe HUD
  Sources/Files         SFTP browser, viewers, editor
core/                   Rust workspace
  termcore              C ABI (include/term.h), sessions, tokio runtime, SFTP
  vt                    libghostty-vt wrapper
  mosh                  sans-IO mosh 1.4 client
  ssh                   russh client, mosh bootstrap
formal/                 TLA+ models and runners, fragment property tests
scripts/                ghostty-vt.sh, build-core.sh
docs/                   README images
```

## Credits

- [Blink Shell](https://blink.sh), the iOS terminal Term takes its look and gestures from.
- [Ghostty](https://github.com/ghostty-org/ghostty) for libghostty-vt (MIT).
- [mosh](https://mosh.org), the protocol and the server Term talks to (GPL-3.0).
- [russh](https://github.com/Eugeny/russh) and [russh-sftp](https://github.com/AspectUnk/russh-sftp) (Apache-2.0).
- [Runestone](https://github.com/simonbs/Runestone) and [TreeSitterLanguages](https://github.com/simonbs/TreeSitterLanguages) for the editor, on [tree-sitter](https://tree-sitter.github.io) (MIT).
- [swift-cmark](https://github.com/swiftlang/swift-cmark) for Markdown (BSD-2-Clause).
- [JetBrains Mono](https://github.com/JetBrains/JetBrainsMono) and [Iosevka](https://github.com/be5invis/Iosevka) as patched by [Nerd Fonts](https://www.nerdfonts.com) (SIL OFL 1.1; licenses in [`app/Resources/Fonts`](app/Resources/Fonts)).
- [Geist and Geist Mono](https://github.com/vercel/geist-font) for the app's chrome (SIL OFL 1.1; license in [`app/Sources/Menu/Fonts`](app/Sources/Menu/Fonts)).

## License

[MIT](LICENSE)
