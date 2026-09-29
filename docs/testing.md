# Testing

Every suite runs without a display (`QT_QPA_PLATFORM=offscreen`); only
`tst_service.qml` needs a real systemd user session.

```bash
# node: no framework, plain scripts, non-zero exit on failure
node tests/shell-quote.test.js
node tests/accounts.test.js
node tests/package-layout.test.js

# python: the daemon tests itself
python3 daemon/kclaude-daemon --selftest

# QML: Qt's own engine and the real Plasma imports
for t in tests/tst_*.qml; do
    QT_QPA_PLATFORM=offscreen qmltestrunner -input "$t"
done

# static analysis
qmllint contents/ui/*.qml contents/code/*.qml contents/config/*.qml   # clean
shellcheck scripts/*.sh                                               # clean
```

On distros that do not put Qt 6 tools on PATH, they live in
`/usr/lib/qt6/bin/`.

## What each suite pins, and why it exists

| Suite | Pins | The bug it prevents |
| --- | --- | --- |
| `shell-quote.test.js` | `Shell.js` quoting, round-tripped through a **real bash**, plus injection payloads with a side-effect marker | the one user-configurable string that reaches a shell becoming an injection |
| `accounts.test.js` | the shared id table `tests/fixtures/slugs.json` — read here **and** by the daemon's `--selftest`, so the two implementations are pinned to each other rather than each to itself — plus `Accounts.js` label/filename rules, and the three `Shell.js` commands the accounts page runs (`writeFile`, `findConfigDirs`, `hasCredentials`) against a **real bash** and a real filesystem — including `printf` format-specifier payloads and a command-substitution marker check | the widget and the collector deriving different filenames from the same account id, so an account silently shows nothing; a `%` in a label eating the JSON; a config dialog's write going somewhere else |
| `package-layout.test.js` | config page lives in `contents/ui/` (Plasma resolves `ConfigCategory.source` there, not `contents/config/`); every `cfg_*` alias ↔ `main.xml` entry both ways **across all pages**; a page that writes its own file defines `save()`; scripts use the metadata id | silently blank config dialog; settings that save but never load; a page whose own file is never written because `save()` is missing; installer removing the wrong package |
| `kclaude-daemon --selftest` | the shared id table; total `iso()`/`parse_iso()` (including the `Z` form this file writes and a naive one); independent per-header parsing; non-finite and out-of-range utilizations refused at every layer, ending at `allow_nan=False`; the `MIN_POLL_GAP` floor on a spent window whose reset has passed; `poll_account` never raising with an unwritable state dir; the credential merge preserving `mcpOAuth` *and* the keys inside `claudeAiOauth`, refusing a damaged file and compare-and-swapping on a re-login; window normalization, token-expiry logic, `Retry-After` parsing, the exact `usage.json` key set, the scoped-window cache (parse, merge, backoff, persistence, plan downgrade, **pro skip**), credential merge-back, `AuthError` classification, `error`-key write/clear, the instance lock; **multi-account**: list parsing with a missing/corrupt/empty/capped file, per-account filenames, entries with no usable path dropped rather than defaulted, **credential isolation between two accounts**, per-account prime stamps, hot reload preserving pacing and scoped cache, reordering re-pointing filenames, `seconds_until_next` taking the minimum, `request_poll` not short-circuiting a backoff, and one account's `AuthError` not stopping the other | daemon and widget drifting apart on the file contract; a refresh eating Claude Code's own credentials; the scarce usage endpoint being hammered by the Fable poll; **one account's token written into another's credentials file, which logs both out of Claude Code**; a bad entry silently showing the default account's numbers under the wrong name; one account's backoff stalling the rest |
| `tst_provider.qml` | widget side of the file contract: a file whose `account` key names a different account is refused (the filename follows the account's *position*, so a reorder moves it), while a file with no such key is still accepted; `utilization` clamped at both ends; a non-JSON document rejected without poisoning the next good read; valid/malformed payloads, valid/malformed payloads, the `error` key (with and without windows), sanitization + caps, the Fable window's name, the per-window lag that a slow window reports, and the `plan` allow-list (including that a rejected payload leaves no plan behind) | a collector change blanking the panel; HTML-ish file content reaching a rich-text label; a half-hour-old number drawn as a live one; arbitrary text from a hand-written file drawn as a plan badge |
| `tst_model.qml` | the status roll-up, driven through a **real file read** rather than by calling `_applyUsage()` directly: a fresh file graded at every threshold boundary, a **stale-but-readable** file still graded at its own severity, an unreadable file being "sleeping" or "offline" by whether a window resets later, the limiting window being the highest, and no windows being "unknown" | `UsageModel` had no suite at all, and it is the only place severity is decided -- so a file the collector had simply stopped updating was passed to `_applyUsage()` as if it could not be read, the roll-up short-circuited into the offline branch, `getStatus()` was never called, and a stale **99%** drew a blue bar labelled "Waiting for a limit to reset" |
| `tst_accounts.qml` | `accounts.json` → the account list: a missing file resolving to the single default account, every unusable shape falling back to it, entries without a usable **string** path dropped, unusable ids dropped and valid ones slugged, duplicate ids dropped, the list capped at the collector's own 8, labels stripped of markup and length-capped, and the per-account usage paths | an upgrade breaking every existing install; one account silently showing the default account's numbers; two accounts sharing one usage file; a label fetching a remote URL from inside plasmashell |
| `tst_refresh.qml` | refresh **scheduling**, against the real executable dataengine: a burst of refreshes is coalesced to one trailing read rather than dropped, spaced refreshes are all honoured, a wedged read is recovered, a failed read does not wedge, an empty path never reaches a shell | the dataengine keys sources by name and `connectSource()` on a name it already holds runs nothing — so a refresh during a read is lost, and a source left connected blocks that name **forever**, freezing the widget on its last numbers |
| `tst_config.qml` | the page is a real `Kirigami.Page` pushed onto a real `PageRow`, renders controls, clamps values, exposes every `cfg_*` | the historical blank-config-page bug; qmllint cannot catch it |
| `tst_configaccounts.qml` | the page's **real read path**: a two-account file written through the page's own `save()` and read back by a page constructed with `accountsFilePath` as an initial property, plus the refusal to write back a list that was never read; the page is a real `Page` pushed onto a real `PageRow` and renders; the list-editing rules: duplicate folder refused, colliding ids made unique, the cap matches the collector's, reordering, removal, the derived usage paths lining up with what the collector writes, and **the General page's usage-file setting reaching this page** — a page that ignored it would show every plan badge as unknown while the accounts themselves polled and drew fine the **General page's usage-path setting re-probing the badges when it arrives after the account list has landed** (Plasma assigns `cfg_*` around construction, and the sweep read the base path once, so a customized collector's badges read unknown until the dialog was reopened), and a **superseded badge sweep being dropped** so a read still in flight cannot file one account's plan under another row |
| `tst_timeutils.qml` | timestamp parsing **under Qt's JS engine** (which is what runs it, not node), including the API's 6-digit fractional seconds; "NaN" never renders | "NaNd NaNh" in the panel |
| `tst_primer.qml` | when a new five-hour window is opened and, mostly, when it is not: refresh never primes, one prime per expiry, a stale reset time does not repeat, an expiry seen only after the fact does nothing, an undelivered prime is retried and then bounded. Single-account only: the "earliest five-hour reset across all accounts" pick that feeds it is a binding in `main.qml`, which no suite loads, so that choice of *which* reset to watch is the one piece of this path with no automated check. The collector's side of it — priming every expired account, each under its own hourly ceiling — is pinned in the selftest | a regression here spends real subscription usage, possibly in a loop |
| `tst_serviceunit.qml` | `ServiceControl` without a systemd session: the surface `tst_service.qml` binds to, and the paths that must refuse to spawn anything — `start()` and `requestPrime()` against a missing unit, and `requestPrime()` against a stopped one. This component had **no** CI coverage at all before, which is how it kept three raw data sources with neither the coalescing nor the watchdog the rest of the widget has. It deliberately does **not** repeat the state-parsing table: it was a byte-identical copy of the one in `tst_service.qml` (9 of 10 cases), and a duplicate table is a second thing to update that keeps passing after the component changes | a rewrite of the component breaking the surface, the service state silently mis-parsed, or a prime/signalled unit that is not installed |

