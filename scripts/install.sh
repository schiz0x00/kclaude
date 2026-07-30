#!/usr/bin/env bash
set -euo pipefail

INSTALL_DAEMON=false
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGE_ID="io.github.schiz0x00.kclaude"

usage() {
    echo "Usage: $0 [--with-daemon]"
    echo "  --with-daemon    Also install and enable the systemd usage daemon"
    exit 1
}

# `read` returns non-zero at EOF, which `set -e` turns into a silent exit
# mid-install. Honour piped answers, fall back to the default only at real EOF.
ask() {
    local prompt="$1" default="$2" reply
    if read -rp "$prompt " reply; then
        # bash suppresses -p when stdin is not a tty; echo what we consumed.
        [[ -t 0 ]] || echo "$prompt $reply"
    else
        echo "$prompt $default (no input, using default)"
        reply="$default"
    fi
    [[ "${reply:-$default}" =~ ^[Yy]$ ]]
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --with-daemon) INSTALL_DAEMON=true ;;
        -h|--help) usage ;;
        *) usage ;;
    esac
    shift
done

echo "Checking dependencies..."

if ! command -v kpackagetool6 &>/dev/null; then
    echo "Error: kpackagetool6 not found. Install plasma-sdk or kpackage."
    exit 1
fi

if ! command -v plasmashell &>/dev/null; then
    echo "Warning: plasmashell not found. Make sure Plasma 6 is installed."
fi

if $INSTALL_DAEMON && ! command -v python3 &>/dev/null; then
    echo "Error: python3 not found, required by the daemon."
    exit 1
fi

# kpackagetool6 copies the whole source directory, so stage only what belongs in
# the package. Otherwise scripts/, daemon/ and the docs get installed too.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp "$PROJECT_DIR/metadata.json" "$STAGE/"
cp -r "$PROJECT_DIR/contents" "$STAGE/"
[[ -f "$PROJECT_DIR/LICENSE" ]] && cp "$PROJECT_DIR/LICENSE" "$STAGE/"

WIDGET_CHANGED=false
if kpackagetool6 --type Plasma/Applet --list 2>/dev/null | grep -q "$PACKAGE_ID"; then
    echo "Widget '$PACKAGE_ID' is already installed."
    if ask "Upgrade? [Y/n]:" Y; then
        echo "Upgrading widget..."
        kpackagetool6 --type Plasma/Applet --upgrade "$STAGE" || {
            echo "Upgrade failed. Try removing and reinstalling."
            exit 1
        }
        WIDGET_CHANGED=true
    else
        echo "Skipping widget installation."
    fi
else
    echo "Installing widget..."
    kpackagetool6 --type Plasma/Applet --install "$STAGE" || {
        echo "Installation failed."
        exit 1
    }
    WIDGET_CHANGED=true
fi

# The widget itself loads the bundled SVG directly; this copy is only so the
# "Add Widgets" browser can resolve metadata.json's Icon name.
ICON_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/scalable/apps"
mkdir -p "$ICON_DIR"
cp "$PROJECT_DIR/contents/icons/claude.svg" "$ICON_DIR/kclaude.svg"

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/kclaude"
mkdir -p "$STATE_DIR"
echo "Created state directory: $STATE_DIR"

if $INSTALL_DAEMON; then
    echo "Installing daemon..."
    echo "Note: the daemon reads, and refreshes, the OAuth token in"
    echo "      ~/.claude/.credentials.json. See the README Security section."

    mkdir -p "$HOME/.local/bin"
    cp "$PROJECT_DIR/daemon/kclaude-daemon" "$HOME/.local/bin/kclaude-daemon"
    chmod +x "$HOME/.local/bin/kclaude-daemon"

    mkdir -p "$HOME/.config/systemd/user"
    cp "$PROJECT_DIR/daemon/kclaude.service" "$HOME/.config/systemd/user/kclaude.service"

    systemctl --user daemon-reload
    # reenable (not enable) so a changed [Install] section drops stale symlinks.
    systemctl --user reenable kclaude.service
    systemctl --user restart kclaude.service
    echo "Daemon installed and started."
fi

echo ""
echo "Installation complete!"
echo "Add the widget to your panel:"
echo "  1. Right-click the panel -> Add Widgets..."
echo "  2. Search for 'kclaude'"
echo "  3. Click to add"

# plasmashell caches applet QML, so an upgrade is invisible until it restarts.
if $WIDGET_CHANGED && command -v plasmashell &>/dev/null; then
    echo ""
    if [[ ! -t 0 ]]; then
        # Never restart someone's desktop shell unattended, whatever the default
        # would have been: a piped install must not blank the screen.
        echo "Run 'systemctl --user restart plasma-plasmashell.service' to load the new version."
    elif ask "Restart plasmashell now to load the new version? [Y/n]:" Y; then
        # Plasma is only under systemd when the session was started that way;
        # otherwise the unit exists but is dead and restarting it spawns a
        # second shell that immediately loses the D-Bus name.
        if systemctl --user is-active --quiet plasma-plasmashell.service; then
            systemctl --user restart plasma-plasmashell.service
        else
            # Keep stderr: discarding it throws away every QML error the applet
            # produces, which makes a broken widget impossible to diagnose.
            (setsid plasmashell --replace >/dev/null 2>>"$STATE_DIR/plasmashell.log" &)
            echo "plasmashell errors are logged to $STATE_DIR/plasmashell.log"
        fi
        echo "plasmashell restarting."
    else
        echo "Run 'systemctl --user restart plasma-plasmashell.service' to pick up changes."
    fi
fi
