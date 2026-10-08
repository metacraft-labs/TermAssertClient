## test_client_smoke - smoke test for the TermAssertClient library.
##
## Spins up an independent native IPC peer in a separate process, exposes its
## path via $TERM_ASSERT_URI, then exercises connectHarness / ping /
## requestScreenshot / requestExit and verifies the wire protocol.
##
## The responder deliberately stubs TermAssert to provide an independent wire
## oracle without a circular dependency. Socket operations, process isolation,
## JSON parsing and the production client are real integration boundaries.

import std/[unittest, json, os]
import term_assert_client

when defined(windows):
  import std/[osproc, streams, monotimes, times, winlean, widestrs]
  {.compile: "windows_ipc_deadline.c".}
  proc startOperationDeadline(): pointer {.importc: "tac_start_operation_deadline".}
  proc finishOperationDeadline(p: pointer): cint {.importc: "tac_finish_operation_deadline".}
  proc startFixtureDeadline(): Handle {.importc: "tac_start_fixture_deadline".}
  proc finishFixtureDeadline(timer: Handle): cint {.importc: "tac_finish_fixture_deadline".}
  proc connectNamedPipe(handle: Handle; overlapped: pointer): WINBOOL {.
    stdcall, dynlib: "kernel32", importc: "ConnectNamedPipe".}
  proc waitNamedPipe(path: WideCString; timeout: DWORD): WINBOOL {.
    stdcall, dynlib: "kernel32", importc: "WaitNamedPipeW".}

  template boundedOperation(body: untyped) =
    block:
      let deadline = startOperationDeadline()
      doAssert deadline != nil, "cannot create five-second operation deadline"
      try:
        body
      finally:
        doAssert finishOperationDeadline(deadline) == 0,
          "named-pipe operation timeout or deadline lifecycle failure"

  proc betweenCallsTimeout(path: WideCString): cint {.importc: "tac_between_calls_timeout".}

  proc serveWindowsProtocol(path: string; stall: bool = false) =
    let deadline = startFixtureDeadline()
    doAssert deadline != Handle(0), "cannot create ten-second fixture deadline"
    defer: doAssert finishFixtureDeadline(deadline) == 0
    let widePath = newWideCString(path)
    let pipe = createNamedPipe(widePath, PIPE_ACCESS_DUPLEX, 0, 1, 4096, 4096, 5000, nil)
    doAssert pipe != INVALID_HANDLE_VALUE
    defer: discard closeHandle(pipe)
    let connected = connectNamedPipe(pipe, nil)
    doAssert connected != 0 or int(osLastError()) == 535 # ERROR_PIPE_CONNECTED
    for expected in [%*{"cmd": "ping"},
                     %*{"cmd": "screenshot", "label": "first"},
                     %*{"cmd": "exit", "code": 0}]:
      var line = ""
      while true:
        var ch: char
        var count: int32
        doAssert readFile(pipe, addr ch, 1, addr count, nil) != 0
        doAssert count == 1
        if ch == '\n': break
        doAssert line.len < 65536
        line.add ch
      let parsed = parseJson(line)
      doAssert parsed.kind == JObject
      doAssert parsed.hasKey("cmd")
      doAssert parsed == expected
      if stall: winlean.sleep(10000) # Real stalled peer; fixture timer still owns 10s bound.
      var response = %*{"ok": true}
      if expected["cmd"].getStr == "ping": response["pong"] = %true
      let bytes = $response & "\n"
      var offset = 0
      while offset < bytes.len:
        var count: int32
        doAssert writeFile(pipe, unsafeAddr bytes[offset], int32(bytes.len - offset),
                           addr count, nil) != 0
        doAssert count > 0
        offset += int(count)

  if paramCount() in [2, 3] and paramStr(1) == "--tac-pipe-server":
    try:
      serveWindowsProtocol(paramStr(2), paramCount() == 3 and paramStr(3) == "stall")
      quit(0)
    except Exception:
      quit(1)

  suite "TermAssertClient smoke":
    test "connect + ping + screenshot + exit":
      let path = "\\\\.\\pipe\\TermAssert-test-" & $getCurrentProcessId()
      let hadUri = existsEnv("TERM_ASSERT_URI")
      let originalUri = getEnv("TERM_ASSERT_URI")
      defer:
        if hadUri: putEnv("TERM_ASSERT_URI", originalUri)
        else: delEnv("TERM_ASSERT_URI")
      putEnv("TERM_ASSERT_URI", path)
      let started = getMonoTime()
      let child = startProcess(getAppFilename(), args = @["--tac-pipe-server", path],
                               options = {})
      var terminal = false
      defer:
        if not terminal:
          if peekExitCode(child) < 0: terminate(child)
          let code = waitForExit(child, 5000)
          doAssert code >= 0, "owned fixture did not terminate"
        close(child)
      let widePath = newWideCString(path)
      while waitNamedPipe(widePath, 10) == 0:
        doAssert peekExitCode(child) < 0, "fixture failed before pipe readiness"
        doAssert (getMonoTime() - started).inMilliseconds < 5000,
          "fixture pipe readiness timeout"
        os.sleep(10)
      var client = connectHarness()
      defer: client.close()
      boundedOperation:
        check client.ping()
      boundedOperation:
        client.requestScreenshot("first")
      boundedOperation:
        client.requestExit(0)
      check client.isConnected
      let remaining = max(1, 10000 - int((getMonoTime() - started).inMilliseconds))
      let code = waitForExit(child, remaining)
      terminal = code >= 0
      check terminal
      check code == 0
    test "missing named pipe refuses connection":
      let path = "\\\\.\\pipe\\TermAssert-missing-" & $getCurrentProcessId()
      expect TuiTestClientError:
        var client = connectHarness(path)
        client.close()

    test "deadline cancels read started after its first cancellation":
      let path = "\\\\.\\pipe\\TermAssert-gap-" & $getCurrentProcessId()
      let started = getMonoTime()
      let child = startProcess(getAppFilename(),
        args = @["--tac-pipe-server", path, "stall"], options = {})
      defer:
        try:
          if peekExitCode(child) < 0: terminate(child)
          doAssert waitForExit(child, 5000) >= 0, "owned stalled peer did not terminate"
        finally:
          close(child)
      let widePath = newWideCString(path)
      while waitNamedPipe(widePath, 10) == 0:
        doAssert peekExitCode(child) < 0
        doAssert (getMonoTime() - started).inMilliseconds < 5000
        os.sleep(10)
      check betweenCallsTimeout(widePath) == 0

    test "fixture deadline fails a real unconnected child":
      let path = "\\\\.\\pipe\\TermAssert-unconnected-" & $getCurrentProcessId()
      let child = startProcess(getAppFilename(), args = @["--tac-pipe-server", path],
                               options = {})
      var terminal = false
      defer:
        try:
          if not terminal:
            if peekExitCode(child) < 0: terminate(child)
            doAssert waitForExit(child, 5000) >= 0
        finally:
          close(child)
      let code = waitForExit(child, 11000)
      terminal = code >= 0
      check terminal
      check code == 125 # Timeout is expected failure, never protocol success.

