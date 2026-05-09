# TermAssertClient

Companion client library for child processes coordinating with a
[TermAssert](../TermAssert) harness.

## What this library does

A child process spawned under TermAssert receives the harness IPC URI
in the `TERM_ASSERT_URI` environment variable. The child can then call
`connectHarness()` and request screenshots / a clean exit / a health
check via tiny line-delimited JSON messages.

This library deliberately avoids any pty / libvterm dependency so
production app code can ship a "request screenshot under test" hook
without dragging in the full harness stack.

## Status

This library lands as part of IsoNim-TUI's **M28** milestone alongside
the main [TermAssert](../TermAssert) repo. Public, MIT-licensed.

## Commands

```sh
just build           # compile every test as a smoke check
just test            # run the integration suite (requires TermAssert sibling)
just lint            # nim check + nixfmt --check
just format          # nimpretty + nixfmt
```

## Project structure

```
src/
  term_assert_client.nim          # public top-level - one file
tests/
  test_client_smoke.nim           # smoke test (constructor + URI handling)
.github/workflows/ci.yml          # lint + test
flake.nix                         # nix devShell
Justfile                          # build/test/lint/format
term_assert_client.nimble         # single-source-of-truth version
```

## Quick example

```nim
import term_assert_client

var client = connectHarness()  # reads $TERM_ASSERT_URI by default
client.requestScreenshot("checkpoint_1")
client.requestExit(0)
quit(0)
```

## Wire protocol

```text
-> {"cmd": "screenshot", "label": "main_menu"}
<- {"ok": true}
-> {"cmd": "exit", "code": 0}
<- {"ok": true}
-> {"cmd": "ping"}
<- {"ok": true, "pong": true}
```

## Specs

The authoritative spec for this library is the **M28** entry in
`Front-Ends/IsoNim/isonim-tui.milestones.org` in the
`codetracer-specs` repo.
