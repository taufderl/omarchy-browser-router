# TODO

## Resolved: dropped the Node dependency

`bin/browser-router` used to shell out to `node` for WHATWG-correct
hostname extraction, since Python's `urllib.parse` and GLib's `GUri`
both mishandle backslashes in the authority component the same way the
original vulnerable bash parser did (verified directly against the
`docs/codex-review.md` attack URL -- both return `trusted.example` for
`https://evil.example\@trusted.example/login`, not `evil.example`).

Fixed without Node and without shipping a C binary (`ada` was the only
real WHATWG-compliant alternative, C-only, rejected for that reason):
`extract_host()` in `bin/browser-router-config` doesn't fully parse
URLs, it recognizes a narrow ASCII-only subset (no userinfo, no
percent-encoding, no backslashes) where no parser could disagree, and
fails closed on everything else. Cross-checked every accepted case
against real Node `URL()` output for equivalence. `bin/browser-router`
is now pure Python, importing `browser-router-config` directly instead
of shelling out to it -- one runtime, no subprocess boundary between our
own two components. See README.md's Design notes for the details.

## Why bin/browser-router handles --help at all (not our design choice)

`bin/browser-router` is the system default browser's `Exec` target, so
`omarchy-launch-browser` (Omarchy core, never edit it) goes through it.
That script runs, on **every single invocation, with no caching**:

```bash
if $browser_exec --help 2>/dev/null | grep -q MOZ_LOG; then
  private_flag="--private-window"
...
```

-- probing `browser_exec --help` to sniff Firefox-vs-Chromium flag
naming before the real launch. So every link costs two spawns of
`browser-router`: the probe, then the real one.

This is why `-h`/`--help` are special-cased instead of just failing
closed like any other non-URL input would (the bug this fixed: a
tailscale link opened Brave navigated to the literal text `--help`,
because the probe isn't a URL). Not optional -- `omarchy-launch-browser`
does this regardless of whether `browser-router` handles it well, since
it has no way to know it's talking to a dispatcher, not a real browser.
