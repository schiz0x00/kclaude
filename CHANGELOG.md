# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses
[semantic versioning](https://semver.org/spec/v2.0.0.html). The version is read
from `metadata.json`, and pushing a `v*` tag builds and attaches the
`.plasmoid`, `.deb` and `.rpm`.

## [Unreleased]

### Changed

- The collector reads usage from the `anthropic-ratelimit-unified-*` headers on
  a tiny `/v1/messages` ping instead of polling `/api/oauth/usage`. That
  endpoint has an account-wide quota of roughly one call every two minutes and
  returned `429` for hours once drained, which a five-minute poll did reliably.
  A ping costs 8 input and 1 output token of Haiku, so the poll interval drops
  from 300s to 60s. The usage endpoint remains as the fallback.
- The collector identifies itself as `claude-cli`, with the version read from
  the installed Claude Code at startup.

### Added

- The collector stops sending entirely when a window reaches 100%, and waits
  for that window's reset rather than retrying into a refusal. A manual refresh
  cannot shorten the wait.
- `scripts/build-packages.sh` builds `dist/kclaude-<version>.plasmoid`, so the
  KDE Store artifact is reproducible instead of zipped by hand. It is built
  before the `nfpm` step and needs no Go toolchain.
- Screenshots of every widget state, under `docs/screenshots/`.

### Fixed

- The icon now resolves inside the package. `metadata.json` declared
  `Icon: kclaude` while the file was `contents/icons/claude.svg`; the `.deb` and
  `install.sh` both hid this by copying it into the icon theme, so only store
  installs — which copy nothing — showed a placeholder in Add Widgets.
- A ping that returns `200` with no rate-limit headers now falls back to the
  usage endpoint instead of leaving the widget frozen behind a growing backoff.

## [1.1.0] - 2026-07-30

First tagged release. Attached a `.deb` and an `.rpm`.

### Added

- Compact panel indicator with a colour-coded status dot, and a popup with a
  progress bar and reset countdown per window.
- Configurable warning and critical thresholds, compact display mode, refresh
  interval, and usage file path.
- Optional collector daemon (`systemd --user`), with single-instance locking,
  token refresh, and exponential backoff.
- Optional session priming: opens the next five-hour window the moment the
  previous one resets.
- `.deb` and `.rpm` packaging, install and uninstall scripts, and CI covering
  the daemon selftest, the QML suites, shellcheck and the package layout.

[Unreleased]: https://github.com/schiz0x00/kclaude/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/schiz0x00/kclaude/releases/tag/v1.1.0
