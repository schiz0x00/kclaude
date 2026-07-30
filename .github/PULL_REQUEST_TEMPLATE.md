## What this changes

<!-- And why. The reasoning is the part a diff cannot show. -->

## Checks

- [ ] `python3 daemon/kclaude-daemon --selftest`
- [ ] `node tests/package-layout.test.js` and `node tests/shell-quote.test.js`
- [ ] `shellcheck scripts/*.sh`
- [ ] `qmllint` and the hermetic `qmltestrunner` suites
- [ ] Docs updated if behaviour changed (README, `docs/architecture.md`, `CHANGELOG.md`)

## If this touches the collector

- [ ] No new request can go out on a credential that is not a Claude Code OAuth token
- [ ] Any change in what it spends, or how often, is stated in the README's Security section
