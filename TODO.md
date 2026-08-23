# TODO

## Drop the Node dependency for URL parsing

`bin/browser-router` requires `node` for hostname extraction, while
`bin/browser-router-config` is Python. Two runtimes for one small tool is a
real inconsistency, not just a style nitpick -- but it isn't arbitrary
either: it's there because the two jobs have different correctness
requirements.

**Why not just use Python:** verified directly against the exact attack URL
from `codex-review.md` (`https://evil.example\@trusted.example/login`).
Python's `urllib.parse` (`urlsplit`/`urlparse`) and GLib's `GUri` both
return `trusted.example` -- the same wrong answer the original vulnerable
bash parser gave, not `evil.example` like real Chromium. Neither implements
the WHATWG URL Standard's backslash-as-authority-terminator rule; both are
RFC-3986-based. Node's `URL` is WHATWG-correct by design, which is the
actual reason it's used here, not convenience.

**The real fix, and why it's not done:** `extra/ada` is an official Arch
package (not AUR) -- a WHATWG-compliant URL parser, and in fact the same
parsing engine Node.js itself now uses internally for its own `URL` class.
~1.1 MiB vs Node's ~61 MiB, and Node isn't part of Omarchy's default install
(`omarchy-base.packages`/`omarchy-other.packages` don't include it) -- so on
a non-dev-heavy Omarchy system, `browser-router` currently pulls in a real,
non-trivial, non-default runtime just to parse one URL string per link
click.

`ada` only ships as a C library though (`libada.so` + `ada_c.h`, confirmed
via `pacman -Ql ada` -- no CLI binary anywhere in the package). Using it
means writing a small C wrapper (parse `argv[1]`, print the hostname or
exit nonzero on failure/non-http(s) -- same contract the current `node -e`
block has) and shipping it: either a prebuilt binary (per-arch build,
provenance/trust questions, compiled artifacts in a shell-script project) or
building it in `install.sh` (needs `gcc`/build tools present on the
target, another install-time failure mode).

**Decision: not doing this for now.** Explicitly don't want to ship a
compiled C binary alongside a project that's otherwise plain scripts --
that's a real cost (build/trust/portability), not just extra code. Revisit
if:
- a maintained, packaged (non-AUR) way to call `ada` without owning a C
  build shows up (a CLI wrapper someone else maintains, a Rust/Go binding
  with a prebuilt static binary already packaged for Arch, etc.), or
- Node's footprint becomes an actual reported problem for someone running
  this without existing dev tooling, rather than a theoretical one.

## Consider dropping Node for config/YAML too? No.

Not actually a TODO -- noting the boundary so it isn't re-litigated.
`browser-router-config` (Python + PyYAML) has no WHATWG-style correctness
requirement; YAML parsing is YAML parsing, PyYAML is a standard, always-
present Arch package (`python-yaml`), and there's no equivalent "the stdlib
version silently disagrees with the real implementation" trap the way there
is for URLs. The Node/Python split is: Node for the one job that needs
spec-exact browser-matching behavior, Python for everything else. That's
correct as-is.
