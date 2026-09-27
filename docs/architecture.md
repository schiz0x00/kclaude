# Architecture

Two independent halves, joined by JSON files — one per account:

```
                  ~/.config/kclaude/accounts.json
                  (the list; written by the settings page,
                   re-read by the daemon every poll)
                              │ reads
                              ▼
┌─────────────────────────┐        ┌──────────────────────────────┐
│ collector daemon        │ writes │ ~/.local/state/kclaude/      │
│ (Python 3, stdlib only) │──────► │ usage.json                   │
│ one account per entry:  │        │ usage-<id>.json  …            │
│ own token, own schedule │        └──────────────┬───────────────┘
└───────────┬─────────────┘                       │ reads (cat, one per
            │ SIGUSR1 = poll now                   │ account)
            │ SIGUSR2 = prime every expired        ▼
            └──────────────────────┌──────────────────────────────┐
                                   │ Plasma widget (QML only)     │
                                   │ panel: all accounts at once  │
                                   │ popup: a section per account│
                                   └──────────────────────────────┘
```

The widget never touches the network or the credentials; the daemon never draws
anything. Either side can be replaced: anything that writes the file format
below works as a collector, and anything that reads it works as a display.

One account is the degenerate case of all of this, and is what a fresh install
gets: a single entry, a single `usage.json`, and a panel and popup that look
exactly as they always did.

## The file contract

`usage.json`, written atomically (temp file + rename in the same directory):

```json
{
    "windows": {
        "five_hour": { "utilization": 0.68, "resetAt": "2026-07-30T18:00:00Z" },
        "seven_day": { "utilization": 0.41, "resetAt": "2026-08-03T00:00:00Z" },
        "fable": {
            "utilization": 0.22,
            "resetAt": "2026-08-03T00:00:00Z",
            "updatedAt": "2026-07-30T13:07:00Z"
        }
    },
    "updatedAt": "2026-07-30T13:37:00Z",
    "plan": "max",
    "error": "Claude Code login expired: run 'claude' and sign in again"
}
```

