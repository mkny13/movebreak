# Main protection verification — issue 123

The fresh live scan is **unknown, not pass**. No unsafe setting has been
confirmed, and no repository setting or workflow was changed. The build identity
cannot read classic protection. This evidence does not satisfy the remaining
protection acceptance criteria and must not be used to close them as passed.

The machine-readable [scan](scan.json) records UTC time, repository and installed
scanner SHAs, sanitized API responses, and the full `scan_project` result.
Repository source: `50779f5ee19e31b6b2c9322a2fe6f9864a678aea` (also the live
`main` SHA). Scanner: `d50fc07f59cf8db11f3ab959f1814980d8917df1`.

| Safeguard | Required | Observed classic/repository value | Effective rules |
| --- | --- | --- | --- |
| Strict required checks | `true` | Unavailable: protection HTTP 403 | None supplied |
| Required PR test check | Discovered `verify` | Required contexts unavailable: HTTP 403 | None supplied |
| Administrator enforcement | `true` | Unavailable: HTTP 403 | None supplied |
| Allow force pushes | `false` | Unavailable: HTTP 403 | None supplied |
| Allow deletions | `false` | Unavailable: HTTP 403 | None supplied |
| Squash merging | `true` | Field absent in repository response | Not established |

`GET repos/mkny13/movebreak/rules/branches/main` and `GET
repos/mkny13/movebreak/rulesets` both returned HTTP 200 with `[]`. There are no
supplying rulesets to inspect in these responses. Empty effective rules do not
establish the classic settings. Administrator enforcement applies across the
classic safeguards; historical missing labels are not independent defects.

## Verification

- `./scripts/build_app.sh`: passed, including security-surface negative fixtures,
  documentation checks, compilation, complete self-tests, packaging and signing.
  Verified on 2026-10-31 UTC with repository SHA 50779f5ee19e31b6b2c9322a2fe6f9864a678aea.
- Installed `mahler.practices_audit.scan_project` with `GH("mkny13/movebreak")`
  and the assigned worktree: executed against live GitHub APIs. `_ci(_Tree(...))`
  discovered `['verify']` from actual workflow files; no job names were injected
  into the protection scan. Assertions confirmed that HTTP 403 remains unknown.
- CI discovery separately reports `ci-tests: unknown` with `ci_uncertain=true`;
  full evidence is retained. This is not a passing CI-discovery claim.
- No behavior implementation was made, so no failing-first implementation test
  or scanner fix is claimed. App verification does not prove remote protection.

## Conductor follow-up

Post this evidence to [mahler#1487](https://github.com/mkny13/mahler/issues/1487)
and [mahler#800](https://github.com/mkny13/mahler/issues/800), linked from
[movebreak#123](https://github.com/mkny13/movebreak/issues/123). No comments were
posted by the build agent, as required by the run contract.

Use the conductor's authorized repository settings context to read classic
protection and squash-merge configuration. Preserve unrelated fields when
correcting any confirmed unsafe setting. If the settings prove safe, supply
sanitized successful responses to mahler#1487 and implement its scanner regression
in the Mahler repository. Investigate CI-discovery uncertainty there as needed.
Rerun the scanner with actual workflow discovery and record SHAs/UTC time; link
passing evidence to both Mahler issues only when a pass is actually obtained.
No owner verdict or manual UAT is required. Remaining work is automated conductor
evidence collection and, if warranted, settings correction or a scanner fix.
