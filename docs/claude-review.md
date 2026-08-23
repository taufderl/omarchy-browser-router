# Security review: omarchy-browser-router

Review date: 2026-08-24
Scope: all tracked application code, installer/uninstaller, desktop entry,
example configuration, and the Quickshell ask-mode plugin.
Method: source review plus dynamic testing (real `node`/`python3`, a
capture-only fake browser binary that logs `argv` without ever invoking a
shell or interpreter on it, and direct calls into `browser-router-config`'s
Python functions/CLI). No payload used in testing ever executed — every
probe was inert data whose only purpose was to observe how it was parsed
and where it landed as an argument.

A prior review, `docs/codex-review.md`, is present in the repo and already
covers (and this review re-verifies as fixed) three earlier issues: the
missing `--` before `node -e`'s URL argument, the missing `--` before the
fallback/launch `exec` calls, and browser-order-based (rather than
longest-match) resolution of overlapping domain rules. All three are
confirmed fixed in the current code (commit `8bc4863` et al.) — see
"Verified fixed" below. This review found one new issue of the same class
that the earlier fix missed, plus several lower-severity items.

## Summary

| Severity | Finding |
| --- | --- |
| High | `browser-router-config resolve`/`add` called without `--`: a hostname starting with `-h` is parsed by Python's `argparse` as `--help`, and the router then tries to `exec` the help text as a browser binary — the link silently fails to open at all, breaking the project's own "always falls back to a real browser" guarantee |
| Low | `mktemp`-based ask-mode hand-off files are deleted and recreated by name (TOCTOU window), and the filename is visible in that process's argv while `omarchy-shell` runs |
| Low | `resolve_binary()` trusts the first whitespace-split token of `Exec=` from a `.desktop` file in the user's own `~/.local/share/applications`, with no check that it's an absolute path to a real executable |
| Informational | A few defense-in-depth / documentation notes (see below) |

## Findings

### High: Untrusted hostname reaches `browser-router-config` without a `--` separator, and a `-h...` host makes the router try to `exec` argparse's help text

Affected code: `bin/browser-router`, lines 116 and 88 (inside `ask_and_resolve`).

```bash
binary="$("$CONFIG_TOOL" resolve "$host" 2>/dev/null)"; rc=$?
...
"$CONFIG_TOOL" add "$choice" "$host" >/dev/null 2>&1
```

`$host` is attacker-controlled: it's `u.hostname` from the URL the router
was invoked with. The WHATWG URL parser Node uses (correctly, per the
existing fix) does **not** reject hostnames starting with `-`:

```
$ node -e 'console.log(new URL("https://-evil.com/").hostname)'
-evil.com
```

This is not a hypothetical: DNS itself permits a label to start with `-`
in a subdomain the zone owner controls (only registrars restrict this for
*registrable* second-level names), so an attacker who owns any domain can
freely serve real content at e.g. `https://-hello.attacker.example/` and
send that link to a victim.

`bin/browser-router` passes `$host` straight into `browser-router-config`'s
`argparse`-based CLI with no `--` end-of-options marker — the exact bug
class already fixed for the `node -e` and browser-`exec` call sites
(`docs/codex-review.md`), but missed here. `argparse` registers `-h`/`--help`
on every subcommand. Confirmed by direct testing:

```
$ ./bin/browser-router-config resolve "-x.com"      --config ...   # rc=2, stderr error (harmless: falls back to brave)
$ ./bin/browser-router-config resolve "-h.evil.com" --config ...   # rc=0, prints the FULL HELP TEXT to stdout
$ ./bin/browser-router-config resolve "-hello.com"  --config ...   # same
$ ./bin/browser-router-config resolve "-help.com"   --config ...   # same
```

Any hostname beginning with the two characters `-h` triggers this — real,
plausible names like `-home.example.com`, `-hidden.example.net`, or a
domain an attacker registers outright such as `-hello.example` all match.

The impact is worse than a simple misroute. In `bin/browser-router`:

```bash
binary="$("$CONFIG_TOOL" resolve "$host" 2>/dev/null)"; rc=$?
if (( rc == 0 )); then
  [[ -z $binary ]] && fallback "$url"
elif (( rc == 3 )); then
  ...
else
  fallback "$url"
fi

exec "$binary" -- "$url"
```

`argparse`'s help action prints to **stdout** and exits **0** (unlike its
error path, which prints to stderr and exits 2). So `rc` is 0 and `binary`
is non-empty — it's the multi-line help text — and the `[[ -z $binary ]]`
guard doesn't catch it. Execution falls through to
`exec "$binary" -- "$url"`, which tries to `exec` the literal help text as
a command name. Reproduced end-to-end with a real fake-browser harness:

```
$ browser-router 'https://-hyphen-led.test/'
bin/browser-router: line 126: /home/.../usage: browser-router-config resolve [-h] [--config CONFIG] host

positional arguments:
  host             hostname to resolve...: File name too long
```

