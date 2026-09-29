# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses
[semantic versioning](https://semver.org/spec/v2.0.0.html). The version is read
from `metadata.json`, and pushing a `v*` tag builds and attaches the
`.plasmoid`, `.deb` and `.rpm`.

## [Unreleased]

### Fixed

A top-to-bottom audit found a lot of these, and a few of them are severe enough
to lead with. The test suite was fully green throughout: the failures below were
in paths no test drove.

**Stale data was reported with the wrong severity.** `UsageModel._applyUsage`
took a second argument meaning "this file could not be read", and the caller
passed `_provider.isStale` — "this file is old" — to it. Every file the
collector had stopped updating therefore took the unreadable branch,
`TimeUtils.getStatus()` was never called, and the status came out as `sleeping`
or `offline` regardless of the numbers: a **stale 99%** drew a blue bar and read
"Waiting for a limit to reset". Staleness is still reported, through the
"Usage data is stale" note and the "N minutes ago" line; it just no longer
decides severity. `UsageModel` had no test suite of its own, which is how this
survived — it is the only component that decides severity. `tests/tst_model.qml`
now covers it, driving a real file read rather than calling `_applyUsage()`
directly, because a suite that calls it with a literal passes with the bug
still in place.

**A badge could be filed under the wrong account.** The accounts page reads one
usage file per account in sequence to show plan badges, recording which row the
read in flight belongs to. Editing the list restarted the sweep while a read
was still in flight, resetting that row marker and the position counter
underneath it, so the straggling result was stored against whichever account
had taken its place. A generation counter now drops results from a superseded
sweep.

**Badges read "unknown" for a customized usage path.** Plasma assigns the
General page's `cfg_*` values around construction, and the badge sweep read the
base path once, when the account list landed. A path assigned after that was
never used, so every badge was answered from the default directory until the
dialog was reopened — for exactly the user the setting exists for.

**Ten file reads a minute to discover nothing.** The collector re-read
`accounts.json` on every pass of the poll loop: once to classify it, once more
to load it, and once more per account building a scoped-limits cache that was
then discarded because nothing had changed. A single `stat` now short-circuits
the common case.

**The Accounts settings page could destroy your account list.** The page
instantiated its `AccountList` with no `Component.onCompleted: refresh()`, so
the read was never started, the working copy stayed empty, and pressing OK
wrote `{"accounts": []}` over `accounts.json`. Both halves then read that as
"no accounts" and fell back to `~/.claude` — silently, with a journal line only.
`save()` is now gated on a read having actually completed, so an unread list can
never be written back as an empty one.

**"Add folder…" could not add anything.** It runs `test -f`, which exits 0 and
prints nothing, and the one-shot reader treated empty output as failure by
default. A valid folder was reported as having no `.credentials.json` and the
code that adds the account never ran. The default is now the other way round —
a command's contract is its exit status — and only the two callers that really
read a document opt in.

**A spent limit could be pinged every ten seconds.** When a window's reset time
had already passed — a clock skew, a stale header — the wait clamped to exactly
the ten-second slack constant, which is below the collector's own 30-second
floor. It now waits at least `MIN_POLL_GAP`. A weekly limit has the same shape of
problem and it is the reason the collector stops polling at all.

**A malformed number could take an account offline.** `NaN` from a rate-limit
header passed every range check, was written into `usage.json` as a bare `NaN`
token — which is not JSON, and which the widget's parser rejects — and, because
every comparison against `NaN` is false, was also read as "limit spent", so the
collector slept for the whole window and a manual Refresh could not pull it out.
Refused at every layer now, ending at `json.dumps(..., allow_nan=False)`.

**The collector could delete Claude Code's own credentials.** When the
read-before-write of `.credentials.json` failed for any reason other than the
file being absent, the merge answered `{}` and rewrote the file, dropping
`mcpOAuth` and `organizationUuid`. A transient parse error — Claude Code caught
mid-write — was enough. An unreadable file is not an empty one now. Related: a
successful refresh whose *write* failed used to lose a token the server had
already rotated, which costs the user their login.

**Non-ASCII account ids silently split the two halves.** The collector
slugified with Python's `str.isalnum()`, which is Unicode-aware; the widget used
an ASCII-only regex. `café` became `café` in one and `caf` in the other, so the
panel watched a file the collector never wrote. Both sides now share one
fixture table, and the same table pins a 64-character cap: an over-long id
overflowed `NAME_MAX`, after which every write for that account failed and it
showed nothing for ever.

**A failed poll could stop the collector entirely.** The auth-error path wrote
its diagnostic with nothing around it, so an unwritable state directory plus one
expired login killed the process and every account with it — and
`Restart=on-failure` turned that into a 30-second loop. Also: an unwritable lock
file no longer raises out of startup.

**The collector's service state could freeze for a whole session.** The three
`systemctl` calls used raw data sources with neither the coalescing nor the
watchdog that the rest of the widget has, so one lost callback held a source
name forever, and the refresh and prime calls went on reporting success —
permanently disarming session priming — with nothing said.

### Added

- `usage.json` carries an optional `account` key. The filename follows the
  account's *position* in the list, so reordering moves a filename between
  accounts for a poll interval; this key does not, and the widget refuses a
  file that names a different account rather than drawing it. Files without the
  key are unaffected.
- The panel and popup now re-read `accounts.json` on their own slow cadence and
  when the popup opens, so an account added in the settings shows up without
  restarting plasmashell. An unchanged re-read costs nothing.
- The popup distinguishes **"Waiting for a limit to reset"** from **"Collector
  Offline"**. The collector deliberately stops polling a spent window for hours;
  that was indistinguishable from a crash, and the grey dot was the only
  feedback.
- The popup now shows *why* a file could not be read, and whatever `systemctl`
  last reported. Both were computed and then never displayed.
- CI runs the collector's selftest on Python 3.9, 3.11 and 3.14, and lints it
  with ruff. The collector declares only "python3", so the oldest interpreter
  anyone is likely to run is part of the contract — and it was not for a long
  time: the daemon's own `…Z` timestamps were unreadable by
  `datetime.fromisoformat` before 3.11, and every reset time failing to parse
  silently degraded the whole go-quiet-until-reset design to a one-hour backoff.
- CI regenerates the translation template and fails when the committed one has
  drifted. Nothing enforced `docs/i18n.md`'s extraction command, so a new
  user-facing string written as a bare literal passed every check in the
  repository and never reached a translator.

### Changed

- Account ids are lowercased and reduced to ASCII letters and digits on both
  sides, and capped at 64 characters. An install with a hand-edited
  `accounts.json` whose id contained non-ASCII characters will see that account
  write to a differently-named file; the old one is left in place, unread.
- The popup's one-second countdown clock and each account's ten-second
  "updated" timer now run only while the popup is open. They were running
  inside plasmashell all day, driving bindings for a closed window.
- Poll jitter is a per-account offset in that account's own schedule rather than
  added to the collector's shared sleep, which had stretched every effective
  interval to 60–75s against a documented 60s.
- `OneShotReader` caps a single read at 1 MiB and refuses it as a named failure
  rather than handing back half a document to parse.
- State files are written 0600 in a 0700 directory, and the rename is followed
  by a directory fsync. Without it a crash can revert a rotated token to the
  copy the server has already invalidated.
- The collector refuses HTTP redirects outright. Python's default redirect
  handler copies `Authorization` across a 3xx.
- `docs/architecture.md` no longer claims the plasma5support dependency is
  confined to two files (it is three, all reached through `OneShotReader`), and
  several other claims that the code did not support have been corrected.

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
