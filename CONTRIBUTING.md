# Contributing

Bug reports, patches and packaging fixes are all welcome. This is a small
project, so there is very little process — but there are a few things worth
knowing before you spend time on a change.

## Ground rules

- **The widget never touches the network or the credentials.** It reads one
  JSON file and draws it. Anything that needs a token belongs in the collector
  daemon.
- **The collector spends real subscription quota.** Every request it can send
  goes through one allowlist that refuses anything that is not a Claude Code
  OAuth token, so no code path can reach API billing. Keep it that way.
- **Either half is replaceable.** Anything that writes `usage.json` in the
  documented format works as a collector; anything that reads it works as a
  display. Changes that couple the two need a reason.
- **Comments explain why, not what.** The surprising decisions in this codebase
  are written down next to the code that depends on them. If you change one of
  those decisions, change the comment in the same commit.

## Development setup

```bash
git clone https://github.com/schiz0x00/kclaude.git
cd kclaude
./scripts/install.sh          # add --with-daemon for the collector
```

Iterate on the widget without touching your panel:

```bash
plasmawindowed io.github.schiz0x00.kclaude
```

Every state the widget can show is reachable by writing `usage.json` — no real
limit has to be hit. See the Data format section of the README.

## Before opening a pull request

Run what CI runs:

```bash
node tests/shell-quote.test.js
node tests/package-layout.test.js
python3 daemon/kclaude-daemon --selftest
shellcheck scripts/*.sh

export QT_QPA_PLATFORM=offscreen
qmllint contents/ui/*.qml contents/code/*.qml contents/config/*.qml
qmltestrunner -input tests/tst_timeutils.qml
qmltestrunner -input tests/tst_provider.qml
qmltestrunner -input tests/tst_config.qml
qmltestrunner -input tests/tst_primer.qml
```

`tests/tst_service.qml` is deliberately left out of CI: it drives a real systemd
user manager and will stop and restart `kclaude.service` if you have it
installed. Run it by hand when you touch `ServiceControl.qml`.

New logic wants one runnable check, not a suite. The daemon keeps its checks in
`--selftest`; the QML suites are hermetic and take no fixtures.

## Commits and pull requests

- One concern per commit. A rename and a behaviour change are two commits.
- Explain **why** in the commit body when the change is not obvious from the
  diff — the reasoning is what future readers cannot reconstruct.
- Pull requests go against `main`. CI must be green.

## Reporting a bug

Open an issue with your Plasma version, distribution, whether the collector is
installed, and the relevant output of:

```bash
systemctl --user status kclaude.service
journalctl --user -u kclaude -n 50
```

Never paste `~/.claude/.credentials.json` or anything out of it.
