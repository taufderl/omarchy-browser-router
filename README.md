# omarchy-browser-router

Routes links to whichever browser their domain is configured for, on
Omarchy/Hyprland. Supports google-chrome, chromium, brave, and firefox (for
now -- adding another browser is a two-line change).

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

google-chrome:
  - google.com
  - work-sso.example.com

chromium:
  - internal.example

brave: []

firefox: []
```

- `default` is required and must name one of the known browsers -- used
  for any domain not listed elsewhere, and as the fallback when a URL can't
  be parsed at all.
- Listing a domain also covers its subdomains: `google.com` covers
  `accounts.google.com`.
- A domain may only be listed under one browser.

Edit the file directly, or use the helper:

```sh
browser-router-config              # usage
browser-router-config check        # validate the config, warn about
                                    # configured browsers missing from PATH
browser-router-config add google-chrome google.com
```

`add` refuses domains that don't look like a plain hostname (no scheme,
path, or `@`) and domains already routed to a different browser. Note:
`add` rewrites the whole file, so hand-added comments won't survive it --
if you want to keep comments, edit by hand and skip `add`.

No reload needed either way -- the config is read fresh on every link
click.

## Uninstall

```sh
./uninstall.sh
```

Restores whichever browser was the default before install, removes both
scripts and the desktop entry. Leaves `~/.config/browser-router/` (your
config) in place by default, since it's hand-edited data. Pass `--purge` to
remove that too:

```sh
./uninstall.sh --purge
```

## Requirements

- `xdg-mime`, `update-desktop-database` (part of `xdg-utils`, standard on
  Omarchy)
- `node`, for spec-compliant URL parsing
- `python3` with PyYAML (Arch/Omarchy package: `python-yaml`), for config
  parsing and routing
- Whichever of `google-chrome-stable`, `chromium`, `brave`, `firefox` your
  config actually routes to

Missing `node` or `python3`/PyYAML doesn't break anything -- every link
just fails closed to `brave` (see above), and `install.sh` warns about it.

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

## Limitations

- Routes browser-launched links (anything going through the XDG default
  browser). An app that hardcodes its own browser launch (rare) won't go
  through this.
- Domain matching only, not full URL/path rules.
