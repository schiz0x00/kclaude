# Architecture

Two independent halves, joined by one JSON file:

```
┌─────────────────────────┐        ┌──────────────────────────────┐
│ collector daemon        │ writes │ ~/.local/state/kclaude/      │
│ (Python 3, stdlib only) │──────► │ usage.json                   │
│ polls the usage API     │        └──────────────┬───────────────┘
│ every 5 minutes         │                       │ reads (cat)
└───────────┬─────────────┘        ┌──────────────▼───────────────┐
            │ SIGUSR1 = poll now   │ Plasma widget (QML only)     │
            └──────────────────────│ panel dot + popup bars       │
                                   └──────────────────────────────┘
```

The widget never touches the network or the credentials; the daemon never
draws anything. Either side can be replaced: anything that writes the file
format below works as a collector, and anything that reads it works as a
display.

## The file contract

`usage.json`, written atomically (temp file + rename in the same directory):

```json
{
    "windows": {
        "five_hour": { "utilization": 0.68, "resetAt": "2026-07-30T18:00:00Z" },
        "seven_day": { "utilization": 0.41, "resetAt": "2026-08-03T00:00:00Z" }
    },
    "updatedAt": "2026-07-30T13:37:00Z",
    "error": "Claude Code login expired: run 'claude' and sign in again"
}
```

