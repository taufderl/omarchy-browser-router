#!/bin/bash
# Installs omarchy-browser-router and makes it the default web browser handler.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

BIN_DEST="$HOME/.local/bin/browser-router"
DESKTOP_DEST="$HOME/.local/share/applications/browser-router.desktop"
CONFIG_DIR="$HOME/.config/browser-router"
TRUSTED_FILE="$CONFIG_DIR/trusted-domains.txt"
PREVIOUS_DEFAULT_FILE="$CONFIG_DIR/previous-default.desktop"

MIME_TYPES=(
  text/html
  x-scheme-handler/http
  x-scheme-handler/https
  x-scheme-handler/about
  x-scheme-handler/unknown
)

for cmd in xdg-mime update-desktop-database; do
  command -v "$cmd" >/dev/null || { echo "Missing required command: $cmd" >&2; exit 1; }
done

for browser in google-chrome-stable brave; do
  command -v "$browser" >/dev/null || echo "Warning: '$browser' not found on PATH. Install it or routing to it will fail." >&2
done

mkdir -p "$HOME/.local/bin" "$HOME/.local/share/applications" "$CONFIG_DIR"

install -m 755 "$SCRIPT_DIR/bin/browser-router" "$BIN_DEST"
install -m 644 "$SCRIPT_DIR/share/applications/browser-router.desktop" "$DESKTOP_DEST"

if [[ ! -f $TRUSTED_FILE ]]; then
  install -m 644 "$SCRIPT_DIR/config/trusted-domains.txt.example" "$TRUSTED_FILE"
  echo "Created $TRUSTED_FILE (empty trust list -- edit it to add domains)"
else
  echo "Keeping existing $TRUSTED_FILE"
fi

# Remember what was the default before we take it over, so uninstall.sh can
# restore it. Only capture this once: on a reinstall, the current default is
# already browser-router.desktop, which would make a useless backup.
current_default="$(xdg-mime query default x-scheme-handler/https 2>/dev/null || true)"
if [[ -n $current_default && $current_default != "browser-router.desktop" && ! -f $PREVIOUS_DEFAULT_FILE ]]; then
  echo "$current_default" >"$PREVIOUS_DEFAULT_FILE"
  echo "Saved previous default browser ($current_default) for uninstall.sh to restore"
fi

update-desktop-database "$HOME/.local/share/applications"

for mime in "${MIME_TYPES[@]}"; do
  xdg-mime default browser-router.desktop "$mime"
done

echo
echo "Installed. Current defaults:"
for mime in "${MIME_TYPES[@]}"; do
  echo "  $mime -> $(xdg-mime query default "$mime")"
done
echo
echo "Edit $TRUSTED_FILE to choose which domains open in Chrome."