Ten QML suites in all, nine of them in CI.

## CI

`.github/workflows/ci.yml`, five jobs:

- **unit** (ubuntu-latest): all three node suites and shellcheck.
- **daemon** (ubuntu-latest, matrix 3.9 / 3.11 / 3.14): the selftest on each.
  The collector declares only "python3", so the oldest interpreter anyone is
  likely to run is part of the contract. It was not for a long time: `iso()`
  writes a trailing `Z` and `datetime.fromisoformat` only learned to read one
  in 3.11, so on 3.9/3.10 every reset time failed to parse — silently, into a
  one-hour fallback — and nothing noticed, because the selftest only ever ran
  on one interpreter.
- **lint** (ubuntu-latest): ruff over the daemon, through stdin because the file
  has no `.py` extension.
- **i18n** (ubuntu-latest): regenerates the translation template with the
  command in `docs/i18n.md` and fails if the committed one has drifted. Fails
  on drift only — no `.pot` is committed yet, so the first run attaches the
  generated one as an artifact.
- **qml** (Arch container — Ubuntu LTS does not ship the Qt 6 builds of these
  modules): qmllint plus the eight hermetic QML suites (`tst_timeutils`,
  `tst_provider`, `tst_refresh`, `tst_config`, `tst_configaccounts`,
  `tst_model`, `tst_accounts`, `tst_primer`, `tst_serviceunit`).