No browser opens — not even the hardcoded `brave` fallback. This directly
breaks the invariant the project states repeatedly (README, install.sh,
and the header comment in `bin/browser-router` itself): *"Any failure
along the way... falls back to launching brave directly, so a config
mistake can never silently open a link in some other configured browser."*
Here, the failure isn't silently absorbed into that fallback — the whole
open-a-link operation dies with a shell error the user (who likely
triggered this from a GUI app, not a terminal) will never see. It's a
functional denial-of-service against opening any link to this class of
hostname, and it's directly attacker-triggerable via an ordinary link.

The same missing `--` on the `add` call (line 88, `ask_and_resolve`'s
"remember this choice" path) is lower-impact — `argparse` failing there
just means the "remember" write silently doesn't happen — but should be
fixed identically for consistency and because a future caller of that path
may not tolerate silent failure as gracefully.

#### Recommendation

Add `--` before the untrusted positional at both call sites, exactly as
already done for `node -e` and every browser `exec`:

```bash
binary="$("$CONFIG_TOOL" resolve --config-flags-if-any -- "$host" 2>/dev/null)"; rc=$?
...
"$CONFIG_TOOL" add "$choice" -- "$host" >/dev/null 2>&1
```

(`--config` is a flag with its own value and can stay before `--`; only the
bare positional needs to move after it.) Verified this fixes it:

```
$ ./bin/browser-router-config resolve --config ... -- "-h.evil.com"
brave
$ echo $?
0
```

Also worth a regression test asserting `browser-router-config resolve --
-h.example.com` (and `-x.example.com`) both print a plain browser id, not
argparse output — this is exactly the kind of thing that silently
regresses if someone "simplifies" the invocation later.

## Verified fixed (from `docs/codex-review.md`)

Re-tested against the current code; all hold:

- **`node -e` argument-injection**: `bin/browser-router` line 111-112 now
  invokes `node -e '...' -- "$url"`. Tested with a Node-flag-shaped string
  as the URL — it's now passed to the URL parser (and rejected as
  non-HTTP(S), falling back to `brave`) rather than being parsed as a Node
  CLI option.
- **Fallback/launch missing `--`**: `fallback() { exec brave -- "$@"; }`
  (line 41) and `exec "$binary" -- "$url"` (line 126) both terminate
  option parsing before the URL. Verified with a capture-only fake
  browser: a leading-dash URL is always received as a single argument
  after a literal `--`, never split or reinterpreted as a flag.
- **Longest-match domain resolution**: `resolve_explicit()`
  (`bin/browser-router-config` lines 185-211) now picks the longest
  matching domain across all browsers rather than the first hit in
  `BROWSER_IDS` order. Verified: with `chrome: [example.com]` and
  `brave: [login.example.com]`, resolving `login.example.com` now
  correctly returns `brave`, and `example.com`/`other.example.com`
  correctly return `chrome`.
- **Backslash-authority bypass** (`https://evil.example\@trusted.example/`
  reads as `evil.example` under WHATWG, not `trusted.example`): confirmed
  still correct — Node's `URL` returns `evil.example`, so no bypass into a
  differently-configured browser is possible via this vector.

## Other findings

### Low: TOCTOU window on ask-mode's hand-off temp files

Affected code: `bin/browser-router`, `ask_and_resolve()`, lines 60-79.

```bash
selection_file=$(mktemp)
done_file=$(mktemp)
rm -f "$done_file"
trap 'rm -f "$selection_file" "$done_file"' RETURN
...
deadline=$((SECONDS + ASK_TIMEOUT_SECONDS))
while [[ ! -e $done_file && $SECONDS -lt $deadline ]]; do
  sleep 0.05
done
```

`mktemp` creates `done_file` with an unpredictable name and safe (0600)
permissions, but the script immediately deletes it and then polls for up
to `ASK_TIMEOUT_SECONDS` (default 30s) for something to reappear at that
exact path. The path is embedded in the JSON payload passed as a CLI
argument to `omarchy-shell shell summon ...`, so it's visible via
`/proc/<pid>/cmdline` of that short-lived process to anything that can
read it. If something wins the race to (re)create that path — e.g. as a
symlink — before the real popup writes its answer, the `: > "$doneFile"`
truncation in `AskPopup.qml`'s `resolveRequest()`/`resolveEmptyFor()` would
follow the symlink.

