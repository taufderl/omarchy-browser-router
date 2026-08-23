# Security review: omarchy-browser-router

Review date: 2026-08-23  
Scope: the tracked shell scripts, desktop entry, and example configuration.

## Summary

One high-severity URL parsing vulnerability was identified. The router uses
ad-hoc string operations to determine the host, while Chrome and Brave parse
URLs using the WHATWG URL parser. An attacker can exploit a difference in how
backslashes are handled to cause an untrusted HTTPS site to open in Chrome.

| Severity | Finding |
| --- | --- |
| High | Backslash URL parsing differential bypasses trusted-domain routing |

## Findings

### High: Backslash URL parsing differential bypasses trusted-domain routing

Affected code: `bin/browser-router`, host extraction and trusted-domain match.

The router derives a host by removing text around `://`, `/`, `?`, `#`, `@`,
and `:`. It does not recognize a backslash (`\\`) as a URL path separator.
For special schemes such as HTTPS, Chromium's WHATWG URL parser does recognize
a backslash as a path separator.

Consequently, given this trusted-domain entry:

```text
trusted.example
```

an attacker can supply the following link:

```text
https://evil.example\@trusted.example/login
```

The router extracts `trusted.example`, considers it trusted, and invokes
Chrome. Chromium parses the URL with hostname `evil.example` (the backslash
ends the authority); it therefore navigates Chrome to the attacker's site.

This defeats the primary security property documented by the project: keeping
unknown links out of the Chrome profile. A malicious link delivered through an
application that uses the XDG browser handler can thus be used for phishing or
for attacks that target the Chrome profile rather than the isolated Brave
profile.

Proof of the parser mismatch:

```sh
# Current router logic returns: trusted.example
# WHATWG/Chromium-compatible parsing returns: evil.example
node -e 'console.log(new URL(process.argv[1]).hostname)' \
  'https://evil.example\@trusted.example/login'
```

#### Recommendation

Do not parse URLs with shell parameter expansion. Either use a standards-
compliant URL parser and route according to its hostname, or apply a strict
allow-list grammar before extracting a host. The latter should, at minimum:

1. Accept only `http://` and `https://` URLs.
2. Reject any authority containing backslashes, control characters, or
   malformed percent-encoding.
3. Parse userinfo, ports, IPv6 literals, IDNs, and trailing dots according to
   the same URL standard as the target browsers.
4. Fail closed (Brave) for every parse error or unsupported URL form.

A robust implementation should avoid reproducing URL grammar in Bash. For
example, a small helper using a standards-compliant URL library can emit a
normalized hostname for the shell script to compare. Add regression tests for
the proof-of-concept URL above and other parser edge cases.

## Notes

- Trusted-list matching itself correctly uses an exact-or-proper-subdomain
  comparison; `eviltrusted.example` does not match `trusted.example`.
- The installer creates the configuration and installed executable with
  conventional user-only ownership assumptions. No separate privilege-
  escalation issue was identified in the reviewed scripts.
- This was a source review; browser behavior was cross-checked with Node's
  WHATWG `URL` implementation, which follows Chromium's special-scheme
  backslash behavior.
