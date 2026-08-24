# Security Review: omarchy-browser-router

Date: 2026-08-24

Scope:
- `bin/browser-router`
- `bin/browser-router-config`
- `install.sh`
- `uninstall.sh`
- `share/applications/browser-router.desktop`
- `shell-plugin/browser-router.ask/`

Method:
- Manual source review only. I did not use prior review documents as evidence for the findings below, and I intentionally excluded `docs/claude-review-2026-08-24.md` from review input.
- I did not run the application code. A brief `semgrep` attempt was non-essential and not used for conclusions.

## Findings

### Low: ask-mode response file is created with `tempfile.mktemp()` and later opened through shell redirection, enabling local file clobbering via symlink race

Affected code:
- `bin/browser-router:82-91`
- `shell-plugin/browser-router.ask/AskPopup.qml:62-75`

Why this matters:
- `ask_and_resolve()` creates `selection_file` and `done_file` names with `tempfile.mktemp()` but does not create the files.
- The QML side later writes the browser choice with shell redirection:
  - `printf ... > "$selectionFile"` in `resolveRequest()`
  - `> "$selectionFile"` in `resolveEmptyFor()`
- Redirection follows symlinks. If another local user can learn the temporary pathname before the QML helper writes it, they can pre-create a symlink at that path and cause the victim process to truncate or overwrite an arbitrary file writable by the victim.

Exploitability notes:
- This is a local attack, not a remote URL-handling bug.
- The practical precondition is pathname disclosure. That pathname is placed into the JSON payload passed as an argument to `omarchy-shell shell summon ...`, so on systems where other users can inspect process arguments, the race is realistic.
- Impact is integrity/availability, not straightforward code execution: the attacker can cause truncation or replacement with a very small set of possible contents (browser id plus `once`/`remember`, or empty content on cancel/timeout paths).

Why I scored this low:
- It requires a second local user or process on the same host.
- It only affects ask mode.
- The attacker does not get arbitrary file content control, only file clobbering/truncation with constrained contents.

Recommended fix:
- Replace `tempfile.mktemp()` with secure file creation (`mkstemp()` or `NamedTemporaryFile(delete=False)`), and hand the already-created pathname to the QML side.
- Keep the response file in a directory that is private to the user and not attacker-creatable by other users.
- Preserve the existing rename-based pattern for `done_file`; that part is already doing the right thing.

## Non-Findings / Rejected Issues

### `.desktop` `Exec=` trust is a documented same-user trust assumption, not a new vulnerability

Relevant code:
- `bin/browser-router-config:66-80`

The router resolves a browser executable from `.desktop` files in user-writable locations. That is a real trust assumption, but I am not counting it as a vulnerability here because any actor who can modify `~/.local/share/applications/*.desktop` already has same-user code-execution influence over the session.

### The URL-routing boundary itself is in good shape against hostile URLs

Relevant code:
- `bin/browser-router-config:90-130`
- `bin/browser-router:44-46`
- `bin/browser-router:160`

I did not find a current remote issue in the URL handling path. The implementation now does the security-important things correctly:
- accepts only a narrow, unambiguous URL subset for routing
- rejects userinfo, backslashes, percent-encoding, IPv6 literals, and non-ASCII authorities
- fails closed to a real browser on parse failure
- inserts `--` before the untrusted URL when launching a browser

### The shell-command construction in QML is quoted correctly for current inputs

Relevant code:
- `shell-plugin/browser-router.ask/AskPopup.qml:54-75`

The popup helper does invoke `bash -c`, which deserves scrutiny, but the current variable interpolation is shell-quoted and the attacker-controlled remote input (`host`) is not inserted into a shell command at all. I did not find a command-injection path here.

## Overall Posture

Current posture is reasonably strong for the main threat boundary: hostile URLs coming from external applications or websites should either route correctly or fail closed to the fallback browser. I found one low-severity local hardening issue in ask mode's temporary-file handoff, but no high-confidence remote code execution, command injection, or browser-routing bypass in the current code.
