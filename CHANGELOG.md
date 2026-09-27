# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses
[semantic versioning](https://semver.org/spec/v2.0.0.html). The version is read
from `metadata.json`, and pushing a `v*` tag builds and attaches the
`.plasmoid`, `.deb` and `.rpm`.

## [Unreleased]

## [1.2.0] - 2026-09-27

**Several accounts at once**, and a collector that reads usage from the
rate-limit headers on its own ping instead of the scarce usage endpoint.

Upgrading needs nothing. With no `accounts.json` present — which is exactly what
every install from 1.1.0 has — the widget shows the single `~/.claude` account it
always did, now polled every 60s instead of every 300s.

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

- **Several accounts at once.** A new **Accounts** settings page takes a list of
  Claude config directories — *Scan home folder* finds `~/.claude*`, *Add
  folder…* takes any path and checks it for a `.credentials.json` — and the
  collector polls each one on its own schedule with its own token, rate-limit
  budget and backoff, so a dead login or an hour-long backoff on one leaves the
  others updating. The panel lists every account's five-hour window at once
  (`82% · 0%`); the popup gives each a section with its own bars, plan badge,
  countdowns and login errors. The list lives in `~/.config/kclaude/accounts.json`
  and is re-read every poll, so a change takes effect within a minute with no
  restart. A missing file resolves to the single `~/.claude` account, so an
  existing install needs no configuration.
  - An entry with a missing or non-string `path` is dropped rather than
    defaulted to `~/.claude`: showing one account's numbers under another's
    name is the one failure this list cannot have. Duplicate ids are dropped,
    and ids are slugged identically on both sides, so two accounts can never
    share a state file. Both sides cap the list at 8.
  - The collector publishes each account's `plan` (`max`, `pro`, …) in its usage
    file, shown as a badge next to the account name in the popup and in the
    Accounts page. The widget and the settings dialog therefore never read a
    credentials file at all; a folder is checked with `test -f` and nothing
    more. A pro account cannot have a per-model weekly budget, so the scarce
    usage-endpoint call is skipped for one entirely, and a plan downgrade drops
    the window it had instead of leaving a phantom bar.
  - Priming covers every account whose five-hour window has expired, each under
    its own hourly ceiling. `SIGUSR2` carries no payload, so the widget passes
    the earliest reset across all accounts and the collector primes all of them;
    per-account stamps keep one account's prime from consuming another's
    allowance.
- The Fable weekly budget now shows as its own window, automatically, on the
  plans that have one (Max). It is not on the `anthropic-ratelimit-unified-*`
  headers the poll reads — verified against a live Max-plan response, which
  carries `5h` and `7d` and nothing else — so it comes off the usage endpoint's
  `limits[]` instead, read at one call per 30 minutes with exponential backoff
  and cached across restarts. A window read that way carries its own
  `updatedAt`, and the popup says how old it is rather than drawing a
  half-hour-old number as if it were live.
- The collector stops sending entirely when a window reaches 100%, and waits
  for that window's reset rather than retrying into a refusal. A manual refresh
  cannot shorten the wait.
- `scripts/build-packages.sh` builds `dist/kclaude-<version>.plasmoid`, so the
  KDE Store artifact is reproducible instead of zipped by hand. It is built
  before the `nfpm` step and needs no Go toolchain.
- Screenshots of every widget state, under `docs/screenshots/`.

### Fixed

- The popup's reset countdowns now tick. `TimeUtils.formatResetTime()` reads the
  clock inside a plain JS function, which QML cannot register a dependency on,
  so every "Resets in …" was computed once per model update and then froze — a
  reset that had already passed kept counting down at its last value for up to a
  full refresh interval. The popup is where this was visible: the panel shows no
  countdown and the tooltip's is a parenthetical.
- A read that never completes no longer freezes the widget forever. If
  `onNewData` does not arrive, the source name stays held by the engine and
  every later refresh is silently dropped, leaving the panel on its last numbers
  with nothing to show that anything is wrong. A watchdog now forces the name
  loose and says so.
- A refresh is no longer lost when it lands while another read is in flight. The
  executable dataengine keys its sources by name, and `connectSource()` on a
  name it already holds returns without running anything — measured on the real
  engine, a second connect during a `cat` runs the process zero extra times.
  Refreshes now coalesce onto one trailing read instead, which loses nothing
  because the file is read when the process runs.
- A successful prime now updates the file, using the rate-limit headers on the
  prime's own reply, instead of leaving the pre-prime numbers up. The numbers on
  screen were 100% for up to five hours after the window had actually reopened.
- A prime also cancels the wait it just made obsolete. The loop used to sleep
  out the rest of the "limit reached, quiet until reset" wait even though the
  prime is exactly what un-exhausted that window — and the widget's Refresh
  button was subject to the same wait, so it could report success and change
  nothing.
- A ping that returns `200` with no rate-limit headers now falls back to the
  usage endpoint instead of leaving the widget frozen behind a growing backoff.
- The icon now resolves inside the package. `metadata.json` declared
  `Icon: kclaude` while the file was `contents/icons/claude.svg`; the `.deb` and
  `install.sh` both hid this by copying it into the icon theme, so only store
  installs — which copy nothing — showed a placeholder in Add Widgets.
- A boolean is no longer accepted as a utilization percentage. `true` is an
  `int` in Python, so `utilization: true` became 1%.

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

[Unreleased]: https://github.com/schiz0x00/kclaude/compare/v1.2.0...HEAD
[1.2.0]: https://github.com/schiz0x00/kclaude/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/schiz0x00/kclaude/releases/tag/v1.1.0
