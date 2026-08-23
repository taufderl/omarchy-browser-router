# omarchy-browser-router

Routes links to two different browsers based on domain, on Omarchy/Hyprland:

- Domains in a trusted list open in **Chrome** (kept as the "logged in to
  things I trust" browser).
- Everything else opens in **Brave** (the default for unknown links).

## How it works

It's a small default-browser shim, using standard XDG mechanisms -- no
Hyprland config involved:

- `bin/browser-router` is a shell script that receives a URL, extracts its
  hostname, checks it against `~/.config/browser-router/trusted-domains.txt`,
  and execs either `google-chrome-stable` or `brave` with that URL.
- `share/applications/browser-router.desktop` registers that script as an
  installed application (`NoDisplay=true`, so it doesn't clutter app
  launchers).
- `install.sh` sets it as the default handler for `http`/`https`/`text/html`
  links via `xdg-mime`, which writes into `~/.config/mimeapps.list`.

A trusted domain also matches its subdomains: listing `google.com` routes
`accounts.google.com` to Chrome too. A lookalike like `evilgoogle.com` does
**not** match `google.com` -- matching is exact-or-proper-subdomain, not a
substring check.

Hostname extraction uses Node's WHATWG `URL` parser -- the same standard
Chromium implements -- rather than shell string manipulation. An earlier
version parsed hosts with shell parameter expansion, which disagreed with
Chromium on backslashes in the authority component and let a crafted link
(e.g. `https://evil.example\@trusted.example/`) get routed into the trusted
Chrome profile. See `codlex-review.md` for the full writeup. Any URL that
fails to parse, isn't `http(s)`, or that can't be parsed at all (`node`
missing) now fails closed to Brave.

## Install

```sh
./install.sh
```

This installs `browser-router` to `~/.local/bin`, registers the desktop
entry, creates `~/.config/browser-router/trusted-domains.txt` if it doesn't
already exist, and points the relevant XDG mime defaults at it. It also
records whatever was the default browser beforehand, so `uninstall.sh` can
put it back.

Safe to re-run; it won't overwrite an existing `trusted-domains.txt` or
clobber the saved previous-default record on a reinstall.

## Configure

Edit `~/.config/browser-router/trusted-domains.txt`, one domain per line,
`#` for comments:

```
# Domains that should open in Chrome instead of Brave.
google.com
work-sso.example.com
```

No reload needed -- the file is read fresh on every link click.

## Uninstall

```sh
./uninstall.sh
```

Restores whichever browser was the default before install, removes the
script and desktop entry. Leaves `~/.config/browser-router/` (your trust
list) in place by default, since it's hand-edited data. Pass `--purge` to
remove that too:

```sh
./uninstall.sh --purge
```

## Requirements

- `xdg-mime`, `update-desktop-database` (part of `xdg-utils`, standard on
  Omarchy)
- `google-chrome-stable` and `brave` on `PATH`
- `node` on `PATH`, for spec-compliant URL parsing. Without it the router
  still runs safely, but fails closed to Brave for every link (see above).

## Limitations

- Routes browser-launched links (anything going through the XDG default
  browser). An app that hardcodes its own browser launch (rare) won't go
  through this.
- Domain matching only, not full URL/path rules.
