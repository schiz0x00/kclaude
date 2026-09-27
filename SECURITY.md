# Security

## What this project touches

The widget is inert: it reads JSON files and draws them. The optional collector
daemon is the part with reach. It reads the OAuth token Claude Code stores in
each configured account's `.credentials.json` — `~/.claude/.credentials.json`
unless you add more in the **Accounts** settings page — sends requests to
Anthropic with them, and writes a refreshed token back to the same file it came
from when the old one expires. Each account's token only ever goes back to that
account's own file: writing one account's refresh into another's credentials file
would log that account out of Claude Code.

The widget also *writes* one file, `~/.config/kclaude/accounts.json`, mode `0600`
— a list of directory paths and labels. It contains no secrets, and the
settings dialog never reads a token to produce it.

The README's [Security
section](README.md#security-read-this-before-installing-the-daemon) is the full
account of what it sends and why, and it is kept current with the code. Read it
before installing the daemon.

## Reporting a vulnerability

Report privately, not as a public issue:

- Use [GitHub's private vulnerability
  reporting](https://github.com/schiz0x00/kclaude/security/advisories/new), or
- email the address on the maintainer's GitHub profile.

Please include what an attacker would gain and how to reproduce it. This is a
hobby project maintained by one person, so expect an initial reply in days
rather than hours.

Anything that could expose an OAuth token, write a bad token back into any
account's `.credentials.json`, or send a request the user did not ask for counts
as a vulnerability here — including bugs in the widget half, which is not
supposed to be able to do any of those things.

## Not vulnerabilities

- The Anthropic endpoints being undocumented, unversioned, or breaking.
- The collector spending subscription quota. It does that by design, about nine
  tokens a minute, and the README says so up front.
- Reusing Claude Code's OAuth client id. That is a deliberate, documented
  trade-off, not an oversight.

## Supported versions

The latest release only. Fixes ship in a new tag rather than as patches to old
ones.
