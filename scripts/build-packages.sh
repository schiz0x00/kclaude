#!/usr/bin/env bash
# Builds, into dist/:
#   kclaude-<version>.plasmoid       for the KDE Store and kpackagetool6
#   kclaude_<version>_all.deb
#   kclaude-<version>.noarch.rpm
#
#   ./scripts/build-packages.sh          # .deb and .rpm need nfpm on PATH
#
# The staging step exists because a system package and a per-user install put
# things in different places: kpackagetool6 copies a source tree, the package
# lays out /usr/share, /usr/bin and /usr/lib/systemd/user.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

# One version, from the file Plasma already reads it out of.
VERSION="$(python3 -c 'import json,sys; print(json.load(open("metadata.json"))["KPlugin"]["Version"])')"
[[ -n "$VERSION" ]] || { echo "Error: no KPlugin.Version in metadata.json" >&2; exit 1; }

STAGE="build/stage"
# dist too, not just build: leftover packages from an older version would
# otherwise sit next to the new ones and get picked up by a `dist/*` upload.
rm -rf build dist
mkdir -p "$STAGE/plasmoid" dist

# Only what belongs inside the Plasma package: not scripts/, daemon/ or docs/.
cp metadata.json LICENSE "$STAGE/plasmoid/"
cp -r contents "$STAGE/plasmoid/"

cp daemon/kclaude-daemon "$STAGE/kclaude-daemon"

# The in-repo unit points at the per-user copy install.sh makes; the package puts
# the collector on PATH instead. Fail loudly rather than shipping a unit whose
# ExecStart does not exist.
sed 's|%h/\.local/bin/kclaude-daemon|/usr/bin/kclaude-daemon|' \
    daemon/kclaude.service > "$STAGE/kclaude.service"
grep -q '^ExecStart=/usr/bin/kclaude-daemon$' "$STAGE/kclaude.service" || {
    echo "Error: could not rewrite ExecStart in daemon/kclaude.service" >&2
    exit 1
}

# The .plasmoid is just that staged tree zipped, with metadata.json at the root
# rather than inside a directory -- kpackagetool6 and the KDE Store both reject
# a nested one. Built before the nfpm gate below, so it can be produced without
# a Go toolchain installed.
#
# python3, not zip(1): the version is already read with it, and this way the
# script needs nothing that is not already required.
PLASMOID="dist/kclaude-$VERSION.plasmoid"
python3 - "$STAGE/plasmoid" "$PLASMOID" <<'PY'
import os, sys, zipfile

root, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for directory, _, files in os.walk(root):
        for name in sorted(files):
            path = os.path.join(directory, name)
            z.write(path, os.path.relpath(path, root))
PY
# A .plasmoid whose metadata is one level down installs as a broken package and
# says nothing about why, so check the one thing that makes it valid.
python3 - "$PLASMOID" <<'PY'
import sys, zipfile

names = zipfile.ZipFile(sys.argv[1]).namelist()
if "metadata.json" not in names:
    sys.exit(f"Error: {sys.argv[1]} has no metadata.json at its root (got {names[:3]}...)")
PY

if ! command -v nfpm &>/dev/null; then
    echo "Error: nfpm not found, so only the .plasmoid was built. Install with:" >&2
    echo "  go install github.com/goreleaser/nfpm/v2/cmd/nfpm@latest" >&2
    exit 1
fi

export KCLAUDE_VERSION="$VERSION"
for format in deb rpm; do
    nfpm package --config packaging/nfpm.yaml --packager "$format" --target dist/
done

echo ""
echo "Built kclaude $VERSION:"
ls -1 dist/
