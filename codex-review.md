# Security review: omarchy-browser-router

Review date: 2026-08-24  
Scope: current tracked application code, installer/uninstaller, desktop entry,
and example configuration.

## Summary

The earlier URL-parser differential has been addressed correctly: the router
now obtains a normalized hostname through Node's WHATWG `URL` parser, accepts
only HTTP(S), and fails closed to Brave on parsing or configuration failures.

One medium-severity policy-bypass issue remains in the new per-browser routing
logic. Overlapping domain rules are resolved according to the hard-coded
browser order rather than by the most-specific domain. A broad rule can
therefore silently override a more-specific rule intended to isolate a site
in a different browser.

| Severity | Finding |
| --- | --- |
| Medium | Overlapping routes use browser order instead of most-specific match |

## Finding

### Medium: Overlapping routes use browser order instead of most-specific match

Affected code: `bin/browser-router-config`, `resolve()`.

`resolve()` iterates `BROWSER_IDS` first and returns the first suffix match.
It does not select the longest matching domain. The configuration validator
rejects an identical domain in two browser lists, but permits overlapping
parent and child domains in different lists.

For example, this valid configuration does not do what its specific route
suggests:

```yaml
default: brave

chrome:
  - example.com

brave:
  - login.example.com
```

Resolving `login.example.com` returns `chrome`, because `chrome` occurs before
`brave` in `BROWSER_IDS` and `example.com` is a suffix match. The explicit
`brave` rule is ignored.

This matters when browser selection is used as a trust or profile-isolation
boundary. A user may route a broad corporate domain to an authenticated
browser while trying to send a sensitive or less-trusted subdomain to an
isolated browser. Links to the child domain will instead open in the
authenticated browser. An attacker who can control content or hosting on such
a child domain can exploit that configuration mistake to reach the wrong
browser profile.

#### Reproduction

The current resolver returns `chrome` for the configuration above:

```sh
python3 -c 'import importlib.machinery; m = importlib.machinery.SourceFileLoader("brc", "bin/browser-router-config").load_module(); print(m.resolve({"default":"brave", "chrome":["example.com"], "brave":["login.example.com"]}, "login.example.com"))'
```

#### Recommendation

Resolve by longest matching suffix, independent of browser declaration/order.
For equal-length matches, reject the configuration as ambiguous (the existing
duplicate-domain check already covers exact duplicate entries). Alternatively,
reject all parent/child overlaps across browser lists during validation. Add
tests covering both a parent route and a more-specific child route assigned to
different browsers.

## Verified protections

- The previous `https://evil.example\@trusted.example/` bypass no longer
  routes according to `trusted.example`: WHATWG parsing returns
  `evil.example` as the host.
- The router rejects non-HTTP(S) schemes before route resolution.
- YAML is loaded with `yaml.safe_load`, and config validation restricts
  browser identifiers and domain-shaped entries.
- Route execution uses quoted arguments; no shell evaluation of the URL or
  resolved browser executable was identified.

## Review notes

This was a source review with focused runtime checks of the URL and routing
parsers. No high- or critical-severity issue was identified in the current
codebase.
