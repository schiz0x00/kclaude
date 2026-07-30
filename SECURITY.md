# Security

## What this project touches

The widget is inert: it reads one JSON file and draws it. The optional collector
daemon is the part with reach. It reads the OAuth token Claude Code stores in
`~/.claude/.credentials.json`, sends requests to Anthropic with it, and writes a
refreshed token back to that file when the old one expires.

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

Anything that could expose the OAuth token, write a bad token back into
`~/.claude/.credentials.json`, or send a request the user did not ask for counts
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
