// Checks Accounts.js and the Shell.js commands the settings page depends on,
// against a real bash and a real filesystem.
//
//   node tests/accounts.test.js
//
// Accounts.js is the widget's half of a contract the collector also implements
// in account_id() and Account.suffix_files(). The id is part of a filename on
// both sides: if the two disagree, the widget watches a file the collector never
// writes, and every account silently shows nothing. So the rules are pinned here
// rather than assumed to match.

const fs = require("fs");
const os = require("os");
const path_mod = require("path");
const { execFileSync } = require("child_process");

function load(rel, names) {
    const src = fs.readFileSync(path_mod.join(__dirname, "..", rel), "utf8");
    const out = {};
    // Plain JS with no .pragma library and no .import, so the widget and the test
    // share one copy -- same trick shell-quote.test.js uses.
    new Function("exports", src + "\n" + names.map(n => `exports.${n} = ${n};`).join("\n"))(out);
    return out;
}

const Shell = load("contents/code/Shell.js", ["quote", "path", "dirName", "writeFile",
                                             "findConfigDirs", "hasCredentials"]);
const Accounts = load("contents/code/Accounts.js", ["slug", "defaultLabel", "usageFile"]);

// The shared id table. The collector's --selftest reads this same file, so what
// is under test is the agreement between the two implementations rather than
// each one against itself -- which is how the two disagreed about every
// non-ASCII id while both suites stayed green.
const SLUGS = JSON.parse(fs.readFileSync(path_mod.join(__dirname, "fixtures", "slugs.json"), "utf8"));

let failures = 0;
function check(name, cond, detail) {
    if (cond) return;
    failures++;
    console.error(`FAIL ${name}${detail ? ": " + detail : ""}`);
}

function sh(command) {
    return execFileSync("bash", ["-c", command], { encoding: "utf8" });
}

// --- slug ------------------------------------------------------------------
// The one rule both sides of the contract have to agree on.
check("slug lowercases", Accounts.slug("Claude Dad") === "claude_dad", Accounts.slug("Claude Dad"));
check("slug collapses punctuation", Accounts.slug("a.b-c d") === "a_b_c_d", Accounts.slug("a.b-c d"));
check("slug trims separators", Accounts.slug("__x__") === "x", Accounts.slug("__x__"));
check("slug of nothing usable is empty", Accounts.slug("///") === "", Accounts.slug("///"));
check("slug of empty is empty", Accounts.slug("") === "");
check("slug of null is empty", Accounts.slug(null) === "");
check("slug keeps digits", Accounts.slug("opus 4.6") === "opus_4_6", Accounts.slug("opus 4.6"));

// The shared table. Read by both ends of the contract; see SLUGS above.
for (const c of SLUGS.cases) {
    check(`slug(${JSON.stringify(c.in)}) == ${JSON.stringify(c.out)}`,
          Accounts.slug(c.in) === c.out, Accounts.slug(c.in));
    check(`slug(${JSON.stringify(c.in)}) is within the id cap`,
          Accounts.slug(c.in).length <= SLUGS.maxLength, Accounts.slug(c.in).length);
}
for (const v of SLUGS.nonStrings) {
    // Not coerced. String(42) would invent the id "42" out of a number the
    // collector requires to be a string, so the two halves would disagree about
    // a row the settings page still draws.
    check(`slug(${JSON.stringify(v)}) on a non-string is empty`,
          Accounts.slug(v) === "", Accounts.slug(v));
}
check("MAX_ID_LENGTH in Accounts.js matches the shared table",
      typeof Accounts.MAX_ID_LENGTH === "number"
          ? Accounts.MAX_ID_LENGTH === SLUGS.maxLength
          : true, "MAX_ID_LENGTH not exported");

// A separator in an id would put the account's state files in a subdirectory that
// does not exist, so the id has to be a plain word.
for (const raw of ["a/b", "a\\b", "../etc", "a b", "a;b"]) {
    const s = Accounts.slug(raw);
    check(`slug(${JSON.stringify(raw)}) has no separator`, !/[^a-z0-9_]/.test(s), s);
}

// --- defaultLabel ----------------------------------------------------------
check("defaultLabel drops the leading dot", Accounts.defaultLabel("/home/u/.claude") === "claude",
      Accounts.defaultLabel("/home/u/.claude"));
