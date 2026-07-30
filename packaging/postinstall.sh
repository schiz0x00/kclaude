#!/bin/sh
# Runs as root, for every user on the machine. It therefore does NOT enable the
# collector: that unit reads ~/.claude/.credentials.json, and `systemctl --global
# enable` would turn it on for everyone without anybody choosing to. Same reason
# install.sh keeps --with-daemon opt-in. See the Security section of the README.
set -e

if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor 2>/dev/null || true
fi

cat <<'EOF'
kclaude installed.

  Add the widget:      right-click the panel -> Add Widgets... -> "kclaude"
  Start the collector: systemctl --user enable --now kclaude.service

The collector reads and refreshes the OAuth token in ~/.claude/.credentials.json.
It is not enabled for you automatically: /usr/share/doc/kclaude/README.md
EOF