else:
  import std/posix

  proc allocPath(): string =
    var dir = getEnv("TMPDIR")
    if dir.len == 0: dir = "/tmp"
    dir / ("term_assert_client_test_" & $getCurrentProcessId() & ".sock")

  proc startServer(path: string): cint =
    discard unlink(cstring(path))
    let sh = posix.socket(AF_UNIX, SOCK_STREAM, 0)
    doAssert sh.cint != -1
    var addrUn: Sockaddr_un
    addrUn.sun_family = typeof(addrUn.sun_family)(AF_UNIX)
    copyMem(addr addrUn.sun_path[0], cstring(path), path.len)
    addrUn.sun_path[path.len] = '\0'
    doAssert bindSocket(sh, cast[ptr SockAddr](addr addrUn),
                        SockLen(sizeof(addrUn))) == 0
    doAssert listen(sh, 1) == 0
    return sh.cint

  proc serveProtocol(lfd: cint) =
    discard alarm(10)
    let sh = posix.accept(SocketHandle(lfd), nil, nil)
    doAssert sh.cint != -1
    discard posix.close(lfd)
    let cfd = sh.cint
    defer: discard posix.close(cfd)
    for expected in [%*{"cmd": "ping"},
                     %*{"cmd": "screenshot", "label": "first"},
                     %*{"cmd": "exit", "code": 0}]:
      var line = ""
      while true:
        var ch: char
        let n = posix.read(cfd, addr ch, 1)
        doAssert n == 1
        if ch == '\n': break
        line.add ch
      let parsed = parseJson(line)
      doAssert parsed.kind == JObject
      doAssert parsed.hasKey("cmd")
      doAssert parsed == expected
      var resp = %*{"ok": true}
      if expected["cmd"].getStr == "ping": resp["pong"] = %true
      let data = $resp & "\n"
      var offset = 0
      while offset < data.len:
        let n = posix.write(cfd, unsafeAddr data[offset], data.len - offset)
        doAssert n > 0
        offset += n

  proc reap(pid: Pid; status: var cint): Pid =
    while true:
      result = waitpid(pid, status, 0)
      if result != -1 or errno != EINTR: return

  suite "TermAssertClient smoke":
    test "connect + ping + screenshot + exit":
      let path = allocPath()
      let lfd = startServer(path)
      defer:
        discard posix.close(lfd)
        discard unlink(cstring(path))
      let hadUri = existsEnv("TERM_ASSERT_URI")
      let originalUri = getEnv("TERM_ASSERT_URI")
      defer:
        if hadUri: putEnv("TERM_ASSERT_URI", originalUri)
        else: delEnv("TERM_ASSERT_URI")
      putEnv("TERM_ASSERT_URI", path)

      # Fork before constructing the client or starting any test worker threads.
      let child = fork()
      doAssert child >= 0
      if child == 0:
        try:
          serveProtocol(lfd)
          exitnow(0)
        except Exception:
          exitnow(1)
      var reaped = false
      defer:
        if not reaped:
          discard kill(child, SIGKILL)
          var status: cint
          discard reap(child, status)

      var client = connectHarness()
      defer: client.close()
      # Bound real transport operations without adding a production timeout API.
      var timeout = Timeval(tv_sec: Time(5), tv_usec: Suseconds(0))
      doAssert setsockopt(SocketHandle(client.fd), SOL_SOCKET, SO_RCVTIMEO,
                         addr timeout, SockLen(sizeof(timeout))) == 0
      doAssert setsockopt(SocketHandle(client.fd), SOL_SOCKET, SO_SNDTIMEO,
                         addr timeout, SockLen(sizeof(timeout))) == 0
      let pong = client.ping()
      check pong
      client.requestScreenshot("first")
      client.requestExit(0)
      check client.isConnected
      var status: cint
      let waited = reap(child, status)
      reaped = waited == child
      check waited == child
      check WIFEXITED(status)
      check WEXITSTATUS(status) == 0
