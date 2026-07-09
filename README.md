# kclaude

A KDE Plasma 6 panel widget that shows your Claude Code usage limits at a glance:
the five-hour, weekly and monthly windows, with a colour-coded status dot.

> **Disclaimer:** Unofficial third-party widget. Not affiliated with, endorsed by,
> or sponsored by Anthropic. "Claude" and "Claude Code" are trademarks of
> Anthropic. This project is not a product of Anthropic.

## Features

- Compact panel indicator with a colour-coded status dot
- Five-hour, weekly and monthly utilization, each with a progress bar
- Configurable warning and critical thresholds (defaults 75% / 90%)
- Countdown to the next limit reset
- Optional background collector that keeps the numbers current
- No runtime dependencies beyond Plasma 6 and Python 3

## Security: read this before installing the daemon

The widget alone is inert: it reads one JSON file and draws it. **The optional
collector daemon is the part that touches your credentials.** Specifically it:

- Reads the OAuth token Claude Code stores in `~/.claude/.credentials.json`.
- Calls `GET https://api.anthropic.com/api/oauth/usage` with that token.
- When the token has expired, refreshes it against
  `https://platform.claude.com/v1/oauth/token` using Claude Code's own OAuth
  client id, and **writes the refreshed token back to
  `~/.claude/.credentials.json`** — a file the daemon does not own.

Consequences worth weighing:

- **Both endpoints are undocumented and unversioned.** They can change or
  disappear without notice, and reusing Claude Code's OAuth client id may not be
  something Anthropic's terms permit. Treat this as a best-effort tool.
- **A token refresh rotates your refresh token.** That is why the daemon refuses
  to run twice (`flock` on `daemon.lock`): two copies refreshing at once would
  leave one holding a server-invalidated token, and writing that back would force
  you to re-authenticate Claude Code.
- **The credential file is shared, not owned.** The daemon re-reads it
  immediately before writing and replaces only the `claudeAiOauth` key, so the
  keys Claude Code owns survive. This narrows the race to microseconds but cannot
  eliminate it — Claude Code does not take the daemon's lock.
- Tokens never leave your machine except to the two Anthropic endpoints above,
  are never logged, and the credential file is rewritten mode `0600`.

If none of that is acceptable, install the widget without `--with-daemon` and
write `usage.json` yourself (format below).

## Requirements

- KDE Plasma 6
- `kpackagetool6` (from `plasma-sdk` or `kpackage`)
- Python 3 — only for the optional collector daemon

## Installation

```bash
git clone https://github.com/schiz0x00/kclaude.git
cd kclaude
./scripts/install.sh
```

With the collector daemon (see the Security section first):

```bash
./scripts/install.sh --with-daemon
```

Then right-click the panel, choose **Add Widgets…**, and search for `kclaude`.

The script is safe to re-run to upgrade, and works non-interactively — piped or
in CI it takes the default for every prompt.

### Manual install

```bash
kpackagetool6 --type Plasma/Applet --install .
# the "Add Widgets" browser resolves the icon by name, so it needs a copy:
mkdir -p ~/.local/share/icons/hicolor/scalable/apps
cp contents/icons/claude.svg ~/.local/share/icons/hicolor/scalable/apps/kclaude.svg
```

### Uninstall

```bash
./scripts/uninstall.sh
```

Removing the widget never touches `~/.claude/`. The daemon and the collected
usage snapshot are each removed only if you confirm.

## Configuration

Right-click the widget → **Configure**:

| Setting | Default | Notes |
| --- | --- | --- |
| Compact display mode | Icon + Usage | Icon only, or with the name and/or percentage |
| Refresh interval | 60 s | How often the widget re-reads the file, floored at 30 s |
| Refresh button | — | Re-reads the file *and* asks the collector to poll now |
| Warning threshold | 75% | Status turns amber at or above this |
| Critical threshold | 90% | Status turns red; always kept above the warning level |
| Usage file path | `~/.local/state/kclaude/usage.json` | |
| Refresh on popup open | on | Re-read the file when the popup opens |
| Start collector on popup open | on | Starts an installed-but-stopped collector. Never installs it |
| Show tooltip | on | |
| Show reset countdown | on | |

When the popup opens, the widget starts the collector if it is installed but
not running, then picks up the first numbers a few seconds later. It will not
install the collector for you: that would mean dropping an executable and a
systemd unit that read your credentials, which stays your explicit call. If the
unit is missing, the popup says so and shows the command. Turn the auto-start off
in the settings if you would rather drive it yourself.

