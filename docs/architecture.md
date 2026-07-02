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
| `contents/code/ServiceControl.qml` | queries/starts the systemd unit, SIGUSR1 poke |
| `contents/code/Shell.js` | the only shell-quoting code (see Security) |
| `contents/code/TimeUtils.js` | formatting + status thresholds |

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