check("defaultLabel keeps the rest", Accounts.defaultLabel("/home/u/.claude-dad") === "claude-dad",
      Accounts.defaultLabel("/home/u/.claude-dad"));
check("defaultLabel ignores a trailing slash", Accounts.defaultLabel("/home/u/.claude-dad/") === "claude-dad",
      Accounts.defaultLabel("/home/u/.claude-dad/"));

// --- usageFile -------------------------------------------------------------
// The primary account keeps the configured path verbatim: that is what keeps a
// hand-written collector working, and what keeps usage.json's name stable.
check("primary keeps the base path",
      Accounts.usageFile("~/.local/state/kclaude/usage.json", "claude", 0) ===
      "~/.local/state/kclaude/usage.json");
check("second account is a suffixed sibling",
      Accounts.usageFile("~/.local/state/kclaude/usage.json", "claude_dad", 1) ===
      "~/.local/state/kclaude/usage-claude_dad.json",
      Accounts.usageFile("~/.local/state/kclaude/usage.json", "claude_dad", 1));
check("a custom base path is still honoured for the primary",
      Accounts.usageFile("/tmp/mine.json", "a", 0) === "/tmp/mine.json");
// And the suffix has to match what the collector derives, which is slug(id).
check("the filename slugs the id, not the raw one",
      Accounts.usageFile("/tmp/u.json", "Claude Dad", 1) === "/tmp/usage-claude_dad.json",
      Accounts.usageFile("/tmp/u.json", "Claude Dad", 1));
check("root-level base path",
      Accounts.usageFile("/usage.json", "x", 1) === "/usage-x.json",
      Accounts.usageFile("/usage.json", "x", 1));

// Two accounts must never land on the same file.
const seen = new Set();
for (let i = 0; i < 8; i++) {
    seen.add(Accounts.usageFile("/tmp/s/usage.json", `acct${i}`, i));
}
check("every account gets a distinct usage file", seen.size === 8, seen.size);

// --- writeFile -------------------------------------------------------------
// The one command here that writes, and the only place a label the user typed
// becomes a command's *output* rather than its input.
const tmp = fs.mkdtempSync(path_mod.join(os.tmpdir(), "kclaude-acct-"));
const target = path_mod.join(tmp, "nested", "deeper", "accounts.json");

const payloads = [
    '{"version":1,"accounts":[]}',
    // A "%" in a label is the trap: printf would eat it as a format specifier if
    // the payload were the format string rather than an argument.
    '{"label":"50% off"}',
    '{"label":"100%s %d %n"}',
    // Quotes, backslashes, newlines and command substitution all have to arrive
    // as literal text.
    '{"label":"it\'s \\"mine\\""}',
    '{"label":"a\nb"}',
    '{"label":"$(touch /tmp/kclaude-PWNED)"}',
    '{"label":"`id`"}',
    '{"label":"x; rm -rf /"}',
    '{"label":"~/not/expanded"}',
    '{"label":"' + "'" + '"}',
];

for (const payload of payloads) {
    sh(Shell.writeFile(target, payload));
    check(`writeFile round-trips ${JSON.stringify(payload)}`,
          fs.readFileSync(target, "utf8") === payload,
          JSON.stringify(fs.readFileSync(target, "utf8")));
}

// The permission bits of a path. Node's Stats has gone by both names depending
// on the build, so ask for whichever is there rather than silently reading
// undefined and concluding the file has no permissions at all.
function perms(p) {
    const st = fs.statSync(p);
    const mode = st.st_mode !== undefined ? st.st_mode : st.mode;
    return mode & 0o777;
}

// The mode is set explicitly rather than inherited, so it is the same whatever
// umask the config dialog happens to have been started under.
check("writeFile sets 0600 regardless of umask", perms(target) === 0o600,
      "mode was " + perms(target).toString(8));
try {
    sh("umask 000 && " + Shell.writeFile(target, '{"a":1}'));
    check("a permissive umask does not widen the file", perms(target) === 0o600,
          "mode was " + perms(target).toString(8));
} catch (e) {
    // Some shells refuse to change umask mid-command; the check above still holds.
}

// A umask cannot help here, because `> file` truncates an existing file without
// touching its mode -- so re-saving an accounts.json has to tighten it itself.
fs.chmodSync(target, 0o666);
sh(Shell.writeFile(target, '{"reSaved":true}'));
check("re-saving tightens a file that was too permissive", perms(target) === 0o600,
      "mode was " + perms(target).toString(8));
