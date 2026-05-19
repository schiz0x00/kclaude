// Checks Shell.js quoting against a real bash, so a future edit to the one
// shell-facing line in FileUsageProvider.qml cannot silently open an injection.
//
//   node tests/shell-quote.test.js

const fs = require("fs");
const os = require("os");
const path_mod = require("path");
const { execFileSync } = require("child_process");

const src = fs.readFileSync(path_mod.join(__dirname, "..", "contents", "code", "Shell.js"), "utf8");
// Shell.js is plain JS on purpose; eval keeps the widget and the test on one copy.
const Shell = {};
new Function("exports", src + "\nexports.quote = quote; exports.path = path;")(Shell);

const HOME = os.homedir();
let failures = 0;

function check(name, cond, detail) {
    if (cond) return;
    failures++;
    console.error(`FAIL ${name}${detail ? ": " + detail : ""}`);
}

// bash must echo the path back byte-for-byte, with ~ expanded to $HOME.
function roundTrip(input) {
    const quoted = Shell.path(input);
    let out;
    try {
        out = execFileSync("bash", ["-c", `printf '%s' ${quoted}`], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
    } catch (e) {
        // A quoter broken enough to produce unparseable shell lands here.
        check(`roundTrip(${JSON.stringify(input)})`, false, `bash rejected ${JSON.stringify(quoted)}`);
        return;
    }
    const expected = input === "~" ? HOME
        : input.startsWith("~/") ? HOME + input.slice(1)
        : input;
    check(`roundTrip(${JSON.stringify(input)})`, out === expected,
          `got ${JSON.stringify(out)} want ${JSON.stringify(expected)}`);
}

[
    "/tmp/usage.json",
    "~/.local/state/kclaude/usage.json",
    "~",
    "/tmp/with space/usage.json",
    "/tmp/it's mine/usage.json",
    "~/it's/a space/usage.json",
    "/tmp/single'quote",
    "/tmp/double\"quote",
    "/tmp/back\\slash",
    "/tmp/dollar$HOME",
    "/tmp/back`tick`",
    "/tmp/semi;colon",
    "/tmp/pipe|char",
    "/tmp/amp&and",
    "/tmp/glob*star?",
    "/tmp/newline\nhere",
    "/tmp/(parens)",
    "/tmp/{brace}",
    "/tmp/#hash",
    "/tmp/!bang",
    "/tmp/tab\there",
    "~/dollar$(id)",
    "",
].forEach(roundTrip);

// Injection attempts must arrive as literal text. Byte-identical round-tripping
// already proves nothing was substituted, so the decisive extra check is a side
// effect: if any payload executes, it creates the marker file.
const marker = fs.mkdtempSync(path_mod.join(os.tmpdir(), "shellq-")) + "/PWNED";
[
    `/tmp/x'; touch ${marker}; #`,
    `/tmp/x$(touch ${marker})`,
    "/tmp/x`touch " + marker + "`",
    `~/x'; touch ${marker}; #`,
    `~/$(touch ${marker})`,
    `/tmp/x' && touch ${marker} && echo '`,
    `/tmp/x\n touch ${marker}\n`,
].forEach((payload) => {
    roundTrip(payload);
    check(`no side effect ${JSON.stringify(payload)}`, !fs.existsSync(marker), `${marker} was created`);
});

// "~" only expands when it is the whole path or a leading "~/" segment.
check("bare tilde passthrough", Shell.path("~") === "~");
check("mid-path tilde is quoted", Shell.path("/tmp/~/x") === "'/tmp/~/x'");
check("tilde user not expanded", Shell.path("~root/x") === "'~root/x'");

if (failures) {
    console.error(`\n${failures} failure(s)`);
    process.exit(1);
}
console.log("shell-quote: all cases pass");
