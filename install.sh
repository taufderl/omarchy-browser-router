#!/bin/bash
# Installs omarchy-browser-router and makes it the default web browser handler.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

BIN_DEST="$HOME/.local/bin/browser-router"
CONFIG_TOOL_DEST="$HOME/.local/bin/browser-router-config"
DESKTOP_DEST="$HOME/.local/share/applications/browser-router.desktop"
CONFIG_DIR="$HOME/.config/browser-router"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
PREVIOUS_DEFAULT_FILE="$CONFIG_DIR/previous-default.desktop"

PLUGIN_ID="browser-router.ask"
PLUGIN_SRC="$SCRIPT_DIR/shell-plugin/$PLUGIN_ID"
PLUGIN_DEST="$HOME/.config/omarchy/plugins/$PLUGIN_ID"

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

command -v node >/dev/null || echo "Warning: 'node' not found on PATH. It's required for safe hostname parsing (see codlex-review.md) -- without it every link fails closed to brave." >&2

if command -v python3 >/dev/null; then
  python3 -c "import yaml" 2>/dev/null || echo "Warning: PyYAML not found for python3 (Arch/Omarchy package: python-yaml). Without it, config validation and routing fail closed to brave." >&2
else
  echo "Warning: 'python3' not found on PATH. It's required for config validation and routing; without it every link fails closed to brave." >&2
fi

mkdir -p "$HOME/.local/bin" "$HOME/.local/share/applications" "$CONFIG_DIR"

install -m 755 "$SCRIPT_DIR/bin/browser-router" "$BIN_DEST"
install -m 755 "$SCRIPT_DIR/bin/browser-router-config" "$CONFIG_TOOL_DEST"
install -m 644 "$SCRIPT_DIR/share/applications/browser-router.desktop" "$DESKTOP_DEST"

if [[ ! -f $CONFIG_FILE ]]; then
  install -m 644 "$SCRIPT_DIR/config/config.yaml.example" "$CONFIG_FILE"
  echo "Created $CONFIG_FILE (default: brave, no domains routed yet -- edit it or use browser-router-config add)"
else
  echo "Keeping existing $CONFIG_FILE"
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

# Ask mode's popup. No user-authored content in this directory -- always
# safe to overwrite wholesale on reinstall/update.
if [[ -d $PLUGIN_SRC ]]; then
  plugin_preexisted=0
  [[ -d $PLUGIN_DEST ]] && plugin_preexisted=1

  mkdir -p "$(dirname "$PLUGIN_DEST")"
  rm -rf "$PLUGIN_DEST"
  cp -r "$PLUGIN_SRC" "$PLUGIN_DEST"

  if command -v omarchy-shell >/dev/null; then
    omarchy-shell shell rescanPlugins >/dev/null 2>&1 || echo "Warning: could not rescan omarchy-shell plugins -- ask mode's popup won't load until this succeeds" >&2
    omarchy-shell shell enablePlugin "$PLUGIN_ID" '{}' >/dev/null 2>&1 || true
    if (( plugin_preexisted )); then
      echo "Note: an update to an already-loaded ask-mode popup needs a shell restart to fully take effect (a rescan alone can leave stale content showing) -- run: omarchy restart shell"
    fi
  else
    echo "Warning: 'omarchy-shell' not found -- ask mode's popup won't work; default: ask will fail closed to brave instead" >&2
  fi
else
  echo "Warning: shell-plugin/$PLUGIN_ID not found in this checkout, skipping ask-mode popup install" >&2
fi

echo
echo "Installed. Current defaults:"
for mime in "${MIME_TYPES[@]}"; do
  echo "  $mime -> $(xdg-mime query default "$mime")"
done
echo
"$CONFIG_TOOL_DEST" check --config "$CONFIG_FILE" || true
echo
echo "Edit $CONFIG_FILE, or run: browser-router-config add <browser> <domain>"