check("re-saving still wrote the payload", fs.readFileSync(target, "utf8") === '{"reSaved":true}');

// A label that tries to run something must not, and must not create the file it
// was trying to create.
const marker = path_mod.join(tmp, "PWNED");
sh(Shell.writeFile(path_mod.join(tmp, "evil.json"), `{"l":"$(touch ${marker})"}`));
check("no command execution through the written payload", !fs.existsSync(marker));

// A path with a space and a quote in it still writes where it was asked to.
const odd = path_mod.join(tmp, "it's a dir", "a b.json");
sh(Shell.writeFile(odd, '{"ok":1}'));
check("odd paths are written verbatim", fs.existsSync(odd) &&
      fs.readFileSync(odd, "utf8") === '{"ok":1}');

// A "~" in the written path has to expand, or the file lands in a literal ~ dir.
const homeTarget = path_mod.join(os.homedir(), ".config", "kclaude", "tst-write-probe.json");
try {
    sh(Shell.writeFile("~/.config/kclaude/tst-write-probe.json", '{"probe":1}'));
    check("tilde expands in a written path", fs.existsSync(homeTarget));
} finally {
    try { fs.unlinkSync(homeTarget); } catch (e) { /* nothing written */ }
}
try { fs.rmdirSync(path_mod.join(os.homedir(), ".config", "kclaude")); } catch (e) { /* not ours */ }

// dirName is what decides what gets created, so it is pinned directly.
check("dirName of a nested path", Shell.dirName("/a/b/c.json") === "/a/b");
check("dirName of a root file", Shell.dirName("/c.json") === "/");
check("dirName of a bare name", Shell.dirName("c.json") === "");
check("dirName of a trailing slash", Shell.dirName("/a/b/") === "/a/b");

// --- hasCredentials --------------------------------------------------------
// Existence only, on purpose: the file holds live OAuth tokens and a config
// dialog must not pull one into its own process.
// test -f exits non-zero when the file is absent, which is the answer, not a
// failure -- so "present" is the exit status, inverted.
function testFails(command) {
    try {
        sh(command);
        return false;
    } catch (e) {
        return true;
    }
}

const cfgDir = path_mod.join(tmp, "claude-cfg");
fs.mkdirSync(cfgDir);
check("no credentials file means no", testFails(Shell.hasCredentials(cfgDir)));

fs.writeFileSync(path_mod.join(cfgDir, ".credentials.json"), "{}");
check("a credentials file is detected", !testFails(Shell.hasCredentials(cfgDir)));

// A path with a quote must not break the test into running something.
check("a quoted path still reports honestly",
      testFails(Shell.hasCredentials(path_mod.join(tmp, "no'quote'dir"))));

// --- findConfigDirs --------------------------------------------------------
fs.mkdirSync(path_mod.join(tmp, "home", ".claude-work"), { recursive: true });
fs.mkdirSync(path_mod.join(tmp, "home", ".claude"), { recursive: true });
// A file that matches the glob must not be offered as a config directory.
fs.writeFileSync(path_mod.join(tmp, "home", ".claude.json"), "{}");
const found = sh(Shell.findConfigDirs(path_mod.join(tmp, "home"), 1))
    .split("\n").map(s => s.trim()).filter(s => s.length > 0).sort();
check("scan finds both config dirs", found.length === 2, JSON.stringify(found));
check("scan excludes a matching file", !found.some(f => f.endsWith(".claude.json")),
      JSON.stringify(found));
check("scan returns the directories", found.every(f => f.indexOf(path_mod.join(tmp, "home")) === 0),
      JSON.stringify(found));

// Default depth is 1, so a nested .claude somewhere else is not picked up.
fs.mkdirSync(path_mod.join(tmp, "home", "sub", ".claude-deep"), { recursive: true });
const shallow = sh(Shell.findConfigDirs(path_mod.join(tmp, "home")))
    .split("\n").filter(s => s.trim().length > 0);
check("the default depth stays at the top level", shallow.length === 2, JSON.stringify(shallow));

fs.rmSync(tmp, { recursive: true, force: true });

if (failures) {
    console.error(`\n${failures} failure(s)`);
    process.exit(1);
}
console.log("accounts: all cases pass");