- `utilization` is a fraction 0.0–1.0 (the daemon divides the API's 0–100).
- `resetAt` and `updatedAt` are ISO-8601. `updatedAt` older than 15 minutes
  renders as stale.
- `error` is optional. The daemon writes it when only the user can fix the
  problem (expired or missing Claude Code login) and removes it again on the
  next successful poll. The widget shows it verbatim (sanitized, capped at
  160 chars) as a red banner in the popup and a line in the tooltip. A payload
  with `error` and zero windows is valid — that is what a collector that never
  authenticated writes.
- Unknown window keys are accepted and title-cased for display
  (`core_seven_day` → "Core Seven Day"); entries without a numeric
  `utilization` are skipped, never shown as 0%. At most 8 windows, names
  capped at 32 chars: the path to the file is user-configurable, so its
  contents are treated as untrusted.

The daemon side of the contract is pinned by `--selftest`
(`daemon/kclaude-daemon`), the widget side by `tests/tst_provider.qml`.

## Widget components

| File | Role |
| --- | --- |
| `contents/ui/main.qml` | `PlasmoidItem` root; wires model ↔ representations, tooltip, refresh timer |
| `contents/ui/CompactRepresentation.qml` | panel icon + status dot (+ optional text) |
| `contents/ui/FullRepresentation.qml` | popup: bars, error banner, empty states, Refresh |
| `contents/ui/UsageBar.qml`, `StatusIndicator.qml` | presentation only |
| `contents/code/UsageModel.qml` | keeps last good state, derives status/limiting window |
| `contents/code/FileUsageProvider.qml` | reads + validates usage.json |
| `contents/code/ServiceControl.qml` | queries/starts the systemd unit, SIGUSR1 poke, SIGUSR2 prime |
| `contents/code/SessionPrimer.qml` | decides when a new five-hour window should be opened |
| `contents/code/Shell.js` | the only shell-quoting code (see Security) |
| `contents/code/TimeUtils.js` | formatting + status thresholds |

The panel percentage is always the five-hour window (`CompactRepresentation`
looks up `five_hour` directly), because a number whose denominator changes on its
own cannot be read at a glance. The status dot is not: it follows the worst
window, so an approaching weekly limit still shows.

Status is derived from the *most utilized* window: `active` → `warning`
(default 75%) → `critical` (90%) → `limit_reached` (100%), with `offline`
when the data is stale or unreadable and `unknown` before first data.

## Decisions worth knowing about

### Why the widget reads the file with `cat` (plasma5support)

Pure QML cannot read a local file in a Plasma session: `XMLHttpRequest`
refuses `file://` unless `QML_XHR_ALLOW_FILE_READ=1` is set process-wide in
plasmashell, which is not something a widget can or should do. The only
sanctioned escape hatch is the `executable` dataengine from
`org.kde.plasma.plasma5support`, so `FileUsageProvider` runs
`cat <quoted path>` and `ServiceControl` runs fixed `systemctl --user`
strings.

**Known risk:** KDE describes plasma5support as a transition-period framework
("dataengine support has been removed from KF6; this provides a temporary
implementation during the transition"). It ships with every current Plasma 6
release, but may disappear in Plasma 7. The dependency is deliberately
confined to two files — `FileUsageProvider.qml` and `ServiceControl.qml` —
so the exit is contained: if KDE ships a QML file-reading or process API (or
plasma5support is dropped), those two files are the entire migration surface.
Nothing else in the widget knows how the data arrives.

### Why every interpolated shell string goes through Shell.js

`FileUsageProvider` is the only place user-configurable text (the usage file
path) reaches a shell. `Shell.path()` POSIX-single-quotes it, keeping a
leading `~/` outside the quotes so the shell still expands it.
`tests/shell-quote.test.js` round-trips every case through a real bash and
proves injection payloads do not execute (marker-file check).
`ServiceControl` never interpolates anything: its commands are fixed strings
built from a readonly unit name.

### Why the config page is a KCM.SimpleKCM

The Plasma config dialog pushes each page onto a Kirigami `PageRow`, whose
insertion handler assumes the page has `background` and a global-header
transform. A bare `FormLayout` has neither, the handler throws mid-insert,
and the page renders blank with no visible error. `SimpleKCM` is a
`Kirigami.Page` and is what in-tree applets use. Pinned by
`tests/tst_config.qml`, which pushes the page onto a real `PageRow`.

### Why the daemon refuses to run twice

A token refresh rotates the refresh token server-side. Two daemons refreshing
concurrently means the loser holds — and writes back — a dead token, forcing
the user to re-authenticate Claude Code itself. The `flock` on
`daemon.lock` makes the second instance exit 0 (systemd sees success, no
restart loop).

### The credential file is shared, not owned

The daemon reads `~/.claude/.credentials.json` (Claude Code's file), and when
it refreshes the token it re-reads the file immediately before writing back
*only* the `claudeAiOauth` key, atomically, mode 0600. Claude Code does not
take the daemon's lock, so a lost-update window of microseconds remains; the
merge discipline keeps Claude Code's other keys (`mcpOAuth`, etc.) intact
either way. Pinned by `--selftest`.

### The re-authentication surface

Auth failures are classified, not retried blindly. `AuthError` covers: missing
credentials file, credentials without a `claudeAiOauth` entry, and the token
endpoint rejecting the refresh with 400/401/403 (an expired or rotated-away
refresh token returns 400 `invalid_grant`). On `AuthError` the daemon writes
the `error` key into `usage.json` — preserving the last good numbers — and
keeps backing off exponentially. Unlike the generic error path, a manual
Refresh is allowed through at the normal 30s floor, because the expected next
event is the user re-authenticating and clicking Refresh; the daemon re-reads
the credentials file on every poll, so recovery is automatic. 5xx and network
failures stay on the generic path: exponential backoff up to an hour,
`Retry-After` honoured (and capped, so a hostile header cannot park the
daemon).

### Why the widget decides when to prime, and the daemon sends it

Session priming needs two things that live on opposite sides of the file
contract: the setting (a widget config key, in plasmashell's applet config) and
the credentials (the daemon's). Rather than teach the daemon to find and parse an
applet's config group, the widget decides *when* and the daemon decides *how*:
`SessionPrimer` raises a signal, `ServiceControl` turns it into
`systemctl --user kill -s USR2`, and the daemon sends the message.

Priming is a separate signal from the poll poke on purpose. Refresh must never
be able to spend usage, and a single signal with a "which action" flag would put
that guarantee in a payload rather than in the kernel's signal number.

The cost is that priming needs plasmashell running with the widget in the panel.
That is when a five-hour window is worth aligning anyway, and the alternative --
a daemon reading a Plasma applet config group by index -- is far more fragile
than the feature is valuable.

Arming is what keeps it to one message per window: the primer only counts a
five-hour window it observed while that window still had time left, and a reset
time already in the past the first time it is seen (which is what a plasmashell
restart looks like) arms nothing.

A window disarms on delivery, not on the attempt. `ServiceControl.requestPrime()`
returns false while the unit is not active — the first seconds after a
plasmashell start look exactly like that — so the handler only calls
`SessionPrimer.confirm()` when the signal really went out, and otherwise the
window stays armed for the next 30-second tick. Retrying is free (the check is
local; nothing is sent), and bounded: ten minutes past the reset the primer gives
up rather than opening a window that is already well under way.
`tests/tst_primer.qml` covers each case, including both ends of that bound.

The daemon's own hourly floor is the backstop under all of it, and it lives in
`~/.local/state/kclaude/last-prime` rather than in memory — an in-memory counter
would let a crash-restart loop spend once per crash, which is the case the floor
exists to bound.

### Priming must not reach API billing

The token in `~/.claude/.credentials.json` is a Claude Code OAuth token
(`sk-ant-oat…`) and draws on the subscription. An API key (`sk-ant-api…`) in the
same field would draw on prepaid credits. `prime_request` therefore checks the
prefix against an allowlist and raises `AuthError` for anything else, including
an unfamiliar prefix: refusing to prime is always cheaper than guessing which
account pays. No `x-api-key` header is ever set and no `ANTHROPIC_API_KEY` is
read anywhere in the daemon, so the bearer token is the only credential in play.

### Rate-limit discipline

The usage endpoint 429s well below one call every 30s. Three layers keep the
widget from ever hammering it: the daemon polls every 5 minutes and floors
manual pokes at 30s (`MIN_POLL_GAP`); the widget floors its Refresh button at
30s (`pollCooldownMs`) and its systemctl start attempts at 15s; and during an
error backoff a manual poke waits out the whole backoff rather than
short-circuiting it.

### systemd unit choices

`WantedBy=default.target` — the user manager's main target — rather than
`graphical-session.target`, which only exists when the session manager pulls
it in. Hardening is limited to `NoNewPrivileges` and `RestrictSUIDSGID`
because both are prctl/seccomp-only and cannot fail to apply in a user
manager; heavier sandboxing (`ProtectHome=`) is impossible anyway, since the
daemon's whole job is writing `~/.claude/` and `~/.local/state/`.

## Undocumented API caveat

Both endpoints the daemon uses (`api.anthropic.com/api/oauth/usage`,
`platform.claude.com/v1/oauth/token`) are undocumented and unversioned, and
the daemon reuses Claude Code's OAuth client id. They can change or disappear
without notice; treat the collector as best-effort. The widget half keeps
working with any other writer of the file contract.
