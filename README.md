# omarchy-browser-router

Routes links to whichever browser their domain is configured for, on
Omarchy/Hyprland. Supports the same browsers as `omarchy default browser
--help`: chromium, chrome, brave, brave-origin, edge, firefox, zen.

## How it works

A default-browser shim using standard XDG mechanisms -- no Hyprland config
involved:

- `bin/browser-router` is the script registered as the default web browser.
  It extracts a URL's hostname (via Node's WHATWG `URL` parser -- the same
  standard Chromium implements) and asks `browser-router-config` which
  browser that hostname routes to.
- `bin/browser-router-config` owns `~/.config/browser-router/config.yaml`:
  loading, validating, resolving a hostname to a browser, and editing it.
  Written in Python with PyYAML rather than reimplementing a YAML parser in
  shell -- see [Design notes](#design-notes).
- `share/applications/browser-router.desktop` registers `browser-router` as
  an installed application (`NoDisplay=true`, so it doesn't show up in app
  launchers).
- `install.sh` points the relevant XDG mime defaults at it via `xdg-mime`,
  which writes into `~/.config/mimeapps.list`.
- `shell-plugin/browser-router.ask/` is a local Omarchy/Quickshell plugin --
  the popup shown in [ask mode](#ask-mode) for a domain with no explicit
  route.

Any failure along the way -- an unparseable URL, a missing or invalid
config, `node`/`python3` not installed -- fails closed to launching `brave`
directly, so a config mistake can never silently open a link in some other
configured browser.

## Install

```sh
./install.sh
```

Installs both scripts to `~/.local/bin`, registers the desktop entry,
creates `~/.config/browser-router/config.yaml` from the example if it
doesn't already exist, and points XDG's mime defaults at it. Also records
whatever was the default browser beforehand, so `uninstall.sh` can restore
it, and runs `browser-router-config check` at the end so you see the
resulting config's validity immediately.

Safe to re-run: won't overwrite an existing `config.yaml` or clobber the
saved previous-default record on a reinstall.

## Configure

`~/.config/browser-router/config.yaml`:

```yaml
default: brave

ask_new: false

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

- `default` is required and must name one of the known browsers -- used
  for any domain not listed elsewhere, and as the fallback when a URL can't
  be parsed at all.
- `ask_new` (optional, default `false`) turns on [ask mode](#ask-mode):
  prompt instead of silently falling back to `default` for a domain with no
  explicit route.
- Listing a domain also covers its subdomains: `google.com` covers
  `accounts.google.com`.
- A domain may only be listed under one browser.
- A more specific domain always wins over a broader one in a different
  browser, regardless of which is declared first: `login.example.com` in
  `brave` takes precedence over `example.com` in `chrome`. `check` calls
  out any such overlap so it's never a silent surprise.

Edit the file directly, or use the helper:

```sh
browser-router-config              # usage
browser-router-config check        # validate the config; prints the default,
                                    # ask_new state, and each nonzero browser's
                                    # domain count, and warns about configured
                                    # browsers that aren't installed or
                                    # overlapping routes
browser-router-config add chrome google.com
browser-router-config default              # print the current default
browser-router-config default brave        # change it
browser-router-config ask-new              # print whether ask mode is on
browser-router-config ask-new on           # turn it on
```

`add` refuses domains that don't look like a plain hostname (no scheme,
path, or `@`) and domains already routed to a different browser. Note:
`add` rewrites the whole file, so hand-added comments won't survive it --
if you want to keep comments, edit by hand and skip `add`.

No reload needed either way -- the config is read fresh on every link
click.

## Ask mode

With `ask_new: true`, a domain with no explicit route pops up an
Omarchy/Quickshell dialog instead of silently opening in `default`: pick one
of your *installed* browsers, and **Once** or **Remember** (defaults to
Remember). Remember adds the exact domain you were about to visit to the
browser you picked -- same as running `browser-router-config add` yourself
-- then opens it there; Once just opens it there without touching the
config.

Only triggers when everything else is already healthy: the URL parsed, the
config is valid, and this specific hostname has no explicit route. A URL
that won't parse, a missing `node`/`python3`, or an invalid config all still
fail closed to `brave` exactly as without ask mode -- ask mode only ever
replaces the one "silently fall back to default" branch, never any of the
fail-closed ones.

If nothing answers within 30 seconds (dialog left open, Quickshell not
running, etc.) it falls back to `default`, same as cancelling. A second
unmatched-domain link while the dialog is already open also falls back to
`default` rather than interrupting the first one.

## Uninstall

```sh
./uninstall.sh
```

Restores whichever browser was the default before install, removes both
scripts, the desktop entry, and the ask-mode popup plugin (no `--purge`
needed for the plugin -- it holds no user data). Leaves
`~/.config/browser-router/` (your config) in place by default, since it's
hand-edited data. Pass `--purge` to remove that too:

```sh
./uninstall.sh --purge
```

## Requirements

- `xdg-mime`, `update-desktop-database` (part of `xdg-utils`, standard on
  Omarchy)
- `node`, for spec-compliant URL parsing
- `python3` with PyYAML (Arch/Omarchy package: `python-yaml`), for config
  parsing and routing
- Whichever browsers your config actually routes to, installed the way
  `omarchy install browser <name>` installs them (a `.desktop` file is all
  that's required -- the actual binary is resolved from its `Exec=` line,
  the same way `omarchy-launch-browser` does, rather than a hardcoded
  binary name per browser)

Missing `node` or `python3`/PyYAML doesn't break anything -- every link
just fails closed to `brave` (see above), and `install.sh` warns about it.
Same for `omarchy-shell` (a running Omarchy Quickshell session) if
`ask_new` is on: without it, ask mode just always falls back to `default`,
same as `ask_new: false`.

## Design notes

An earlier version parsed URLs and the trust list with shell string
manipulation. That URL parsing disagreed with Chromium on backslashes in
the authority component (`https://evil.example\@trusted.example/` read as
`trusted.example` in the shell, `evil.example` in Chromium), letting a
crafted link bypass routing entirely -- see `codlex-review.md` for the full
writeup. The fix wasn't a patch to the shell logic; it was moving both URL
parsing and config parsing out of shell entirely and into an actual parser
for each (`node`'s `URL`, Python's PyYAML). `bin/browser-router` is now
just glue: extract a hostname, ask `browser-router-config resolve` what to
do with it, exec the answer.

Browser ids resolve to an actual executable by reading the `Exec=` line of
that browser's installed `.desktop` file (`chromium.desktop`,
`google-chrome.desktop`, etc. -- the same ids `omarchy-default-browser`
uses), rather than a hardcoded id -> binary-name table. AUR packaging doesn't
reliably name the binary after the package, and guessing wrong for a
browser this machine doesn't have installed (brave-origin, edge, and zen
weren't available to check against directly) is exactly the kind of thing
that should be looked up, not assumed. `omarchy-launch-browser` already
solves this the same way -- reusing its approach means one less thing to
keep in sync with Omarchy's own browser installer.

If you're editing `shell-plugin/browser-router.ask/AskPopup.qml` yourself:
Quickshell's local-plugin hot-reload (which fires automatically on file
save) reliably picks up changes to plain bar-widget-style plugins, but was
observed here to sometimes leave a `keepLoaded` overlay plugin's *visual*
tree stale (state/logic changes take effect immediately; the actual
rendered content doesn't) after several rapid edits -- backend state
(`isBusy`, etc.) staying correct made this easy to miss without actually
looking at the screen. `omarchy restart shell` after an edit is the
reliable way to see the real result; `rescanPlugins` alone isn't enough to
trust once a `keepLoaded` overlay has already been loaded once this
session.

## Limitations

- Routes browser-launched links (anything going through the XDG default
  browser). An app that hardcodes its own browser launch (rare) won't go
  through this.
- Domain matching only, not full URL/path rules.
