# Security review: omarchy-browser-router

Review date: 2026-08-24  
Scope: current tracked application code, installer/uninstaller, desktop entry,
and example configuration.

## Summary

The earlier URL-parser differential has been addressed: the router obtains a
normalized hostname through Node's WHATWG `URL` parser and accepts only
HTTP(S). However, its invocation of Node does not terminate option parsing.
Under the requested threat model, where the `url` parameter may be any string,
a value beginning with `-` is interpreted as a Node option before the URL
parser runs. Node options can execute JavaScript, making this a critical local
code-execution vulnerability.

The same missing end-of-options delimiter reaches the fallback browser. There
is also a separate policy-resolution issue: overlapping domain rules are
resolved according to the hard-coded browser order rather than by the most-
specific domain.

| Severity | Finding |
| --- | --- |
| Critical | Untrusted URL is parsed as a Node command-line option |
| Medium | Fallback browser receives an untrusted value without `--` |
| Medium | Overlapping routes use browser order instead of most-specific match |

## Finding

### Critical: Untrusted URL is parsed as a Node command-line option

Affected code: `bin/browser-router`, the `node -e` invocation.

The router invokes Node as follows:

```bash
node -e '...' "$url"
```

There is no `--` end-of-options delimiter between Node's own arguments and the
untrusted value. Node therefore processes a value beginning with `-` as one of
its CLI options instead of treating it as `process.argv[1]`. Some Node CLI
options evaluate JavaScript. If an attacker can cause `browser-router` to be
called with an arbitrary first argument, this enables code execution as the
desktop user before hostname validation or the Brave fallback occurs.

Only a benign probe was used in testing:

```sh
bin/browser-router --benign-switch
```

Node reported `bad option: --benign-switch`, confirming the value was parsed
as a Node option. It should instead have been passed to the URL parser and
rejected as a non-HTTP(S) URL.

#### Recommendation

Terminate Node option parsing:

```bash
node -e '...' -- "$url"
```

Keep the existing parse failure behavior after this change. Add a regression
test with a harmless leading-dash string and assert that Node does not emit an
option-parsing error and that the router selects the fallback.

### Medium: Fallback browser receives an untrusted value without `--`

Affected code: `bin/browser-router`, `fallback()`.

The fallback currently executes:

```bash
exec brave "$@"
```

An input beginning with `-` is consequently passed as Brave's first argument,
where it can be interpreted as a browser command-line option rather than a
URL. This is reachable after the Node parsing failure above, and remains
reachable even after that issue is fixed whenever URL parsing fails.

The same benign probe was run with a capture-only Brave substitute. The
substitute received `--benign-switch` as its only argument, confirming that no
`--` separator is supplied.

#### Recommendation

Terminate option parsing in both launch paths:

```bash
fallback() { exec brave -- "$@"; }
# ...
exec "$binary" -- "$url"
```

Confirm that every supported browser launcher accepts `--`; Chromium,
Firefox, and their usual wrappers do. If a supported wrapper cannot, reject
non-HTTP(S) inputs rather than forwarding them to the browser.

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
- Shell quoting preserves URL metacharacters as one literal argument. A
  benign string containing `$()`, `;`, and `>` was passed unchanged to a
  capture-only browser and did not create its marker file. This does not
  protect against the command-line option injection findings above.

## Review notes

This was a source review with focused runtime checks of URL handling, shell
argument passing, and routing resolution. No payload that executed code or
modified user data was used.
