# Issue 123: main protection check (read 2026-10-31T15:59Z)

Repository SHA (main): 50779f5ee19e31b6b2c9322a2fe6f9864a678aea. Identity: Mahler build token (GitHub App installation).

| Safeguard | Source | Value | Class |
|---|---|---|---|
| Rulesets / effective rules | GET rulesets, rules/branches/main | [] / [] | none apply |
| Branch protected | GET branches/main | protected=true | safe |
| Required check | GET branches/main .protection | checks=[verify], matches job `verify` in .github/workflows/build.yml | safe |
| Admin enforcement | GET branches/main .protection.enforcement_level | non_admins (so enforce_admins=false) | **UNSAFE** (real gap) |
| strict, allow_force_pushes, allow_deletions | GET branches/main/protection, GraphQL | HTTP 403 | unavailable (not inferred) |

Because enforcement_level is non_admins, admins can bypass the required check and every other classic safeguard.
No ruleset supplies a replacement.

## Required correction (needs repo-admin credential; this run has none)
Settings > Branches > main: enable "Do not allow bypassing the above settings" (enforce_admins=true) and
"Require branches to be up to date" (strict=true); keep check `verify`; force pushes and deletions off;
squash merging on. Then re-run the Mahler branch-protection scan and link the pass to mahler#1487 and mahler#800.

No scanner patch is warranted: the scanner correctly refuses to pass this state. No scan pass was obtained; none is claimed.