The widget reads a file; it never makes network calls itself. The collector
writes that file every 5 minutes, so a refresh interval below 60 s only re-reads
identical data. Data older than 15 minutes is shown as stale rather than fresh.

## Data format

Anything can write `usage.json` — the daemon is one option. `utilization` is a
fraction from 0.0 to 1.0, and `resetAt` is an ISO-8601 timestamp:

```json
{
    "windows": {
        "five_hour": { "utilization": 0.68, "resetAt": "2026-07-30T18:00:00Z" },
        "seven_day": { "utilization": 0.41, "resetAt": "2026-08-03T00:00:00Z" }
    },
    "updatedAt": "2026-07-30T13:37:00Z"
}
```

Unknown window keys are accepted and title-cased for display. Malformed entries
are skipped rather than shown as 0%. An optional top-level `"error"` string is
shown as a banner in the popup — the daemon uses it when Claude Code's login
has expired and only the user can fix it. See
[docs/architecture.md](docs/architecture.md) for the full contract.

## Daemon

```bash
# status and logs
systemctl --user status kclaude.service
journalctl --user -u kclaude.service -f

# run in the foreground, custom interval in seconds (minimum 60)
~/.local/bin/kclaude-daemon 300

# stop collecting
systemctl --user disable --now kclaude.service
```

Only one instance runs at a time; a second exits immediately, by design. On
errors it backs off exponentially up to an hour and honours `Retry-After`.
When the Claude Code login itself has expired, the popup says so — run
`claude`, sign in again, and hit **Refresh**; the daemon picks the new
credentials up on its own.

`SIGUSR1` cuts the poll interval short, which is what the widget's **Refresh**
button uses to get fresh numbers without restarting the collector:

```bash
systemctl --user kill -s USR1 kclaude.service
```

Manually requested polls are floored at 30s apart, and a refresh request will not
short-circuit an error backoff. The usage endpoint returns `429 Too Many Requests`
well below one call every 30s, so both limits matter.

## Development

```bash
node tests/shell-quote.test.js       # shell quoting, checked against a real bash
node tests/package-layout.test.js   # package layout and config wiring
python3 daemon/kclaude-daemon --selftest
qmllint contents/ui/*.qml contents/code/*.qml contents/config/*.qml
shellcheck scripts/*.sh

# QML behaviour, run against Qt's own engine and the real Plasma imports.
# tst_service talks to the real systemd user manager (and stops/restarts
# kclaude.service if installed); the other suites are hermetic.
for t in tests/tst_*.qml; do
    QT_QPA_PLATFORM=offscreen qmltestrunner -input "$t"
done

# iterate on the widget in a standalone window
kpackagetool6 --type Plasma/Applet --upgrade . && plasmawindowed io.github.schiz0x00.kclaude
```

plasmashell caches applet QML, so `systemctl --user restart
plasma-plasmashell.service` is needed to see changes in the panel. `install.sh`
offers to do it.

CI runs everything except `tst_service` (see
[docs/testing.md](docs/testing.md)). More docs:

- [docs/architecture.md](docs/architecture.md) — components, the usage.json
  contract, and the reasoning behind the odd-looking decisions
- [docs/testing.md](docs/testing.md) — what each suite pins and why
- [docs/i18n.md](docs/i18n.md) — how strings are translated and how to add a
  language

## Layout

```text
metadata.json                 Plasma package metadata
contents/
  ui/                         main.qml, compact + full representations, UsageBar, StatusIndicator
  code/                       UsageModel, FileUsageProvider, ServiceControl, Shell.js, TimeUtils.js
  config/                     main.xml + the configuration form
  icons/claude.svg
daemon/
  kclaude-daemon              collector (Python 3, stdlib only)
  kclaude.service             systemd user unit
scripts/                      install.sh, uninstall.sh
docs/                         architecture, testing, i18n
tests/
  shell-quote.test.js         shell quoting vs a real bash (node)
  package-layout.test.js      config page location, cfg wiring, package id (node)
  tst_config.qml              config page renders and every setting is wired
  tst_provider.qml            usage.json parsing, incl. the "error" key
  tst_service.qml             collector detection and auto-start
  tst_timeutils.qml           timestamp parsing and formatting
.github/workflows/ci.yml      CI: everything except tst_service
```

## License

MIT — see [LICENSE](LICENSE).
