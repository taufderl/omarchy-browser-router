# omarchy-browser-router

Routes links to whichever browser their domain is configured for, on
Omarchy/Hyprland. Supports the same browsers as `omarchy default browser
--help`: chromium, chrome, brave, brave-origin, edge, firefox, zen.

## How it works

A default-browser shim using standard XDG mechanisms -- no Hyprland config
involved:

- `bin/browser-router` is the script registered as the default web
  browser. Python, importing `browser-router-config` directly as a
  module: extracts a URL's hostname, resolves it to a browser, execs it.
- `bin/browser-router-config` owns `~/.config/browser-router/config.yaml`
  (load/validate/edit) and hostname extraction. Also a standalone CLI for
  interactive use. See [Design notes](#design-notes) for why both live
  here instead of being reimplemented in shell.
- `share/applications/browser-router.desktop` registers `browser-router`
  (`NoDisplay=true`, so it doesn't show up in app launchers).
- `install.sh` points XDG's mime defaults at it via `xdg-mime`.
- `shell-plugin/browser-router.ask/` is a local Quickshell plugin -- the
  popup for [ask mode](#ask-mode).

Any failure -- an unparseable URL, a missing or invalid config, `python3`
not installed -- fails closed to `brave` directly, so a mistake can never
silently open a link in some other configured browser.

## Install

```sh
./install.sh
```

Installs both scripts to `~/.local/bin`, registers the desktop entry,
creates `~/.config/browser-router/config.yaml` from the example if it
doesn't exist, points XDG's mime defaults at it, and installs the
ask-mode popup plugin. Records the previous default browser so
`uninstall.sh` can restore it. Safe to re-run.

## Configure

`~/.config/browser-router/config.yaml`:

```yaml
default: brave

chrome:
  - google.com
  - work-sso.example.com

chromium:
  - internal.example

brave: []
brave-origin: []
edge: []
firefox: []
zen: []
```

- `default` names a browser, or the literal value `ask` to turn on [ask
  mode](#ask-mode) -- used for any domain not listed elsewhere. A URL
  that can't be parsed at all still falls back to a real browser
  regardless of this setting.
- Listing a domain covers its subdomains too: `google.com` covers
  `accounts.google.com`.
- A domain may only be listed under one browser.
- A more specific domain wins over a broader one in a different browser,
  regardless of declaration order: `login.example.com` in `brave` beats
  `example.com` in `chrome`. `check` flags any such overlap.

Edit the file directly, or:

```sh
browser-router-config              # usage
browser-router-config check        # validate; shows default, each
                                    # nonzero browser's domain count, and
                                    # warnings (not installed, overlaps)
browser-router-config add chrome google.com
browser-router-config default              # print the current default
browser-router-config default brave        # change it
browser-router-config default ask          # turn on ask mode
```

`add` rewrites the whole file, so hand-added comments won't survive it.

## Ask mode

With `default: ask`, a domain with no explicit route pops up a dialog
instead of silently opening in a fixed browser: pick one of your
*installed* browsers, and **Once** or **Remember** (default: Remember).
Remember adds the domain to the browser you picked (same as
`browser-router-config add`) and opens it there; Once just opens it.

Only triggers once everything else is healthy: URL parsed, config valid,
this hostname has no explicit route. Every fail-closed path above is
unaffected -- `ask` only replaces "silently open in a fixed browser",
never any of those. The no-URL case never asks either (there's no domain
to show); it opens `default` if that's a real browser, or `brave` if
`default` is itself `ask`.

No answer within 30 seconds, or a second unmatched link while the dialog
is already open, both fall back to `brave` -- same as cancelling.

## Uninstall

```sh
./uninstall.sh            # add --purge to also remove your config
```

Restores the previous default browser, removes both scripts, the desktop
entry, and the popup plugin. Leaves `~/.config/browser-router/` (your
config) in place unless `--purge` is given.

## Requirements

- `xdg-mime`, `update-desktop-database` (`xdg-utils`, standard on
  Omarchy)
- `python3` with PyYAML (`python-yaml`)
- Whichever browsers your config routes to, installed the way `omarchy
  install browser <name>` installs them

Missing `python3`/PyYAML fails every link closed to `brave`, and
`install.sh` warns about it. Same for `omarchy-shell` if `default: ask`
is set -- without it, every domain falls back to `brave` instead of
prompting.

## Design notes

An earlier version parsed URLs with shell string manipulation. It
disagreed with Chromium on backslashes in the authority component
(`https://evil.example\@trusted.example/` read as `trusted.example` in
the shell, `evil.example` in Chromium), letting a crafted link bypass
routing -- see `docs/codex-review.md`. The fix was Node's `URL`, a real
WHATWG parser, since Python's `urllib.parse` and GLib's `GUri` both get
that exact case wrong too (verified directly, see `TODO.md`).

Node is gone now. `extract_host()` in `bin/browser-router-config`
doesn't parse URLs so much as recognize a narrow, provably-unambiguous
subset of them (plain ASCII scheme+host+port, no userinfo, no
percent-encoding, no backslashes) and reject everything else -- verified
by cross-checking every accepted case against Node's real `URL()`
output. A rejected URL just falls back to the default browser, same as
any other unparseable input; nothing is lost except per-domain routing
for URLs that were never common in practice anyway.

`bin/browser-router` imports `browser-router-config` directly rather
than shelling out to it, so there's no subprocess/argv boundary between
our own two components -- one less thing that needed `--` treatment
(see `docs/claude-review.md`'s finding on exactly that). The one
external boundary that remains is the final exec of a real browser,
which still gets `--` before the URL.

Browser ids resolve to an executable via the `Exec=` line of the
matching `.desktop` file, the same way `omarchy-launch-browser` does,
rather than a hardcoded id -> binary table (AUR packaging doesn't
reliably name the binary after the package). This means
`resolve_binary()` trusts whatever `.desktop` file it finds under
`~/.local/share/applications` -- not a new privilege boundary (anything
that can write there already runs as this user), just worth naming.

Editing `shell-plugin/browser-router.ask/AskPopup.qml`: Quickshell's
hot-reload can leave a `keepLoaded` overlay's *visual* tree stale after
rapid edits even though its backend state stays correct, which makes
this easy to misdiagnose. `omarchy restart shell` after an edit is the
reliable way to see the real result.

## Limitations

- Routes browser-launched links (anything going through the XDG default
  browser). An app that hardcodes its own browser launch won't go
  through this.
- Domain matching only, not full URL/path rules.
