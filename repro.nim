## Reprobuild project file for TermAssertClient.
##
## **Typed-Cross-Project-Deps rollout, Wave-0 leaf.** Despite the "Client"
## name and the AGENTS.md note about "requires TermAssert sibling", this repo
## is a self-contained pure-Nim leaf: the companion IPC-client library a
## child process links to coordinate with a TermAssert harness over a
## Unix-domain socket. Reading the sources confirms there is NO build-time
## sibling dependency:
##
##   * ``src/term_assert_client.nim`` imports only ``std/[json, os, posix,
##     options]`` — no ``import <sibling>`` that would need a Justfile
##     ``--path:../<sib>/src`` to resolve. The whole point of the library
##     (per its module docstring) is to "deliberately avoid any pty /
##     libvterm dependency so production app code can ship a request-
##     screenshot-under-test hook without dragging in the full harness
##     stack." So it does not consume ``nim-pty`` / ``nim-libvterm`` / the
##     ``TermAssert`` server repo at build time.
##   * ``term_assert_client.nimble`` only ``requires "nim >= 2.0.0"``.
##   * The one test (``tests/test_client_smoke.nim``) speaks the wire
##     protocol against a tiny in-process Unix-socket server it stands up
##     itself; it imports only ``std/[unittest, json, os, posix, options]``
##     + ``term_assert_client``. No sibling import there either.
##
## So the ``uses:`` block is just the toolchain floor and there is no
## ``uses: "<sibling>"`` edge.
##
## A Mode 1 / Mode 3 hybrid (per
## ``reprobuild-specs/Three-Mode-Convention-System.md``) modelled on the
## canonical ``runquota/repro.nim`` / ``nim-stackable-hooks/repro.nim`` /
## ``nim-pty/repro.nim`` recipes:
##
## * Declares the upstream tool floor via ``uses:`` so consumers that depend
##   on this repo (``uses: "term_assert_client"`` — a TUI app that wants the
##   request-screenshot hook) pick up the same toolchain the nimble file's
##   ``requires "nim >= 2.0.0"`` implies.
## * Declares ``library term_assert_client`` so consumers can express a
##   workspace dependency on this repo. The importable surface is the
##   single-file ``src/term_assert_client.nim`` umbrella; consumers
##   ``import term_assert_client``.
## * Emits, per runnable test file under ``tests/``, a BUILD edge
##   (``buildNimUnittest.build``) that compiles ``build/test-bin/<stem>``
##   and an EXECUTE edge (``edge.testBinary.run``) that runs it — the
##   two-edge test template from ``reprobuild-specs/Package-Model.md``
##   §"The test template". BUILD halves collect into ``test-builds``;
##   EXECUTE halves collect into ``test`` so ``repro build test`` /
##   ``repro test`` materialise the runnable closure.
##
## **Module search path + compile flags.** TermAssertClient ships no
## ``config.nims`` / ``nim.cfg``; its ``Justfile`` supplies
## ``--path:src --path:tests`` on every ``nim c``. Of those,
## ``--path:tests`` is redundant — the one test imports no ``tests/``-local
## helper module (only ``term_assert_client`` from ``src/``). So the BUILD
## edge passes ``paths = @["src"]``, and ``src`` is added to ``extraInputs``
## so the backend source is a declared input of the compile.
##
## Each BUILD edge reproduces the repo's DEFAULT matrix point — ``just
## test`` → ``test-orc`` → ``_matrix orc release on`` → ``nim c … --mm:orc
## -d:release --threads:on``: ``--mm:orc`` via ``mm:``, ``-d:release`` via
## ``defines:``, and ``--threads:on`` via the wrapper's default
## ``threadsOn``. The ``--threads:on`` is load-bearing here — the smoke
## test's body is guarded ``when compileOption("threads"): <real body> else:
## skip()``, and it drives the client requests from spawned
## ``Thread``s while the in-process server replies; compiling without
## ``--threads:on`` would collapse the test to a ``skip()``. The
## ``--styleCheck:usages --styleCheck:error`` from ``nim-flags`` is a style
## toggle that doesn't change the produced binary and isn't part of the
## typed ``nim c`` surface, so it's omitted — the corpus compiles + runs
## identically without it.
##
## **Per-test platform gating.** The single test, ``test_client_smoke.nim``,
## ``import``s ``std/posix`` and builds a ``Sockaddr_un`` Unix-domain server
## (``AF_UNIX`` / ``bindSocket`` / ``listen`` / ``accept``). That is a POSIX
## construct — the file does not compile on Windows (no ``Sockaddr_un`` /
## ``AF_UNIX`` in Nim's Windows ``std/posix`` surface). It carries no
## in-test ``when defined(windows): skip()`` fallback (unlike nim-pty's
## cross-platform test), so it is genuinely POSIX-only: gated
## ``when not defined(windows)`` at extraction so the edge is present on
## Linux/macOS (where it compiles + runs to exit 0) and simply absent from
## the graph on Windows. On this Linux host the edge is in the graph and is
## a real run. (The library ``src/`` itself is likewise POSIX-shaped, but
## only the test needs an extraction gate — the ``library`` declaration is
## a naming/visibility record, not a compile.)
##
## The test stands up its Unix-socket server IN-PROCESS and services the
## client requests from spawned ``Thread``s in the SAME process — it does
## NOT fork/exec a child process or allocate a pty. So there is no
## resource-contending subprocess/pty timing to serialize: no ``pool=`` /
## ``buildPool`` is needed (unlike nim-pty, whose tests fork real children
## and assert on sub-100ms read windows).
##
## **Tool provisioning.** ``defaultToolProvisioning "path"`` matches the
## canonical recipes: the nix dev shell puts ``nim`` + ``gcc`` on ``PATH``,
## so the weak-local PATH resolver is the right default. Without it
## ``repro build`` refuses to run with "typed tool provisioning is required
## for uses declarations".

