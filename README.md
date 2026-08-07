# dart_terminal (Antgrid fork)

[![Analyze](https://github.com/bharathm03/dart_terminal/actions/workflows/analyze.yml/badge.svg)](https://github.com/bharathm03/dart_terminal/actions/workflows/analyze.yml)
[![VTE](https://github.com/bharathm03/dart_terminal/actions/workflows/vte.yml/badge.svg)](https://github.com/bharathm03/dart_terminal/actions/workflows/vte.yml)
[![PTY](https://github.com/bharathm03/dart_terminal/actions/workflows/pty.yml/badge.svg)](https://github.com/bharathm03/dart_terminal/actions/workflows/pty.yml)

> **This is a fork of [kingwill101/dart_terminal](https://github.com/kingwill101/dart_terminal),**
> branched at `d9d3096` and maintained for Antgrid. **Use upstream unless you
> need one of the changes below.** Issues and pull requests here are triaged on
> Antgrid's schedule; no support is promised to anyone else.
>
> Prebuilt native libraries still come from **upstream's** releases — this fork
> publishes none of its own, and the downloaders in `tool/` and each package's
> `bin/setup.dart` point at `kingwill101/dart_terminal` by design.

### What's different from upstream

- **`ghostty_vte` — regenerated FFI bindings.** Published 0.1.4 shipped bindings
  generated before the vendored ghostty submodule was bumped, so
  `GhosttyFormatterTerminalOptions` is missing its trailing `selection` field.
  The C API passes that struct **by value**, so the callee reads the absent field
  from uninitialised heap, takes the branch, and builds a selection from wild
  pointers — the formatter segfaults on every call. This also adds the
  `ffigen.yaml` that was never checked in, which is why the bindings drifted at
  all. **Affects every 0.1.4 consumer, not only Antgrid.**
- **`ghostty_vte_flutter` — Antgrid's terminal engine and rendering patches.**

### What a green VTE badge does and doesn't mean

`VTE / test-flutter` builds no native library and downloads no prebuilt one, so
`flutter_tester` never resolves this package's native assets and every
engine-backed test is inert there. Most of them look green because they guard
with an early `return` *inside the test body*, which reports **passed**, not
skipped. The engine is genuinely exercised only by `dart test` in
`pkgs/vte/ghostty_vte`, which CI does not run — `test-native` is `if: false`
upstream. Run it locally before trusting a change to the bindings.

New tests here use `skip:` instead, so the same absence reports as skipped and
the count stays honest.

Dart & Flutter packages for building terminal applications. This monorepo
provides two complementary package groups — a **VT engine** powered by
[Ghostty](https://github.com/ghostty-org/ghostty) and a **cross-platform
PTY** backed by Rust — that together give you everything needed to embed a
fully functional terminal in any Dart or Flutter app.

## Packages

| Package | pub.dev | Description |
|---------|---------|-------------|
| [`ghostty_vte`](pkgs/vte/ghostty_vte/) | [![pub](https://img.shields.io/pub/v/ghostty_vte.svg)](https://pub.dev/packages/ghostty_vte) | Dart FFI bindings for Ghostty's VT engine — paste safety, OSC/SGR parsing, key encoding |
| [`ghostty_vte_flutter`](pkgs/vte/ghostty_vte_flutter/) | [![pub](https://img.shields.io/pub/v/ghostty_vte_flutter.svg)](https://pub.dev/packages/ghostty_vte_flutter) | Flutter terminal widgets + wasm initialiser |
| [`portable_pty`](pkgs/pty/portable_pty/) | [![pub](https://img.shields.io/pub/v/portable_pty.svg)](https://pub.dev/packages/portable_pty) | Cross-platform PTY — native shells on desktop, WebSocket/WebTransport on web |
| [`portable_pty_flutter`](pkgs/pty/portable_pty_flutter/) | [![pub](https://img.shields.io/pub/v/portable_pty_flutter.svg)](https://pub.dev/packages/portable_pty_flutter) | Flutter `ChangeNotifier` controller for PTY sessions |

The pub.dev badges track **upstream's** published versions. This fork is not
published to pub.dev — consume it as a git dependency.

## Quick start

```bash
git clone https://github.com/bharathm03/dart_terminal.git
cd dart_terminal
git submodule update --init --recursive
flutter pub get
```

### Run the VTE tests

```bash
cd pkgs/vte/ghostty_vte
dart test
```

### Run the PTY example

```bash
cd pkgs/pty/portable_pty
dart run example/pty_example.dart
```

### Run the Flutter example

```bash
cd pkgs/vte/ghostty_vte_flutter/example
flutter run
```

## Prerequisites

| Tool | Required for | Install |
|------|-------------|---------|
| **Dart SDK ≥ 3.10** | All packages | [dart.dev/get-dart](https://dart.dev/get-dart) |
| **Flutter** | Flutter packages & examples | [flutter.dev](https://flutter.dev/docs/get-started/install) |
| **Zig ≥ 0.15** | Building `libghostty-vt` | [ziglang.org/download](https://ziglang.org/download/) |
| **Rust ≥ 1.92** | Building the PTY library | [rustup.rs](https://rustup.rs/) |

> **Don't want to install Zig or Rust?** Download
> [prebuilt libraries](https://github.com/kingwill101/dart_terminal/releases)
> for your platform — the build hooks will use them automatically.
>
> ```bash
> dart run tool/prebuilt.dart --tag v0.0.2
> ```

### Prebuilt assets for downstream consumers

When `ghostty_vte` or `portable_pty` are consumed from **pub.dev**, you don't
need Zig or Rust installed — each package ships a setup command that downloads
the correct prebuilt library for your platform:

```bash
dart run ghostty_vte:setup
dart run portable_pty:setup
```

This places the native libraries in `.prebuilt/<platform>/` at your project
root, where the build hooks find them automatically.

The build hooks search for prebuilt libraries in this order:

1. **Environment variable** — `GHOSTTY_VTE_PREBUILT` / `PORTABLE_PTY_PREBUILT`
   pointing directly to the `.so` / `.dylib` file.
2. **Monorepo `.prebuilt/`** — `.prebuilt/<platform>/<lib>` at the monorepo
   root (found by walking up looking for `pubspec.yaml` + `pkgs/`).
3. **Project `.prebuilt/`** — `.prebuilt/<platform>/<lib>` at your project
   root (derived from the build system's output directory). **This is the
   recommended approach for downstream consumers.**

You can also specify a release tag or target platform:

```bash
dart run ghostty_vte:setup --tag v0.0.2 --platform macos-arm64
dart run portable_pty:setup --tag v0.0.2 --platform macos-arm64
```

Platform labels follow the pattern `{os}-{arch}`:
`linux-x64`, `linux-arm64`, `macos-arm64`, `macos-x64`, `windows-x64`, etc.

> **Tip:** Add `.prebuilt/` to your `.gitignore` — these are binary artifacts
> that should be downloaded as needed, not committed.

## Architecture

```
dart_terminal/
├── pkgs/
│   ├── vte/                        # Terminal VT engine
│   │   ├── ghostty_vte/            # Core Dart FFI bindings
│   │   └── ghostty_vte_flutter/    # Flutter widgets & controllers
│   └── pty/                        # Pseudo-terminal
│       ├── portable_pty/           # Core PTY library (Rust FFI + web transport)
│       └── portable_pty_flutter/   # Flutter ChangeNotifier controller
└── tool/
    └── prebuilt.dart               # Download prebuilt native libraries
```

## License

MIT — see [LICENSE](LICENSE). Upstream's copyright is retained alongside this
fork's; both notices must survive in any copy.

The vendored Ghostty source under
`pkgs/vte/ghostty_vte/third_party/ghostty/` is separately MIT-licensed by
Mitchell Hashimoto and the Ghostty contributors, and carries its own `LICENSE`.
