# Security Review: omarchy-browser-router
**Date:** 2026-08-24  
**Auditor:** Antigravity (Advanced Agentic Security Review)  
**Target:** `omarchy-browser-router`  

---

## Executive Summary

A comprehensive security audit of the `omarchy-browser-router` codebase was conducted. The package acts as a system default browser dispatcher on Omarchy/Hyprland systems, routing URLs to designated web browsers based on domain rules, prompting the user via an ask-mode Quickshell overlay dialog for newly observed domains, and managing configuration via a CLI utility.

During this security evaluation, **9 security vulnerabilities and architectural weaknesses** were identified, ranging from High to Low severity. Among these findings is a critical combination of **insecure temporary file handling (CWE-377 / CWE-59) and command/argument injection vulnerabilities (CWE-88 / CWE-78)** in the IPC bridge and browser execution logic.

### Summary of Findings

| ID | Title | Severity | CWE |
|---|---|---|---|
| **VULN-01** | Insecure Temporary File Creation & Symlink Following in Ask Mode IPC | **High** | [CWE-377](https://cwe.mitre.org/data/definitions/377.html), [CWE-59](https://cwe.mitre.org/data/definitions/59.html) |
| **VULN-02** | Unsafe `.desktop` `Exec` Parsing Leading to Arbitrary Script/Command Execution | **High** | [CWE-78](https://cwe.mitre.org/data/definitions/78.html), [CWE-88](https://cwe.mitre.org/data/definitions/88.html) |
| **VULN-03** | Command-Line Option / Argument Injection in `mv` in `AskPopup.qml` | **Medium** | [CWE-88](https://cwe.mitre.org/data/definitions/88.html) |
| **VULN-04** | Flag / Option Injection in Gecko-based Browsers (Firefox & Zen) via `--` Assumption | **Medium** | [CWE-88](https://cwe.mitre.org/data/definitions/88.html) |
| **VULN-05** | RichText / HTML Injection & UI Spoofing in Ask Popup Dialog | **Medium** | [CWE-79](https://cwe.mitre.org/data/definitions/79.html), [CWE-1021](https://cwe.mitre.org/data/definitions/1021.html) |
| **VULN-06** | Non-Atomic File Writes in `write_config` & TOCTOU Race Condition | **Medium** | [CWE-362](https://cwe.mitre.org/data/definitions/362.html), [CWE-377](https://cwe.mitre.org/data/definitions/377.html) |
| **VULN-07** | Hardcoded Fallback Browser (`brave`) Causing Complete DoS When Not Installed | **Low** | [CWE-754](https://cwe.mitre.org/data/definitions/754.html) |
| **VULN-08** | FQDN Trailing Dot Route Inconsistency / Routing Bypass | **Low** | [CWE-697](https://cwe.mitre.org/data/definitions/697.html) |
| **VULN-09** | Silent Argument Truncation on Multi-Argument Invocations | **Low** | [CWE-754](https://cwe.mitre.org/data/definitions/754.html) |

---

## Detailed Vulnerability Findings

### VULN-01: Insecure Temporary File Creation & Symlink Following in Ask Mode IPC

- **Severity:** High
- **CWE:** CWE-377 (Insecure Temporary File), CWE-59 (Improper Link Resolution Before File Access / Symlink Following)
- **Affected Files:**
  - `bin/browser-router` (Lines 82–83, 102)
  - `shell-plugin/browser-router.ask/AskPopup.qml` (Lines 62–67, 72–76)

#### Description
In `bin/browser-router`, `ask_and_resolve()` creates temporary file paths using the deprecated `tempfile.mktemp()`:
```python
selection_file = tempfile.mktemp()
done_file = tempfile.mktemp()
```
`tempfile.mktemp()` does not create the file or apply safe file permissions (`0600`). The path string (e.g. `/tmp/tmpXXXXXX`) is passed in plaintext over the shell IPC payload (`omarchy-shell summon browser-router.ask <json>`), which is visible in process tables (`ps`).

In `AskPopup.qml`, while the author added a `mv` rename mechanism for `done_file` to mitigate symlinks, `selectionFile` is written using direct shell redirection:
```javascript
function resolveRequest(browser, remember) {
  var cmd = "printf '%s\\n%s\\n' " + Util.shellQuote(browser || "") + " " + Util.shellQuote(remember || "")
    + " > " + Util.shellQuote(root.selectionFile)
    + "; " + root.touchDoneFileCmd(root.doneFile)
  Quickshell.execDetached(["bash", "-c", cmd])
}

function resolveEmptyFor(selectionFile, doneFile) {
  if (!selectionFile || !doneFile) return
  var cmd = "> " + Util.shellQuote(selectionFile) + "; " + root.touchDoneFileCmd(doneFile)
  Quickshell.execDetached(["bash", "-c", cmd])
}
```

#### Impact
1. **Arbitrary File Overwrite / Truncation**: Standard shell redirection (`>`) follows symbolic links. A local attacker or malicious process monitoring `/tmp` can create a symlink from the predicted/observed `selection_file` path to any sensitive file owned by the user (e.g., `~/.bashrc`, `~/.ssh/authorized_keys`, `~/.config/...`). When the user clicks any button in the dialog or closes it, the target file is overwritten and corrupted with user privileges.
2. **Routing / State Hijacking**: Because the file does not exist when generated, a local attacker can create `selection_file` ahead of time with attacker-chosen content, dictating the routing decision and persisting unexpected domains into `config.yaml`.

#### Remediation
- Create temporary files securely inside a dedicated per-user private directory (e.g., `$XDG_RUNTIME_DIR/browser-router/` with `0700` permissions) rather than world-writable `/tmp`.
- Use `tempfile.NamedTemporaryFile(delete=False)` or pre-create the file securely with `os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)`.
- In `AskPopup.qml`, write to a newly created temporary file and atomically rename (`mv -f "$t" "$selectionFile"`) or use direct file I/O instead of `>`.

---

### VULN-02: Unsafe `.desktop` `Exec` Parsing Leading to Arbitrary Script/Command Execution

- **Severity:** High
- **CWE:** CWE-78 (OS Command Injection), CWE-88 (Improper Neutralization of Argument Delimiters)
- **Affected Files:**
  - `bin/browser-router-config` (Lines 75–80)
  - `bin/browser-router` (Lines 138, 160)

#### Description
In `bin/browser-router-config`, `resolve_binary()` extracts the binary from a desktop entry by taking the first whitespace-separated token of the `Exec=` line:
```python
for line in path.read_text().splitlines():
    if line.startswith("Exec="):
        exec_line = line[len("Exec=") :].strip()
        if exec_line:
            return exec_line.split()[0]
```
In `bin/browser-router`, the binary is executed via:
```python
os.execvp(binary, [binary, "--", url])
```

#### Impact
1. **Script Execution via Shell Wrappers**: If a `.desktop` file uses a shell interpreter or runner (e.g., `Exec=sh -c "/path/to/custom-browser %u"` or `Exec=/bin/bash /opt/browser/launch.sh %u`), `resolve_binary` returns `"sh"` or `"/bin/bash"`.
2. When `browser-router` executes `os.execvp("sh", ["sh", "--", url])`, `sh` treats `--` as the end of options and treats `url` as a **path to a shell script to execute**.
3. If an attacker tricks a user into opening a link corresponding to a downloaded or local script file (or relative file path), `sh` executes the script under the user's shell environment.
4. Furthermore, if `Exec=` contains environment wrappers (e.g. `env FOO=bar /usr/bin/firefox`) or Flatpak wrappers (`/usr/bin/flatpak run ...`), `resolve_binary()` extracts `env` or `flatpak`, which fail to launch the browser when passed `["env", "--", url]`.

#### Remediation
- Use standard desktop entry parsing (e.g., Python's `glib` bindings or properly tokenizing and stripping field codes `%u`, `%U`, `%f`, `%F`).
- Ensure the resolved target is verified against known browser binary names or absolute binary paths rather than raw shell interpreters.

---

### VULN-03: Command-Line Option / Argument Injection in `mv` in `AskPopup.qml`

- **Severity:** Medium
- **CWE:** CWE-88 (Improper Neutralization of Argument Delimiters)
- **Affected Files:**
  - `shell-plugin/browser-router.ask/AskPopup.qml` (Lines 54–56)

#### Description
In `AskPopup.qml`, `touchDoneFileCmd` builds a shell command string to atomically move a temp file onto `doneFile`:
```javascript
function touchDoneFileCmd(doneFile) {
  return "t=$(mktemp); : > \"$t\"; mv -f \"$t\" " + Util.shellQuote(doneFile)
}
```
`Util.shellQuote` wraps the argument in single quotes, escaping internal single quotes. However, it does not prevent `mv` from interpreting arguments starting with `-` (such as `-t /target/dir`, `--target-directory=...`, or `-b`) as command-line flags.

#### Impact
If an external or local process summons `browser-router.ask` with a `doneFile` starting with a flag prefix, `mv` interprets `doneFile` as options rather than the destination target operand, causing unexpected file moves into arbitrary directories or command failures.

#### Remediation
Insert the standard `--` option terminator before positional arguments in `touchDoneFileCmd`:
```javascript
function touchDoneFileCmd(doneFile) {
  return "t=$(mktemp); : > \"$t\"; mv -f \"$t\" -- " + Util.shellQuote(doneFile)
}
```

---

### VULN-04: Flag / Option Injection in Gecko-based Browsers (Firefox & Zen) via `--` Assumption

- **Severity:** Medium
- **CWE:** CWE-88 (Improper Neutralization of Argument Delimiters)
- **Affected Files:**
  - `bin/browser-router` (Lines 45, 160)

#### Description
In `bin/browser-router`:
```python
os.execvp(binary, [binary, "--", url])
```
The codebase relies on `--` to prevent a URL starting with a hyphen (e.g., `-profile`, `-search`) from being parsed as browser flags. While Chromium-based browsers honor `--` as end-of-options, **Gecko-based browsers (Firefox and Zen Browser) do NOT treat `--` as an end-of-options delimiter**.

#### Impact
1. When Firefox or Zen is launched with `["firefox", "--", "https://example.com"]`, Firefox attempts to open `--` as a separate URL target (opening a blank/search tab for `--`), causing functional degradation.
2. Any argument or URL passed to Firefox beginning with a flag prefix (`-P <profile>`, `-private-window`, etc.) is evaluated by Firefox as an active flag rather than a positional URL.

#### Remediation
Differentiate argument construction based on browser family:
- For Chromium-based browsers: `[binary, "--", url]`
- For Firefox / Zen: `[binary, "-url", url]` or `[binary, "--new-tab", url]` to explicitly bind the input as a URL operand.

---

### VULN-05: RichText / HTML Injection & UI Spoofing in Ask Popup Dialog

- **Severity:** Medium
- **CWE:** CWE-79 (Improper Neutralization of Input During Web Page Generation), CWE-1021 (Improper Restriction of Rendered UI Layers)
- **Affected Files:**
  - `shell-plugin/browser-router.ask/AskPopup.qml` (Lines 186–193)

#### Description
In `AskPopup.qml`, the header displaying the requested domain is defined as:
```qml
Text {
  width: parent.width
  text: "New site: " + root.host
  color: root.foreground
  font.family: root.fontFamily
  font.pixelSize: Style.font.heading
  wrapMode: Text.WordWrap
}
```
In QtQuick, `Text.textFormat` defaults to `Text.AutoText`, which parses and renders HTML tags.

#### Impact
If `AskPopup` receives input containing HTML markup (via direct IPC invocation or unconstrained host strings), the popup renders HTML formatting, embedded links, or style modifiers. An attacker can craft a payload to disguise the domain being approved or spoof UI dialog contents.

#### Remediation
Explicitly set `textFormat: Text.PlainText` on all dynamic `Text` elements in `AskPopup.qml`:
```qml
Text {
  width: parent.width
  text: "New site: " + root.host
  textFormat: Text.PlainText
  ...
}
```

---

### VULN-06: Non-Atomic File Writes in `write_config` & TOCTOU Race Condition

- **Severity:** Medium
- **CWE:** CWE-362 (Race Condition), CWE-377 (Insecure Temporary File)
- **Affected Files:**
  - `bin/browser-router-config` (Lines 208–210)
  - `bin/browser-router` (Line 110)

#### Description
In `bin/browser-router-config`:
```python
def write_config(path: Path, data: dict) -> None:
    ordered = {"default": data["default"]}
    for b in BROWSER_IDS:
        ordered[b] = sorted(d.lower() for d in data.get(b, []))
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w") as f:
        yaml.safe_dump(ordered, f, default_flow_style=False, sort_keys=False)
```
Opening `path` directly with mode `"w"` truncates the file in place.

#### Impact
If two concurrent browser launches trigger ask-mode resolution or if a user runs `browser-router-config set` during an active launch, `config.yaml` can be read while partially written, causing `load_validated()` to raise `ConfigError` and triggering fail-closed fallback behavior across all subsequent routing requests.

#### Remediation
Perform atomic file replacement using a temporary file in the same directory:
```python
import tempfile

def write_config(path: Path, data: dict) -> None:
    ordered = {"default": data["default"]}
    for b in BROWSER_IDS:
        ordered[b] = sorted(d.lower() for d in data.get(b, []))
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", dir=path.parent, delete=False) as tf:
        yaml.safe_dump(ordered, tf, default_flow_style=False, sort_keys=False)
        temp_name = tf.name
    os.replace(temp_name, path)
```

---

### VULN-07: Hardcoded Fallback Browser (`brave`) Causing Complete DoS When Not Installed

- **Severity:** Low
- **CWE:** CWE-754 (Improper Check for Unusual or Exceptional Conditions)
- **Affected Files:**
  - `bin/browser-router` (Lines 35, 44–47, 127–129, 137, 142, 147, 158)
  - `bin/browser-router-config` (Line 35)

#### Description
`FALLBACK_BROWSER` is hardcoded to `"brave"`. On systems where Brave is not installed (e.g. a user only has Firefox or Chrome installed), any error condition (such as unparseable URLs, ask timeout, or config validation failures) triggers `fallback()` -> `os.execvp("brave", ...)`.

#### Impact
`os.execvp` raises an unhandled `FileNotFoundError`, abruptly crashing the router and leaving the user unable to open links.

#### Remediation
Dynamically resolve a fallback browser: check `resolve_binary()` for the configured default browser, query `xdg-mime query default`, or iterate over installed browsers in `BROWSER_IDS` before attempting `brave`.

---

### VULN-08: FQDN Trailing Dot Route Inconsistency / Routing Bypass

- **Severity:** Low
- **CWE:** CWE-697 (Incorrect Comparison)
- **Affected Files:**
  - `bin/browser-router-config` (Lines 83, 117–130)

#### Description
`_DOMAIN_RE` rejects trailing dots:
```python
_DOMAIN_RE = re.compile(r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$")
```
When an FQDN URL like `https://google.com./` is opened, `extract_host` returns `None`, bypassing the specific route for `google.com` and falling back to the default browser. Both Chromium and Firefox resolve `https://google.com./` identically to `https://google.com/`.

#### Remediation
Strip any single trailing dot from the extracted hostname prior to validation and matching:
```python
host = host.rstrip(".")
```

---

### VULN-09: Silent Argument Truncation on Multi-Argument Invocations

- **Severity:** Low
- **CWE:** CWE-754 (Improper Check for Unusual or Exceptional Conditions)
- **Affected Files:**
  - `bin/browser-router` (Lines 119, 160)

#### Description
`bin/browser-router` only reads `sys.argv[1]`:
```python
url = sys.argv[1] if len(sys.argv) > 1 else ""
```
Any additional arguments passed by callers or scripts are silently discarded.

#### Remediation
Support multi-argument forwarding if multiple URLs are provided on the command line.

---

## Conclusion & Action Plan

The security architecture of `omarchy-browser-router` demonstrates good defensive intent (fail-closed fallbacks, input validation regexes, and `--` argument boundaries). However, critical vulnerabilities exist in **temporary file handling in `/tmp` (symlink attacks)**, **unfiltered `mv` option injection**, **unsafe `.desktop` `Exec` parsing**, and **inaccurate assumption of Gecko CLI argument handling**.

Implementing the remediation patches detailed above will secure the package against local privilege abuse, symlink exploitation, and unexpected command execution.
