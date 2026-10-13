---
name: build-test
description: Run MoveBreak's full verification (build, checks, self-test, package, sign) and report failures.
disable-model-invocation: true
---

# /build-test

1. Run `./scripts/build_app.sh`. This is the full verify: security/agent-context/architecture gates,
   compile, documentation checks, `./build/MoveBreak --self-test`, packaging, and ad-hoc signing.
2. Optionally run `./scripts/test_health.sh` (repeats the self-test; needs the existing `./build/MoveBreak`).
3. Report the output of any failing step verbatim, with the step name.

## GUI rule

The self-test is headless. Never launch or drive the app GUI (opening panels, browser automation)
unless the machine is idle or the local time is 00:00-06:00; otherwise defer GUI checks to CI.
