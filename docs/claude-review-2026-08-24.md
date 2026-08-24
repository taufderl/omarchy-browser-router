# Security review: omarchy-browser-router

Review date: 2026-08-24
Commit reviewed: `27c969b` (clean working tree)
Scope: all tracked code — `bin/browser-router`, `bin/browser-router-config`,
`install.sh`, `uninstall.sh`, `share/applications/browser-router.desktop`,
`config/config.yaml.example`, and the Quickshell ask-mode plugin
(`shell-plugin/browser-router.ask/`).
Method: full source review of the **current Python implementation**, plus
targeted dynamic checks of `extract_host()` against known URL-parser bypass
classes. No destructive payloads were run; probes were inert data used only to
observe parsing and control flow.

> **Note on the two existing reviews in this directory.** `docs/codex-review.md`
> and `docs/claude-review.md` were written against the **older Node/bash
> implementation**. Since then the tool was rewritten in Python
> (`bin/browser-router` now *imports* `bin/browser-router-config` as a module
> and calls its functions directly, rather than shelling out to a CLI). As a
> result, every "missing `--` end-of-options separator" finding in those
> reviews — the Node `-e` argument injection, the fallback/launch `exec`, and
> the `browser-router-config resolve`/`add` argv boundary — **no longer exists
> as an attack surface**: there is no argv boundary between the router and its
> config logic anymore, and the one remaining `exec` (of a real browser) always
> uses `--`. See [Verified protections](#verified-protections). Those reviews
> should be treated as historical.

## Summary

The current code is well-defended on its primary attack surface (untrusted URLs
arriving from the desktop as the registered default browser). Hostname
extraction is deliberately restricted to a WHATWG-safe subset and fails closed;
there is no shell involved in any subprocess call; the final browser `exec`
terminates option parsing with `--`; and YAML is parsed safely.

The findings below are secondary. The most significant is an insecure
temp-file hand-off pattern in ask mode that is exploitable across users on a
shared/multi-user host; the rest are same-user trust and robustness issues.

| # | Severity | Finding |
| --- | --- | --- |
| M1 | Medium (Low on single-user desktop) | Ask-mode hand-off uses `tempfile.mktemp()`; the `selectionFile` write follows symlinks and the path leaks via process argv |
| L1 | Low | `resolve_binary()` executes the first token of a user-writable `.desktop` `Exec=` line without validation |
| L2 | Low | `ASK_TIMEOUT_SECONDS` is parsed with `float()` at import time; a bad value crashes the router before any fallback runs |
| L3 | Low / Informational | Hard-coded `brave` fallback: if brave is absent, `os.execvp` raises and no browser opens, breaking the stated "always falls back" guarantee |

## Threat model

`browser-router` is registered as the system default web browser
(`x-scheme-handler/https`, `text/html`, etc.). Its argument is therefore fully
attacker-controlled: any web page, chat message, email, or other application
can hand it an arbitrary string as `%u`. The primary security goal is that a
crafted URL can neither (a) execute code / inject options into a launched
process, nor (b) be routed to a different (more-trusted) browser profile than
its true hostname warrants. A secondary goal, stated repeatedly in the project's
own docs, is that *any* failure falls back to launching a real browser rather
than silently dropping the link.

The config file, `.desktop` files under `$HOME`, and environment variables are
same-user inputs — not a privilege boundary on a single-user desktop, but worth
tracking on shared hosts.

## Findings

### M1 — Medium: Insecure temp-file hand-off in ask mode (`tempfile.mktemp()`, symlink-followed write, argv path leak)

**Affected code:** `bin/browser-router` `ask_and_resolve()`, lines 82–115;
`shell-plugin/browser-router.ask/AskPopup.qml` `resolveRequest()` /
`resolveEmptyFor()`, lines 62–76.

Ask mode passes an answer back from the Quickshell popup to the polling Python
process through two files:

```python
selection_file = tempfile.mktemp()   # bin/browser-router:82
done_file = tempfile.mktemp()        # bin/browser-router:83
```

Three properties combine into a real weakness:

1. **`tempfile.mktemp()` is insecure by design.** It only *returns a name* (in
   `/tmp`, confirmed) without creating the file, and its use is explicitly
   discouraged in the Python docs precisely because of symlink/TOCTOU races.
   Neither file exists at the moment the popup is summoned.

2. **The paths leak through process argv.** Both names are embedded in the JSON
   payload passed to `omarchy-shell shell summon browser-router.ask <payload>`
   (line 91). On a default Linux system (`/proc` `hidepid=0`), *any* local user
   can read `/proc/<pid>/cmdline` of that process and learn both paths while the
   popup is open (up to `ASK_TIMEOUT_SECONDS`, default 30s).

3. **The `selectionFile` write follows symlinks.** The QML side is careful with
   `doneFile` — `touchDoneFileCmd()` (line 54) creates a fresh file and `mv`s it
   into place, which is `rename(2)` and does *not* dereference a symlink at the
   destination (the code comment on lines 46–53 explains exactly this). But the
   companion `selectionFile` write does **not** get the same treatment:

   ```qml
   // resolveRequest():
   "printf ... > " + Util.shellQuote(root.selectionFile) + "; " + ...
   // resolveEmptyFor():
   "> " + Util.shellQuote(selectionFile) + "; " + ...
   ```

   A bare `>` redirection **follows a symlink** at the target path and truncates
   whatever it points at. Python then also reads it back with
   `Path(selection_file).read_text()` (line 102), which likewise follows a
   symlink.

Putting these together: on a multi-user host, an attacker on the same machine
can read the `selectionFile` path from argv, plant a symlink there (the path is
in world-writable `/tmp` and does not yet exist), and cause the victim's shell
process to **truncate/create an arbitrary victim-writable file** (following the
symlink) when the popup resolves. The written content is fixed (`<browser
id>\n<remember|once>\n`), so this is a file-integrity / denial-of-service
primitive against victim-owned files (e.g. clobbering a dotfile), not arbitrary
content injection. The same race also lets a would-be attacker feed a chosen
`selectionFile`/`doneFile` back to `ask_and_resolve()`, which can silently
`set_domain()` + `write_config()` a route (line 108–110) — i.e. tamper with
routing — though this is harder because it requires also satisfying the
`doneFile` handshake.

On a single-user desktop (the typical Omarchy deployment) there is no crossing
of a trust boundary and the practical severity is Low. On any shared host it is
a genuine cross-user issue, hence Medium. The notable point regardless of host
is the **asymmetry**: `doneFile` was deliberately hardened against exactly this
symlink vector while `selectionFile` was left with a plain truncating write.

#### Recommendation

Create a private per-request directory instead of loose `mktemp` names, and put
both files inside it:

```python
import tempfile
req_dir = tempfile.mkdtemp(prefix="browser-router-ask-")  # mode 0700, owned by us
selection_file = os.path.join(req_dir, "selection")
done_file = os.path.join(req_dir, "done")
...
finally:
    shutil.rmtree(req_dir, ignore_errors=True)
```

A `0700` directory means no other user can plant a symlink inside it, which
closes the vector even though the directory name still appears in argv.
Additionally, make the `selectionFile` write in `AskPopup.qml` use the same
`mv`-into-place pattern already used for `doneFile`, so neither write ever
follows a symlink. Consider `os.open(..., O_NOFOLLOW)` for the Python-side read
as defense in depth.

### L1 — Low: `resolve_binary()` runs the first token of a user-writable `.desktop` `Exec=` line unchecked

**Affected code:** `bin/browser-router-config` `resolve_binary()` and
`APPLICATION_DIRS`, lines 59–80; consumed by `os.execvp(binary, ...)` in
`bin/browser-router` (lines 138, 160).

```python
APPLICATION_DIRS = [
    Path.home() / ".local/share/applications",   # user-writable
    Path.home() / ".nix-profile/share/applications",
    Path("/usr/share/applications"),
]
```

`resolve_binary()` reads the first matching `.desktop` file, takes the first
whitespace-split token of its `Exec=` line, and returns it to be `os.execvp`'d.
There is no check that the token is an absolute path or an existing executable —
and because `execvp` does a `PATH` search for a non-absolute name, a crafted
`Exec=` line can point the router at an arbitrary program on `PATH`.

This is a **same-user** issue: anything that can write to
`~/.local/share/applications` already runs as the user and can do whatever the
user can. It also mirrors, intentionally, how `omarchy-launch-browser` resolves
browsers, so it is consistent with the surrounding system rather than a one-off.
Flagged for awareness and as defense-in-depth, not as an urgent break.

#### Recommendation

After extracting the `Exec=` token, resolve it with `shutil.which()` and/or
require an absolute path to an existing regular executable file before returning
it. This bounds the blast radius of a malformed or malicious `.desktop` entry
and makes routing fail closed (to the `brave` fallback) rather than launching
something unexpected.

### L2 — Low: `ASK_TIMEOUT_SECONDS` parsed with `float()` at import time crashes the router

**Affected code:** `bin/browser-router`, line 36.

```python
ASK_TIMEOUT_SECONDS = float(os.environ.get("ASK_TIMEOUT_SECONDS", 30))
```

This runs at module load, before `main()`'s `try/except` fallbacks. If the
environment variable is set to a non-numeric value, `float()` raises
`ValueError` and the process aborts **before any URL is handled and before any
fallback can run** — directly contradicting the project's stated invariant that
every failure path still opens a browser. A negative or absurdly large value is
also accepted silently and becomes the poll deadline.

This is not attacker-controlled in the normal desktop flow (the user sets their
own environment), so severity is Low; the concern is robustness of the
fail-closed guarantee.

#### Recommendation

Parse defensively and clamp:

```python
try:
    ASK_TIMEOUT_SECONDS = max(1.0, float(os.environ.get("ASK_TIMEOUT_SECONDS", 30)))
except (TypeError, ValueError):
    ASK_TIMEOUT_SECONDS = 30.0
```

### L3 — Low / Informational: hard-coded `brave` fallback can itself fail to launch

**Affected code:** `bin/browser-router` `fallback()`, lines 44–46 (`FALLBACK_BROWSER = "brave"`).

Every failure path ultimately calls `fallback()`, which `os.execvp("brave", ...)`.
If brave is not installed, `execvp` raises `FileNotFoundError`, which is
uncaught on most fallback paths (e.g. lines 128, 137, 142, 147, 158) — so the
link fails to open at all. The docs promise the opposite ("always falls back to
launching a real browser"). This is a resilience gap rather than an attacker
capability.

#### Recommendation

As a last resort in `fallback()`, catch the `execvp` failure and try the set of
installed browsers (`resolve_binary()` over `BROWSER_IDS`) before giving up, or
at minimum emit a diagnostic so the failure is not completely silent.

## Verified protections

These were reviewed (and, where noted, tested) and are sound in the current
code:

- **URL/hostname handling fails closed to a WHATWG-safe subset.**
  `extract_host()` (`bin/browser-router-config:93`) rejects userinfo (`@`),
  backslashes, percent-encoding, IPv6 literals (`[`/`]`), non-ASCII, and any
  non-HTTP(S) scheme, then requires a strict LDH domain. Confirmed by direct
  testing: `https://evil.example\@trusted.example/`, `https://-hello.example.com/`,
  `https://user@trusted.example/`, `javascript:...`, `https://%65xample.com/`,
  `https://[::1]/`, and `https://a.com../` all return `None` (→ fallback), while
  legitimate URLs return the expected lowercased host. The leading-dash-host
  problem that broke the old bash version is doubly resolved here: `is_valid_domain`
  rejects it *and* there is no argv boundary to inject into.
- **No shell is ever invoked with untrusted data.** All subprocess calls
  (`shell_call()`, `os.execvp`) use argv lists, never a shell string. The
  `omarchy-shell ... summon` payload is a single JSON argv element. The QML
  side builds bash commands but only interpolates values via `Util.shellQuote`,
  and the only free-form value there (`root.host`) is *not* used in any command.
- **Final browser launch terminates option parsing.** `os.execvp(binary,
  [binary, "--", url])` (line 160) and `fallback()` (`[FALLBACK_BROWSER, "--"]
  + [url]`, line 45) both place `--` before the URL, preventing a leading-dash
  URL from being read as a browser flag. `-h`/`--help` is intercepted before
  any URL handling (lines 121–123).
- **Routing precedence is longest-match, not declaration order.**
  `resolve_explicit()` (line 213) selects the most specific (longest) matching
  domain across all browsers, so a specific child route is not silently
  overridden by a broad parent route in an earlier browser list — the trust /
  profile-isolation concern from the historical review is addressed.
- **Popup cannot be used for markup injection.** `AskPopup.qml` renders
  `"New site: " + root.host` in an auto-text `Text` element, but `root.host` is
  constrained to LDH characters by `extract_host`/`is_valid_domain`, so no
  `<...>` markup can reach it.
- **YAML is parsed and written safely.** `yaml.safe_load` / `yaml.safe_dump`
  throughout (`load_raw`, `write_config`); no unsafe loader, and `validate()`
  restricts keys to known browser ids + `default` and enforces domain syntax.
- **Installer/uninstaller hygiene.** `install.sh`/`uninstall.sh` use
  `set -euo pipefail`, quote variables, use no `eval`, and interpolate no
  untrusted data into command strings. The `omarchy-menu.jsonc` edit writes a
  fixed entry and touches only its own dotted key. The desktop entry uses `%u`
  (single URL), and `.desktop` `Exec=` substitution is not shell-evaluated.

## Shell injection: dedicated analysis and conclusion

Because command injection is the highest-consequence risk for a tool that
receives attacker-controlled URLs, it was analyzed exhaustively. Every location
that could invoke a shell was enumerated:

- **All Python subprocess calls use argv lists — no shell.** `shell_call()`
  wraps `subprocess.run(["omarchy-shell", *args], ...)` (no `shell=True`), and
  browser launches use `os.execvp(binary, [binary, "--", url])`. There is no
  `os.system`, `os.popen`, `subprocess.Popen(..., shell=True)`, or backtick
  anywhere in `bin/`.
- **`bin/browser-router-config` spawns no processes at all.**
- **`install.sh` / `uninstall.sh` contain no `eval`;** every `$(...)` runs a
  fixed command and every variable expansion is quoted.
- **The only actual shell interpreter in the entire repo is the two
  `Quickshell.execDetached(["bash", "-c", cmd])` calls in `AskPopup.qml`
  (lines 66 and 75).**

Tracing the data that flows into those two `cmd` strings, every interpolated
value is one of exactly three kinds, and **none is attacker-controlled
free-form text**:

| Value | Source | Attacker-controlled? |
| --- | --- | --- |
| `browser` | `payload.browsers[].id`, a member of the fixed `BROWSER_IDS` constant | No (fixed enum) |
| `remember` | `"once"` / `"remember"`, set in QML | No (fixed enum) |
| `selectionFile` / `doneFile` | `tempfile.mktemp()` output — `/tmp/tmpXXXXXXXX`, characters `[a-z0-9_]` only | No (locally generated) |

All three are additionally wrapped in `Util.shellQuote`. Critically, the **one
genuinely attacker-controlled value — the URL host — never reaches a shell**:
`root.host` is used at exactly one place in the QML (line 188, a `Text` label),
never in either `cmd`. On the Python side the host only ever becomes a single
argv element to `omarchy-shell` and a JSON payload field, and `extract_host()`
has already restricted it to LDH characters `[a-z0-9.-]` before it exists at
all.

**Conclusion: no shell injection is reachable from attacker-controlled input in
the code under review.** This holds with two honestly-scoped caveats about
external components not contained in this repository:

1. **`Util.shellQuote` is external Omarchy code**
   (`/usr/share/omarchy/shell/Commons/Util.qml`) and was not present on the
   review host, so its escaping could not be re-verified here. This matters only
   as defense-in-depth, since the values it quotes are all fixed enums or
   locally-generated temp paths — a bug in `shellQuote` would still give an
   attacker no foothold via this code.
2. **`omarchy-shell` is an external binary** that receives the JSON payload
   (which contains the attacker-controlled host) as an argv element. What it
   does with that internally is outside this repo's scope. Within the QML under
   review, the host reaches only a `Text` element, which is safe.

Note that the M1 finding is a file-handling (symlink/TOCTOU) weakness, **not**
shell injection — the `>` redirection there follows a symlink but does not
allow command execution.

## Prioritized remediation

1. **M1** — Replace `tempfile.mktemp()` with a `0700` `mkdtemp()` directory and
   make the QML `selectionFile` write use the `mv`-into-place pattern. Small,
   self-contained change that closes the only cross-user issue.
2. **L2 / L3** — Harden the two fail-closed invariants (`ASK_TIMEOUT_SECONDS`
   parsing; brave-missing fallback) so the "always opens a browser" promise
   actually holds.
3. **L1** — Validate the `Exec=` token (`shutil.which` / absolute-path check)
   as defense in depth.
4. Add regression tests for the verified protections most likely to silently
   regress: the `extract_host` bypass corpus above, and `--`-terminated exec of
   a leading-dash URL.

## Review notes

This was a source review of the current Python implementation with focused
dynamic checks of `extract_host()`. `install.sh`/`uninstall.sh` were reviewed
statically only, since running them mutates real XDG mime defaults on the host.
No exploit was executed; probes were inert observations of parsing and control
flow.
