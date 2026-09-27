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
| `accounts.test.js` | `Accounts.js` slug/label/filename rules, and the three `Shell.js` commands the accounts page runs (`writeFile`, `findConfigDirs`, `hasCredentials`) against a **real bash** and a real filesystem — including `printf` format-specifier payloads and a command-substitution marker check | the widget and the collector deriving different filenames from the same account id, so an account silently shows nothing; a `%` in a label eating the JSON; a config dialog's write going somewhere else |
| `package-layout.test.js` | config page lives in `contents/ui/` (Plasma resolves `ConfigCategory.source` there, not `contents/config/`); every `cfg_*` alias ↔ `main.xml` entry both ways **across all pages**; a page that writes its own file defines `save()`; scripts use the metadata id | silently blank config dialog; settings that save but never load; a page whose own file is never written because `save()` is missing; installer removing the wrong package |
| `kclaude-daemon --selftest` | window normalization, token-expiry logic, `Retry-After` parsing, the exact `usage.json` key set, the scoped-window cache (parse, merge, backoff, persistence, plan downgrade, **pro skip**), credential merge-back, `AuthError` classification, `error`-key write/clear, the instance lock; **multi-account**: list parsing with a missing/corrupt/empty/capped file, per-account filenames, entries with no usable path dropped rather than defaulted, **credential isolation between two accounts**, per-account prime stamps, hot reload preserving pacing and scoped cache, reordering re-pointing filenames, `seconds_until_next` taking the minimum, `request_poll` not short-circuiting a backoff, and one account's `AuthError` not stopping the other | daemon and widget drifting apart on the file contract; a refresh eating Claude Code's own credentials; the scarce usage endpoint being hammered by the Fable poll; **one account's token written into another's credentials file, which logs both out of Claude Code**; a bad entry silently showing the default account's numbers under the wrong name; one account's backoff stalling the rest |
| `tst_provider.qml` | widget side of the file contract: valid/malformed payloads, the `error` key (with and without windows), sanitization + caps, the Fable window's name, the per-window lag that a slow window reports, and the `plan` allow-list (including that a rejected payload leaves no plan behind) | a collector change blanking the panel; HTML-ish file content reaching a rich-text label; a half-hour-old number drawn as a live one; arbitrary text from a hand-written file drawn as a plan badge |
| `tst_accounts.qml` | `accounts.json` → the account list: a missing file resolving to the single default account, every unusable shape falling back to it, entries without a usable **string** path dropped, unusable ids dropped and valid ones slugged, duplicate ids dropped, the list capped at the collector's own 8, labels stripped of markup and length-capped, and the per-account usage paths | an upgrade breaking every existing install; one account silently showing the default account's numbers; two accounts sharing one usage file; a label fetching a remote URL from inside plasmashell |
| `tst_refresh.qml` | refresh **scheduling**, against the real executable dataengine: a burst of refreshes is coalesced to one trailing read rather than dropped, spaced refreshes are all honoured, a wedged read is recovered, a failed read does not wedge, an empty path never reaches a shell | the dataengine keys sources by name and `connectSource()` on a name it already holds runs nothing — so a refresh during a read is lost, and a source left connected blocks that name **forever**, freezing the widget on its last numbers |
| `tst_config.qml` | the page is a real `Kirigami.Page` pushed onto a real `PageRow`, renders controls, clamps values, exposes every `cfg_*` | the historical blank-config-page bug; qmllint cannot catch it |
| `tst_configaccounts.qml` | the accounts page is a real `Page` pushed onto a real `PageRow` and renders; the list-editing rules: duplicate folder refused, colliding ids made unique, the cap matches the collector's, reordering, removal, the derived usage paths lining up with what the collector writes, and **the General page's usage-file setting reaching this page** — a page that ignored it would show every plan badge as unknown while the accounts themselves polled and drew fine | the historical blank-config-page bug again, on a second page; a row added that the collector would have dropped, or two rows sharing one state file; a customized usage path read on one page and not the other |
| `tst_timeutils.qml` | timestamp parsing **under Qt's JS engine** (which is what runs it, not node), including the API's 6-digit fractional seconds; "NaN" never renders | "NaNd NaNh" in the panel |
| `tst_primer.qml` | when a new five-hour window is opened and, mostly, when it is not: refresh never primes, one prime per expiry, a stale reset time does not repeat, an expiry seen only after the fact does nothing, an undelivered prime is retried and then bounded. Single-account only: the "earliest five-hour reset across all accounts" pick that feeds it is a binding in `main.qml`, which no suite loads, so that choice of *which* reset to watch is the one piece of this path with no automated check. The collector's side of it — priming every expired account, each under its own hourly ceiling — is pinned in the selftest | a regression here spends real subscription usage, possibly in a loop |
| `tst_service.qml` | `systemctl show` output parsing against captured strings; start cooldown; `becameActive` edge; plus two **live** tests against the real user manager | auto-start reporting a false "inactive"; restarting an already-running collector |

Eight QML suites in all, seven of them in CI.

## CI

`.github/workflows/ci.yml`, two jobs:

- **unit** (ubuntu-latest): all three node suites, the daemon selftest, shellcheck.
- **qml** (Arch container — Ubuntu LTS does not ship the Qt 6 builds of these
  modules): qmllint plus the seven hermetic QML suites (`tst_timeutils`,
  `tst_provider`, `tst_refresh`, `tst_config`, `tst_configaccounts`,
  `tst_accounts`, `tst_primer`).

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
  in `Accounts.slug`, the per-account filename in `Account.suffix_files` and
  `Accounts.usageFile` — both sides get their own test, because the two can only
  be checked against each other by reading both, and the failure is silent.
- No test frameworks beyond `qmltestrunner` and node's stdlib.