`tst_service.qml` is deliberately not in CI: its last two tests talk to a
real systemd user manager, and when `kclaude.service` is installed they stop
and restart it (leaving it running). In a container with no user session the
live queries would sit at "unknown" and fail. It auto-skips the
service-mutating test when the unit is not installed, so running it on a
machine without the daemon is still safe — but it belongs to developer
machines, not runners.

## Conventions

- Tests pin behaviour that something else silently depends on (a file
  contract, a Plasma resolution rule, a systemd output format) — not
  line-by-line implementation.
- QML behaviour is tested under Qt's engine, never approximated in node; the
  two shared JS files (`Shell.js`, `Accounts.js`) are deliberately
  engine-neutral so the same bytes run in both.
- Where a rule is implemented twice — the account id slug in `account_id()` and
  in `Accounts.slug` — **one shared fixture table** is the right answer, not two
  tests. `tests/fixtures/slugs.json` is read by the daemon's `--selftest` *and*
  by `tests/accounts.test.js`, so what is under test is that the two
  implementations agree. Giving each its own test pins each against *itself*,
  which is the one direction in which two implementations cannot be caught
  diverging — and they had: Python's `str.isalnum()` is Unicode-aware and the
  JavaScript regex is not, so `café` was `café` to the collector and `caf` to
  the widget, and both suites stayed green throughout.
- A test that cannot fail is worse than no test, so each of these is checked by
  reverting its fix and watching it go red. That is how `tst_configaccounts`
  was found to be passing *with* the data-loss bug restored: the first version
  of the case called an explicit `reload()`, which started the read the missing
  `Component.onCompleted: refresh()` was supposed to start. It now constructs
  the page with `accountsFilePath` as an initial property, which is the
  constructor path — the one that was broken.
- Nothing may depend on a clock reading twice. Two `Date.now()` calls in one
  case make the expected value depend on whether a millisecond happened to tick
  between them, which fails about one run in ten for reasons that have nothing
  to do with the code.
- No test frameworks beyond `qmltestrunner` and node's stdlib.