In practice this is low-impact: `/proc/<pid>/cmdline` is only readable by
the same UID (or root) by default, so exploiting this requires code
already running as the same user — which already has equivalent access to
everything this could reach (the user's own config, browsers, files).
It's not a privilege boundary this bug crosses. Still, it's an
unnecessary TOCTOU pattern worth tightening as defense in depth.

#### Recommendation

Don't delete-then-wait-for-recreation. Either keep `done_file` as the
`mktemp`-created file and have the QML side truncate/overwrite it in place
(dropping the `rm -f "$done_file"` on line 62), or write the "done" signal
as a rename-into-place (`mv` a freshly created file onto the target) so an
attacker-planted symlink at the target path can't be followed by a
truncating write.

### Low: `resolve_binary()` trusts the `Exec=` line of a user-writable `.desktop` file

Affected code: `bin/browser-router-config`, `resolve_binary()` and
`APPLICATION_DIRS` (lines 63-85).

```python
APPLICATION_DIRS = [
    Path.home() / ".local/share/applications",
    Path.home() / ".nix-profile/share/applications",
    Path("/usr/share/applications"),
]
```

The first two directories are writable by the invoking user themselves.
`resolve_binary()` reads whichever `.desktop` file matches a known id
first and `exec`s the first whitespace-split token of its `Exec=` line
with no check that it's an absolute path or an existing regular file. This
is not a new privilege boundary (anything that can write to the user's own
`~/.local/share/applications` already runs as that user and could do
anything else that user can do), but it is worth documenting: it means
`browser-router` implicitly trusts the integrity of every `.desktop` file
under those paths, including ones that could be dropped by any other
locally-installed, same-user application or package. This mirrors
`omarchy-launch-browser`'s own approach (intentionally, per the code
comments), so it's consistent with the rest of the system rather than a
one-off weakness — flagging for awareness, not urgency.

### Informational / verified non-issues

- **Rich-text/HTML injection into the ask-mode popup via `root.host`**:
  `AskPopup.qml` displays `"New site: " + root.host` in a plain QtQuick
  `Text` element, which defaults to `Text.AutoText` (heuristically renders
  a limited HTML subset if the string looks like it contains tags).
  Checked whether an attacker-controlled hostname could smuggle `<...>`
  markup in: it can't — WHATWG's forbidden-host-code-point set excludes
  `<`, `>`, and other markup-relevant characters, so URL parsing fails
  before such a hostname could ever reach the popup. Also checked the
  installed Omarchy `Util.shellQuote` used to build the `resolveRequest`/
  `resolveEmptyFor` shell commands (`/usr/share/omarchy/shell/Commons/Util.qml`):
  it's a correct single-quote escape (`'` → `'\''`), and in any case the
  only values it quotes there (`browser`, `remember`) are drawn from fixed
  enums, never from `root.host` or other free-form attacker input.
- **Shell metacharacters, JS/data/file URI schemes, extremely long
  strings**: all tested directly against the real scripts via a
  capture-only fake browser. Every case arrived as a single, unmodified
  argument after a literal `--`; nothing was ever interpreted by a shell
  or executed. `javascript:`, `data:`, and `file:` schemes are rejected by
  the `protocol !== "http:" && protocol !== "https:"` check and fall back
  to `brave` (which then just handles them the same as if the user had
  typed `brave <that URI>` directly — not a new capability introduced by
  this project).
- **Domain validation (`is_valid_domain`)**: rejects everything that isn't
  a clean, LDH-style hostname label sequence — paths, `@`, whitespace,
  shell metacharacters, leading/trailing dots, and (relevant to the High
  finding above) labels starting or ending with `-` are all rejected. This
  means the High finding above can never be triggered via an *explicit
  config entry* — only via the live, unvalidated `$host` value coming
  straight from a URL at request time.
- **YAML handling**: `yaml.safe_load`/`yaml.safe_dump` throughout; no
  `yaml.load` with a non-safe loader, no way to get arbitrary Python
  object construction from a crafted `config.yaml`.
- **`install.sh`/`uninstall.sh`**: `set -euo pipefail`, all variables
  quoted, no `eval`, no interpolation of untrusted data into a command
  string. `__pycache__/` is correctly gitignored and not tracked.
  `share/applications/browser-router.desktop` uses `%u` (single URL), not
  `%U`, and desktop-file `Exec` substitution isn't shell-evaluated, so
  there's no argv-splitting surface there beyond what `bin/browser-router`
  itself already handles.
- **Equal-length domain "tie" in cross-browser overlap resolution**: not
  reachable. A tie would require two different domain strings of equal
  length both matching the same host under different browsers, but
  `validate()` already forbids the same domain string appearing under two
  browsers, and two different strings of the same length can't both be a
  suffix-or-equal match for the same host. Confirmed no such input reaches
  `resolve_explicit()`'s tie-break logic in a way that matters.

## Review notes

Dynamic testing used a capture-only fake browser (a shell script that logs
its `argv` verbatim and does nothing else) standing in for `brave`/other
browsers via `PATH`/`.desktop` overrides in an isolated `$HOME`, plus
direct Python calls into `bin/browser-router-config`'s functions. No test
input was ever passed to a real shell, interpreter, or network request;
the point of every probe was to observe argument boundaries and control
flow, not to demonstrate a working exploit chain. `install.sh`/
`uninstall.sh` were reviewed statically only (not executed), since they
mutate real XDG mime defaults on the host.
