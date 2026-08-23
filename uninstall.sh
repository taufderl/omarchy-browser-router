#!/bin/bash
# Removes omarchy-browser-router and restores the previous default browser.
#
# Usage: ./uninstall.sh [--purge]
#   --purge   Also delete ~/.config/browser-router (config.yaml and the
#             saved previous-default record). Off by default, since
#             config.yaml is hand-edited user data.
set -euo pipefail

PURGE=0
[[ ${1:-} == "--purge" ]] && PURGE=1

BIN_DEST="$HOME/.local/bin/browser-router"
CONFIG_TOOL_DEST="$HOME/.local/bin/browser-router-config"
DESKTOP_DEST="$HOME/.local/share/applications/browser-router.desktop"
CONFIG_DIR="$HOME/.config/browser-router"
PREVIOUS_DEFAULT_FILE="$CONFIG_DIR/previous-default.desktop"

MIME_TYPES=(
  text/html
  x-scheme-handler/http
  x-scheme-handler/https
  x-scheme-handler/about
  x-scheme-handler/unknown
)

if [[ -f $PREVIOUS_DEFAULT_FILE ]]; then
  previous_default="$(<"$PREVIOUS_DEFAULT_FILE")"
  echo "Restoring previous default browser: $previous_default"
  for mime in "${MIME_TYPES[@]}"; do
    xdg-mime default "$previous_default" "$mime"
  done
else
  echo "No saved previous default found -- clearing browser-router as the default instead."
  echo "You may need to pick a default browser yourself, e.g.:"
  echo "  xdg-settings set default-web-browser google-chrome.desktop"
fi

rm -f "$BIN_DEST" "$CONFIG_TOOL_DEST" "$DESKTOP_DEST"
command -v update-desktop-database >/dev/null && update-desktop-database "$HOME/.local/share/applications"

if (( PURGE )); then
  rm -rf "$CONFIG_DIR"
  echo "Removed $CONFIG_DIR (config.yaml included)"
else
  echo "Left $CONFIG_DIR in place (config.yaml included). Pass --purge to remove it too."
fi

echo
echo "Uninstalled. Current defaults:"
for mime in "${MIME_TYPES[@]}"; do
  echo "  $mime -> $(xdg-mime query default "$mime" 2>/dev/null || echo "(none)")"
done