import repro_project_dsl

# ``ct_test_nim_unittest`` supplies the ``buildNimUnittest.build(...)``
# typed-tool used by the test BUILD edge and the ``edge.testBinary.run(...)``
# UFCS dispatch for the EXECUTE edge. It re-exports ``repro_project_dsl`` so
# the import order is unimportant. Like the ``nim-stackable-hooks`` /
# ``nim-pty`` leaf recipes, this file does NOT import
# ``ct_test_runner_install`` (engine-coupled, reprobuild-internal): the
# execute edge routes through the engine's default direct-binary runner (run
# the binary, key on exit status), which is exactly the exit-0 verification
# this corpus needs — Nim ``unittest`` prints per-suite results and exits
# non-zero on failure.
import ct_test_nim_unittest

type
  ClientTestSpec = object
    ## One entry per runnable test file. ``source`` is the repo-relative
    ## ``.nim`` path; ``binary`` is the ``build/test-bin/<stem>`` output.
    source: string
    binary: string

# POSIX-only test corpus — ``test_client_smoke.nim`` imports ``std/posix``
# and builds a ``Sockaddr_un`` Unix-domain server, so it compiles + runs
# only off Windows. Gated ``when not defined(windows)`` at extraction below.
const posixTestSpecs: seq[ClientTestSpec] = @[
  ClientTestSpec(source: "tests/test_client_smoke.nim",
    binary: "build/test-bin/test_client_smoke"),
]

package term_assert_client:
  defaultToolProvisioning "path"

  uses:
    # Toolchain floor — the PATH-resolvable binaries the build needs.
    # ``nim`` compiles the test binary (the ``buildNimUnittest.build`` edge
    # below, matching the nimble file's ``requires "nim >= 2.0.0"``);
    # ``gcc`` is the C back-end ``nim c`` shells out to and the linker.
    # Sufficient for the path-mode resolver under ``nix develop``.
    "nim >=2.0"
    "gcc >=12"

  # Library declaration — the ``src/`` tree the tests put on ``--path`` is
  # importable when this package is consumed via
  # ``uses: "term_assert_client"``. The umbrella is the single-file
  # ``src/term_assert_client.nim``; consumers ``import term_assert_client``.
  library term_assert_client

  build:
    # Two-edge test template (Package-Model.md §"The test template"): one
    # compile BUILD edge + one EXECUTE edge per runnable test file. BUILD
    # halves collect into ``test-builds`` (compile verification); EXECUTE
    # halves collect into ``test`` so ``repro test`` / ``repro build test``
    # materialise the runnable closure (each execute edge transitively
    # depends on its build edge).
    #
    # ``paths = @["src"]`` supplies ``--path:src`` (TermAssertClient has no
    # ``config.nims``; only ``import term_assert_client`` needs it — the
    # test imports no ``tests/``-local helper). ``src`` is an ``extraInput``
    # so the backend source is a declared input of the compile. Flags
    # reproduce the repo's default matrix point (``_matrix orc release on``):
    # ``defines = @["release"]``, ``mm = "orc"``, ``threadsOn`` (default).
    var testBuildActions: seq[BuildActionDef] = @[]
    var testExecuteActions: seq[BuildActionDef] = @[]

    proc emitTestPair(source, binary: string;
                      buildActions, executeActions: var seq[BuildActionDef]) =
      var lastSlash = -1
      for i in 0 ..< binary.len:
        if binary[i] == '/' or binary[i] == '\\':
          lastSlash = i
      let stem =
        if lastSlash >= 0: binary[lastSlash + 1 .. ^1]
        else: binary
      let edge = buildNimUnittest.build(
        source = source,
        binary = binary,
        defines = @["release"],
        paths = @["src"],
        mm = "orc",
        extraInputs = @["src"],
        actionId = "term_assert_client.test_build." & stem)
      buildActions.add(edge.action)
      # ``registerImplicitName = false`` because the BUILD edge already owns
      # the binary basename as the implicit target name; the explicit
      # ``actionId`` is the execute edge's selector (two-edge shape).
      let executeEdge = edge.testBinary.run(
        actionId = "term_assert_client.test_execute." & stem,
        registerImplicitName = false)
      executeActions.add(executeEdge)

    # POSIX-only tests — the smoke test's Unix-domain-socket server compiles
    # + runs only off Windows; gated at extraction so it never enters the
    # graph on Windows.
    when not defined(windows):
      for spec in posixTestSpecs:
        emitTestPair(spec.source, spec.binary,
          testBuildActions, testExecuteActions)

    discard collect("test", testExecuteActions)
    discard collect("test-builds", testBuildActions)
