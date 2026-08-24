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
PLUGIN_DEST="$HOME/.config/omarchy/plugins/browser-router.ask"

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

# No user data in the plugin directory -- always safe to remove outright,
# no --purge gate needed (unlike $CONFIG_DIR).
if [[ -d $PLUGIN_DEST ]]; then
  rm -rf "$PLUGIN_DEST"
  command -v omarchy-shell >/dev/null && omarchy-shell shell rescanPlugins >/dev/null 2>&1
  echo "Removed the ask-mode popup ($PLUGIN_DEST)"
fi

# Remove the Defaults > Browser menu entry install.sh added, if present.
# Only touches this one dotted key -- leaves the rest of the user's
# extensions file untouched.
python3 - <<'PYEOF'
import os, sys

path = os.path.expanduser("~/.config/omarchy/extensions/omarchy-menu.jsonc")
key = "setup.default.browser.browser-router"
if not os.path.exists(path):
    sys.exit(0)

lines = open(path).read().splitlines()
idx = next((i for i, l in enumerate(lines) if f'"{key}"' in l), None)
if idx is None:
    sys.exit(0)

del lines[idx]
# JSON forbids a trailing comma before the closing brace -- strip one if
# our removed entry was the last real one before it.
close_idx = next((i for i in range(idx, len(lines)) if lines[i].strip() == "}"), None)
if close_idx is not None:
    prev_idx = next(
        (i for i in range(close_idx - 1, -1, -1)
         if lines[i].strip() and not lines[i].strip().startswith("//") and lines[i].strip() != "{"),
        None,
    )
    if prev_idx is not None and lines[prev_idx].rstrip().endswith(","):
        lines[prev_idx] = lines[prev_idx].rstrip()[:-1]

with open(path, "w") as f:
    f.write("\n".join(lines) + "\n")
print(f"Removed the Defaults > Browser entry for Browser Router from {path}")
PYEOF

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
