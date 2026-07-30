#!/usr/bin/env bash
set -euo pipefail

PACKAGE_ID="io.github.schiz0x00.kclaude"

# `read` returns non-zero at EOF, which `set -e` turns into a silent exit.
# Honour piped answers; at real EOF fall back to the default, and every prompt
# here defaults to N so an unattended run removes nothing destructive.
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

if ! command -v kpackagetool6 &>/dev/null; then
    echo "Error: kpackagetool6 not found."
    exit 1
fi

if ! kpackagetool6 --type Plasma/Applet --list 2>/dev/null | grep -q "$PACKAGE_ID"; then
    echo "Widget '$PACKAGE_ID' is not installed."
else
    echo "Removing widget..."
    kpackagetool6 --type Plasma/Applet --remove "$PACKAGE_ID" || {
        echo "Failed to remove widget."
        exit 1
    }
    echo "Widget removed."
fi

rm -f "${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/scalable/apps/kclaude.svg"

echo ""
echo "Remove daemon files? This stops the background service."
if ask "Remove daemon? [y/N]:" N; then
    echo "Stopping daemon service..."
    systemctl --user stop kclaude.service 2>/dev/null || true
    systemctl --user disable kclaude.service 2>/dev/null || true

    rm -f "$HOME/.local/bin/kclaude-daemon"
    rm -f "$HOME/.config/systemd/user/kclaude.service"

    systemctl --user daemon-reload
    echo "Daemon removed."
fi

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/kclaude"
if [[ -d "$STATE_DIR" ]]; then
    echo ""
    echo "Remove state data at $STATE_DIR?"
    echo "This deletes the collected usage snapshot."
    if ask "Remove state data? [y/N]:" N; then
        rm -rf "$STATE_DIR"
        echo "State data removed."
    fi
fi

echo ""
echo "Uninstall complete."
echo "Your Claude Code credentials in ~/.claude/ were not touched."
