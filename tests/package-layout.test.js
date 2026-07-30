// Checks the Plasma package layout, which nothing else validates.
//
//   node tests/package-layout.test.js
//
// ConfigCategory.source is resolved by Plasma against contents/ui/, NOT against
// contents/config/ where config.qml itself lives. Putting the page in
// contents/config/ makes the config dialog render a blank panel with no error
// anywhere the user can see, so this is worth pinning.

const fs = require("fs");
const path = require("path");

const repo = path.join(__dirname, "..");
let failures = 0;

function check(name, cond, detail) {
    if (cond) return;
    failures++;
    console.error(`FAIL ${name}${detail ? ": " + detail : ""}`);
}

function read(rel) {
    return fs.readFileSync(path.join(repo, rel), "utf8");
}

// Every ConfigCategory source must exist under contents/ui/.
const configQml = read("contents/config/config.qml");
const sources = [...configQml.matchAll(/source:\s*"([^"]+)"/g)].map(m => m[1]);
check("config.qml declares at least one page", sources.length > 0);
for (const src of sources) {
    const resolved = path.join("contents", "ui", src);
    check(`ConfigCategory source "${src}" resolves`, fs.existsSync(path.join(repo, resolved)),
          `expected ${resolved} (Plasma resolves config sources against contents/ui/)`);
    check(`"${src}" is not left in contents/config/`,
          !fs.existsSync(path.join(repo, "contents", "config", src)),
          `a stale copy in contents/config/${src} will not be loaded`);
}

// Files the package structure requires.
for (const required of ["metadata.json", "contents/ui/main.qml",
                        "contents/config/config.qml", "contents/config/main.xml"]) {
    check(`${required} exists`, fs.existsSync(path.join(repo, required)));
}

// Every cfg_ alias in the config page must have a matching kcfg entry, and the
// reverse: Plasma injects one property per key and drops settings that are
// declared in only one of the two places.
const page = read(path.join("contents", "ui", sources[0] || "configGeneral.qml"));
const aliases = new Set([...page.matchAll(/property\s+(?:alias|int|bool|string|real)\s+(cfg_\w+)/g)]
    .map(m => m[1]));
const entries = new Set([...read("contents/config/main.xml").matchAll(/<entry\s+name="(\w+)"/g)]
    .map(m => "cfg_" + m[1]));
for (const a of aliases) {
    check(`${a} has a kcfg entry`, entries.has(a), "declared in the form but not in main.xml");
}
for (const e of entries) {
    check(`${e} has a control`, aliases.has(e), "declared in main.xml but not exposed by the form");
}

// The icon has to resolve from inside the package. A store install goes through
// kpackagetool6 and copies nothing into hicolor, so an Icon name with no
// matching contents/icons/<name>.svg shows a generic placeholder in Add Widgets
// -- and only for the users who arrive that way, which is why it survives every
// local install test.
const metadata = JSON.parse(read("metadata.json"));
const iconName = metadata.KPlugin.Icon;
check(`contents/icons/${iconName}.svg exists`,
      fs.existsSync(path.join(repo, "contents", "icons", `${iconName}.svg`)),
      `metadata.json Icon is "${iconName}", so the package needs contents/icons/${iconName}.svg`);

// The metadata id has to match what the scripts install and remove.
const id = metadata.KPlugin.Id;
for (const script of ["scripts/install.sh", "scripts/uninstall.sh"]) {
    check(`${script} uses the metadata id`, read(script).includes(`PACKAGE_ID="${id}"`),
          `expected PACKAGE_ID="${id}"`);
}

if (failures) {
    console.error(`\n${failures} failure(s)`);
    process.exit(1);
}
console.log(`package-layout: ok (${sources.length} config page(s), ${aliases.size} settings, id ${id})`);
