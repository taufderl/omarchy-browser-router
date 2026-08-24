# Security review: omarchy-browser-router
Date: 2026-08-24

## Summary
This review focuses on the current state of `omarchy-browser-router` to assess robustness, security, and defense-in-depth, following previous reviews (see `docs/claude-review.md` and `docs/codex-review.md`).

## Findings

### Informational: Hardcoded browser binary paths
The `browser-router-config` script looks up browser binaries by reading `.desktop` files from standard application directories. While this is better than hardcoding binary paths, it assumes that the `Exec=` line contains a simple, direct executable path and that this executable is safe to run. This is a common pattern for desktop launchers, but it's worth noting that it trusts the desktop file content.

### Informational: Temporary files in `/tmp`
`browser-router` uses `tempfile.mktemp()` to create selection and done files for the ask-mode inter-process communication. While `tempfile.mktemp()` is deprecated due to race conditions (TOCTOU), the implementation mitigates this by using the files in a way that implies a trusted, single-user desktop environment. However, replacing this with `tempfile.mkstemp()` would be more idiomatic and robust.

### Defensive: Input Handling
The URL host extraction logic in `browser-router-config` (`extract_host`) is explicitly designed to handle a restricted subset of URLs to avoid the complexities and potential security vulnerabilities of full URL parsing. This "fail-closed" approach is a strong security practice.

## Verified protections
- `browser-router` correctly uses "--" when invoking the final browser binary, preventing arbitrary flag injection from the URL or hostname.
- `browser-router-config` uses a whitelist of browser IDs (`BROWSER_IDS`) and validates all inputs.

## Recommendations
1. **Improve temporary file handling:** Update `browser-router` to use `tempfile.mkstemp()` instead of `tempfile.mktemp()` for better safety during IPC.
2. **Review `resolve_binary`:** The trust placed in `.desktop` files `Exec=` lines is acceptable for a desktop-only tool, but consider if further validation or normalization of the `Exec` line is possible without breaking functionality.

## Review notes
The codebase shows a good understanding of the security boundaries, particularly in handling untrusted inputs (URLs) and avoiding shell injection by directly calling `execvp` and avoiding `shell=True` in `subprocess.run`.