- `utilization` is a fraction 0.0–1.0 (the daemon divides the API's 0–100).
- `resetAt` and `updatedAt` are ISO-8601. `updatedAt` older than 15 minutes
  renders as stale.
- A window may carry its **own** `updatedAt`, and only windows read on a slower
  cadence than the file do. The widget shows how far behind such a window is
  once the gap passes 5 minutes (`windowSkewMs` in `FileUsageProvider.qml`); a
  window without one is exactly as fresh as the file, so it never shows the
  extra line. This exists because Fable's number is up to half an hour old by
  construction, and presenting that as if it were one minute old is the same
  lie the 15-minute rule exists to prevent.
- `error` is optional. The daemon writes it when only the user can fix the
  problem (expired or missing Claude Code login) and removes it again on the
  next successful poll. The widget shows it verbatim (sanitized, capped at
  160 chars) as a red banner in the popup and a line in the tooltip. A payload
  with `error` and zero windows is valid — that is what a collector that never
  authenticated writes.
- `plan` is optional and is the subscription type out of the credentials
  (`max`, `pro`, …). The daemon writes it because it is the only thing that
  reads the credentials, and the widget is not allowed to. The widget
  allow-lists four values and shows no badge for anything else, so this string —
  the one field in the file that was never written by code in this repository —
  cannot become arbitrary text on the panel.
- Unknown window keys are accepted and title-cased for display
  (`core_seven_day` → "Core Seven Day"); entries without a numeric
  `utilization` are skipped, never shown as 0%. At most 8 windows, names
  capped at 32 chars: the path to the file is user-configurable, so its
  contents are treated as untrusted.

With more than one account there is one such file per account: the first entry
keeps `usage.json` verbatim, the rest are `usage-<id>.json` beside it. Separate
files rather than one combined document, so one account's failure cannot reach
the other's row — a dead login, a corrupt write or a missing file stays inside
the account it belongs to. The cost is one `cat` per account per refresh, which
is a few milliseconds each and already bounded by the 30 s refresh floor.

The daemon side of the contract is pinned by `--selftest`
(`daemon/kclaude-daemon`), the widget side by `tests/tst_provider.qml`.

## Widget components

| File | Role |
| --- | --- |
| `contents/ui/main.qml` | `PlasmoidItem` root; one model per account, tooltip, refresh timer |
| `contents/ui/configAccounts.qml` | the account list editor (its own KCM page) |
| `contents/ui/CompactRepresentation.qml` | panel icon + status dot (+ optional text) |
| `contents/ui/FullRepresentation.qml` | popup: bars, error banner, empty states, Refresh |
| `contents/ui/UsageBar.qml`, `StatusIndicator.qml` | presentation only |
| `contents/code/UsageModel.qml` | keeps last good state, derives status/limiting window |
| `contents/code/FileUsageProvider.qml` | reads + validates usage.json |
| `contents/code/AccountList.qml` | reads `accounts.json`, defaults to one account |
| `contents/code/OneShotReader.qml` | runs one command, coalesced, with a wedge watchdog |
| `contents/code/ServiceControl.qml` | queries/starts the systemd unit, SIGUSR1 poke, SIGUSR2 prime |
| `contents/code/SessionPrimer.qml` | decides when a new five-hour window should be opened |
| `contents/code/Shell.js` | the only shell-quoting code (see Security) |
| `contents/code/Accounts.js` | account id slugs and per-account file names |
| `contents/code/TimeUtils.js` | formatting + status thresholds |

The daemon side adds `ScopedWindows`, the one part of it that pays for the
scarce usage endpoint on purpose (see below).

The panel percentage is always the five-hour window (`CompactRepresentation`
looks up `five_hour` directly), because a number whose denominator changes on its
own cannot be read at a glance. The status dot is not: it follows the worst
window, so an approaching weekly limit still shows.

With several accounts the panel lists **every** account's five-hour window in
order, separated by `·` — `82% · 0%`. The alternative, one number for whichever
account is worst, was rejected because it leaves the panel silent about the fact
that a second account exists at all, which is the thing a user with two accounts
is looking at the panel to find out. An account with nothing to report shows `–`
rather than being omitted, so a shorter row never reads as a smaller number. The
dot follows the worst status across accounts, computed once in `main.qml` as
`worstStatus` so the dot, the tooltip and the popup footer cannot disagree about
what "worst" means.

The popup gives each account a section: its label, a plan badge, its own bars,
its own countdowns, and its own login error. A single merged list of bars was
rejected because the accounts' five-hour windows genuinely reset hours apart
(measured 2026-09-27: 16:30Z and 19:50Z), and two unrelated countdowns under one
heading read as a single account with six limits.

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

### Why refreshes are coalesced, and why a stuck read is recovered

The executable dataengine keys its sources by name, and `connectSource()` on a
name it already considers connected returns without running anything. Measured
against the real engine (`tests/tst_refresh.qml`):

| | `connectSource` calls | process actually ran |
| --- | --- | --- |
| two connects while the first is in flight | 2 | **1** |
| connect, let it land, connect again | 2 | 2 |
| one connect, never disconnected, five more | 6 | **1, forever** |

The second row is why this was not visible for so long: the read completes in
single-digit milliseconds and the callers are seconds apart, so a routine
collision needs a double-click. The third row is the one that matters. If
`onNewData` never arrives, the name stays held and *every* later refresh is
dropped — the widget sits on its last numbers with nothing to indicate that
anything is wrong, and no amount of waiting or clicking helps.

So `refresh()` never connects while a read is in flight. It records that one was
asked for, and exactly one trailing read runs when the current one lands. That
loses nothing: the file is read when the process runs, so one read after a burst
returns the same data N reads during it would have. A watchdog covers the wedge —
it is the only thing that can undo a source the engine still believes is
running, so it force-disconnects the name and reports a timeout rather than
leaving the widget quietly frozen.

`ServiceControl` does the same three-process dance and gets the same
per-instance source registry, so its `show`/`start`/`kill` strings cannot
collide with the `cat` above — different `DataSource` objects, and the registry
is per-instance (also measured).

All of this now lives in `OneShotReader.qml`, shared. It started as the body of
`FileUsageProvider` and was pulled out when `AccountList` needed the same
guarantees: a second copy of the wedge recovery is a second place for it to be
un-fixed, and the failure mode is a widget frozen on stale data with nothing
indicating why. `expectOutput` is the one knob that differs between the two
callers — a `cat` with no output is a failure, a `printf > file` with no output
is a success.

### Why every interpolated shell string goes through Shell.js

`FileUsageProvider` and `AccountList` are the places user-configurable text
reaches a shell — the usage file path, the accounts file, and the config
directory a folder picker returned. `Shell.path()` POSIX-single-quotes it,
keeping a leading `~/` outside the quotes so the shell still expands it.
`tests/shell-quote.test.js` round-trips every case through a real bash and
proves injection payloads do not execute (marker-file check).

`Shell.writeFile` is the one command that *writes*, and therefore the only place
widget-supplied text becomes a command's output rather than its input. It is
`printf '%s' <quoted> > <quoted>` with the payload as an argument, never as the
format string — a label containing `50%` would otherwise be eaten as a format
specifier. `tests/accounts.test.js` round-trips `%s`, `%d`, `%n`, quotes,
backslashes, newlines and `$(…)` payloads through a real bash and checks the
bytes that land.

`ServiceControl` never interpolates anything: its commands are fixed strings
built from a readonly unit name.

### Why the config page is a KCM.SimpleKCM

The Plasma config dialog pushes each page onto a Kirigami `PageRow`, whose
insertion handler assumes the page has `background` and a global-header
transform. A bare `FormLayout` has neither, the handler throws mid-insert,
and the page renders blank with no visible error. `SimpleKCM` is a
`Kirigami.Page` and is what in-tree applets use. Pinned by
`tests/tst_config.qml`, which pushes the page onto a real `PageRow`.

### Why the accounts page declares a setting it does not edit

The config dialog pushes **every** entry in `main.xml` at **every** page, not
just the one that owns it, and logs `SimpleKCM does not have a property called
cfg_*` for each one a page has not declared. `configGeneral.qml` has produced
ten such messages since long before accounts existed — open the dialog on a
fresh checkout and they are all in the journal. They are the dialog being
accurate about a page that ignores a setting, not a failure.

The accounts page needs one of them anyway. It shows each account's plan, which
means working out which usage file the collector wrote for it, and that answer
starts from the General page's *usage file path* — so it declares `cfg_filePath`
on a zero-sized hidden `TextField` and derives from it. A hardcoded default
would be wrong for anyone who pointed the widget at a collector of their own:
the accounts would poll and draw perfectly well while every plan badge on that
one page read as unknown, which looks like a bug in the accounts rather than in
the page. Pinned by `tests/tst_configaccounts.qml`.

The other nine it still does not declare, so those messages stay. Declaring
nine dead properties to quieten a log line would leave the next reader hunting
for what they are for.

### Why the account list is a file and not a kcfg entry

The list of accounts has to survive being handed to the collector, and kcfg has
no string-list type. A list of arbitrary paths, each with its own label, and
reorderable, has no kcfg representation at all — and a `String` entry holding
JSON would put a hand-rolled parser behind a settings key that Plasma owns,
validates and rewrites on its own schedule.

So it is `~/.config/kclaude/accounts.json`, written by the settings page's
`save()` and read by the daemon. Neither side owns it: the widget parses it for
what to draw, the daemon parses it for what to poll, and they agree on the
`id`/`label`/`path` shape and on the slug rule that turns an id into a filename.
Both ends of that agreement are pinned —
`account_id()` in the daemon's `--selftest`, `Accounts.slug` in
`tests/accounts.test.js` — because the failure is silent: if the two disagree on
one character, the widget watches a file the collector never writes and that
account shows nothing forever.

`SimpleKCM` persists the `cfg_*` properties itself; a page that writes its own
file has to reimplement `save()`, or Apply does nothing and says so nowhere.
`tests/package-layout.test.js` checks that a page which calls `Shell.writeFile`
also defines `save()`.

A missing file is not an error. It is what every install predating this feature
looks like, so it resolves to the single `~/.claude` account and nothing has to
be configured to keep working. An unusable *entry* is dropped with a reason in
the journal, because one bad path must not cost the user the accounts that are
fine.

### Why an entry with no usable path is dropped, never defaulted

The one failure mode a list of accounts cannot have is showing someone else's
numbers. An entry with a missing or non-string `path` used to fall back to
`~/.claude`, which would have polled the default account and filed its numbers
under the broken entry's name — silently, and looking like a working account.

So both sides require a string with something in it and drop the entry
otherwise. `Account.path_ok` in the daemon, `typeof entry.path !== "string"` in
`AccountList.parse`, and a case in `--selftest` and `tests/tst_accounts.qml` for
`{"id": "nopath", "path": 42}`.

### Why every account path hangs off an Account object

With one account, a module-level `CREDENTIALS_FILE` is fine. With two it is the
one mistake in this file that cannot be undone cheaply: refreshing account A's
token and writing it into account B's credentials file invalidates B's login,
and Claude Code then has to re-authenticate — a state the user has to notice and
fix by hand.

So there is no module-level credentials path left. `load_credentials`,
`save_oauth`, `refresh_access_token` and `with_token` all take the account, as do
`write_usage` and `write_error`; the usage, scoped and prime-stamp filenames are
derived from the account's position in the list. `--selftest` asserts the
isolation directly: refresh one account, read the other's file, expect the
untouched token.

The first account keeps the unsuffixed filenames it has always had, so an
existing install — and anything else already reading `usage.json` — goes on
working without being told about any of this.

### Why the scheduling is per account, and the loop takes the minimum

`next_due`, `last_poll`, `wake_floor` and `backoff` live on the account, not in
the loop's locals, and `seconds_until_next` returns the **minimum** across
accounts.

A shared interval would mean one account in an hour of error backoff stalls the
others at that cadence, and a limit that resets in four minutes gets polled at
the slowest account's pace. Neither is acceptable when the accounts are
independent — separate tokens, separate rate-limit budgets, separate resets.

`wake_floor` stays per account for the reason it existed at all: a Refresh click
may bring an account forward to `last_poll + wake_floor` but no further, so a
signal cannot short-circuit a 429 or a spent limit. During an error backoff that
floor *is* the backoff, which is what stops one 429 becoming a hammer.

One consequence worth stating: adding an account is noticed on the next loop
iteration, which is the poll cadence. So a new account starts polling within
about a minute, not immediately. That is what the settings page promises.

### Why priming covers every account, and how one signal says so

`SIGUSR2` is a signal, and a signal carries no payload. The widget cannot say
which account's five-hour window ran out — and it should not have to, since the
accounts' clocks are independent and any of them can be the one that runs out
first. So `SessionPrimer` is given the *earliest* five-hour reset across all
accounts, and the collector primes every account whose window has expired, each
under its own `MIN_PRIME_GAP` stamp on its own file.

Per-account stamps matter: one shared stamp would let the first account's prime
consume the second account's hourly allowance, and that account would silently
never be primed. A prime that succeeds zeroes only that account's floor, because
its numbers are seconds old and there is nothing left to wait for.

### Why the plan is published in the usage file

The plan decides two things: whether a badge is drawn, and whether the scarce
usage endpoint is worth calling at all. It lives in the credentials, which the
widget must not read, so the daemon publishes it in the file it already writes.
That also means the settings dialog can show each account's plan without ever
touching a token.

A pro account cannot have a per-model weekly budget — measured 2026-09-27, a pro
account's `limits[]` carries only `session` and `weekly_all`, and
`scoped_windows()` of that is `{}` — so `ScopedWindows.refresh` skips the call
entirely for one, and drops any window a downgrade left behind. Otherwise an
account that used to be Max keeps drawing a Fable bar for ever, which is the
phantom the "an empty result is a real answer" rule was written to prevent.

### Why the settings dialog never reads a token

The obvious way to answer "is this a Claude config folder?" is to read
`.credentials.json` and look for `claudeAiOauth`. That pulls a live OAuth access
and refresh token into the process drawing a settings dialog, for a question a
`test -f` answers.

So it is `test -f`, and nothing more — enough to reject a folder that is plainly
not one before offering it, and the collector is what actually reads the file and
reports whether the login works. The plan and any login error then come from the
collector's own output, which is the same source the popup uses.

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

### Where the numbers come from

Not from `/api/oauth/usage`. That endpoint has an account-wide quota measured
(2026-07) at roughly one call every two minutes, with a slow refill and hours
of 429s once drained — polling it every 5 minutes drained it. Claude Code does
not hit this because it barely uses the endpoint: its own bars come from the
`anthropic-ratelimit-unified-*` headers that ride on every `/v1/messages`
reply.

So the daemon reads the same headers, off its own ping: Haiku, no system
prompt, one character of content, `max_tokens: 1` — 8 input tokens and 1 output
token, about $0.00002. `/v1/messages` has no scarce limit at this rate. The
usage endpoint stays as the fallback when a ping fails.

The cost is that a ping opens a five-hour window when none is running, so one
is open around the clock. `primeOnReset` does that deliberately anyway.

### Why the Fable window cannot come off the poll

Fable is a model family with its own weekly budget, and it is the one limit the
ping structurally cannot see. `anthropic-ratelimit-unified-*` on a real Max-plan
reply (2026-09-27) carries `5h` and `7d` and nothing else — there are no Fable
headers to read. It arrives only on `/api/oauth/usage`, inside `limits[]` as a
scoped entry:

```json
{"kind": "weekly_scoped", "group": "weekly", "percent": 22,
 "resets_at": "2026-09-29T19:59:59.622752+00:00",
 "scope": {"model": {"id": null, "display_name": "Fable"}}}
```

That is the endpoint the whole design stays off, so `ScopedWindows` pays for it
deliberately: one call per `SCOPED_INTERVAL` (30 min, 48 a day), backed off
exponentially to 6 hours on failure, `Retry-After` honoured, and cached in
`scoped.json` so a restart does not spend a call the last process already
earned the right to spend. A cache that comes back with no scoped entry is a
real answer, not a failure — that is what an account without Fable reports, and
remembering it is the only way a plan change is ever noticed either way.

The window is named from `scope.model.display_name` rather than enumerated, so
a second scoped limit needs no code change. `normalize_windows` stays an
allowlist of the top-level keys on purpose: the endpoint returns a long tail of
siblings, one of them (`nimbus_quill`) a real dict with a 0% in it, and a bar
the widget had to invent a name for is worse than one it left out.

Two cadences now write the same file, which is why a scoped window carries its
own `updatedAt`. `write_usage` also refuses to let a scoped window displace one
the poll reports: when they disagree, the fast one is the accurate one.

### Why a prime re-polls, and zeroes the wait it just made obsolete

Opening the next five-hour window is a real request against a real window, so
its reply carries the headers for the window it just opened. Reading them costs
nothing, and is the difference between the widget showing the new numbers in a
second and showing the pre-prime ones until the next tick.

The second half matters more. `exhausted_until` is how the daemon avoids
hammering a window that refuses every request, but a prime is precisely what
makes the resulting wait false. With `primeOnReset` on, the widget primes at
every five-hour expiry — exactly the moment such a wait is being slept through —
so the numbers stayed frozen at 100% for up to `FIVE_HOURS` after the window
had already reopened. A successful prime now writes the file, zeroes
`wake_floor` and drops `delay` to the manual floor, so the poll at the top of
the loop re-derives everything from a window that is no longer spent. A prime
that was refused, or that failed, leaves the wait alone: nothing proved it
obsolete.

### Why the popup needed a clock

`TimeUtils.formatResetTime()` reads `new Date()` inside a plain JS function, and
QML cannot register a dependency on the passage of time from inside one. Every
"Resets in …" in the popup was therefore computed once per model update and
froze until the next one — up to a full refresh interval — so a reset that had
already passed kept counting down at its last value. The panel shows no
countdown and the tooltip's is a parenthetical, which is why this surfaced as
"the popup is stale" rather than as a bug with an obvious location.

The fix is a 1 s `Timer` bumping a counter that the countdowns read, because a
binding only re-evaluates when a dependency changes. 1 s rather than the 10 s
the coarse "updated" stamp needs: the text is rendered at that resolution, and a
countdown that visibly skipped would look broken.

### Rate-limit discipline

Three layers still bound the request rate: the daemon polls every 60s and
floors manual pokes at 30s (`MIN_POLL_GAP`); the widget floors its Refresh
button at 30s (`pollCooldownMs`) and its systemctl start attempts at 15s; and
during an error backoff a manual poke waits out the whole backoff rather than
short-circuiting it. A 429 leaves the last good numbers in place rather than
replacing them with an error.

A window at 100% is the fourth, and it is per account: the daemon stops pinging
that account entirely and sleeps until its window resets (`exhausted_until`),
because no request can succeed before then — a Refresh click cannot buy a number
the server will not give, so the wait is the floor for manual pokes too. The
other accounts are unaffected, which is the point of keeping the schedule on the
account.

With N accounts these layers apply N times over, and so does the cost: each
account is pinged every 60s against its own budget, and the scarce usage
endpoint has a budget per account too — so two accounts cost roughly twice one,
and `MAX_ACCOUNTS` (8) exists so that cannot happen by accident. The first ping after the reset is
what opens the new five-hour window. Every window is checked, not just the
five-hour one, since a spent weekly budget refuses the same request for days;
no wait outlives one window's length.

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
