# Testing

Every suite runs without a display (`QT_QPA_PLATFORM=offscreen`); only
`tst_service.qml` needs a real systemd user session.

```bash
# node: no framework, plain scripts, non-zero exit on failure
node tests/shell-quote.test.js
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
| `package-layout.test.js` | config page lives in `contents/ui/` (Plasma resolves `ConfigCategory.source` there, not `contents/config/`); every `cfg_*` alias ↔ `main.xml` entry both ways; scripts use the metadata id | silently blank config dialog; settings that save but never load; installer removing the wrong package |
| `kclaude-daemon --selftest` | window normalization, token-expiry logic, `Retry-After` parsing, the exact `usage.json` key set, credential merge-back, `AuthError` classification, `error`-key write/clear, the instance lock | daemon and widget drifting apart on the file contract; a refresh eating Claude Code's own credentials |
| `tst_provider.qml` | widget side of the file contract: valid/malformed payloads, the `error` key (with and without windows), sanitization + caps | a collector change blanking the panel; HTML-ish file content reaching a rich-text label |
| `tst_config.qml` | the page is a real `Kirigami.Page` pushed onto a real `PageRow`, renders controls, clamps values, exposes every `cfg_*` | the historical blank-config-page bug; qmllint cannot catch it |
| `tst_timeutils.qml` | timestamp parsing **under Qt's JS engine** (which is what runs it, not node), including the API's 6-digit fractional seconds; "NaN" never renders | "NaNd NaNh" in the panel |
| `tst_service.qml` | `systemctl show` output parsing against captured strings; start cooldown; `becameActive` edge; plus two **live** tests against the real user manager | auto-start reporting a false "inactive"; restarting an already-running collector |

## CI

`.github/workflows/ci.yml`, two jobs:

- **unit** (ubuntu-latest): both node suites, the daemon selftest, shellcheck.
- **qml** (Arch container — Ubuntu LTS does not ship the Qt 6 builds of these
  modules): qmllint plus the three hermetic QML suites
  (`tst_timeutils`, `tst_provider`, `tst_config`).

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
  one shared JS file (`Shell.js`) is deliberately engine-neutral so the same
  bytes run in both.
- No test frameworks beyond `qmltestrunner` and node's stdlib.
