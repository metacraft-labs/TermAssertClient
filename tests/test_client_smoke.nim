## test_client_smoke - smoke test for the TermAssertClient library.
##
## Spins up an independent Unix-socket peer in a forked child, exposes its
## path via $TERM_ASSERT_URI, then exercises connectHarness / ping /
## requestScreenshot / requestExit and verifies the wire protocol.
##
## The responder deliberately stubs TermAssert to provide an independent wire
## oracle without a circular dependency. Socket operations, process isolation,
## JSON parsing and the production client are real integration boundaries.

import std/[unittest, json, os, posix]
import term_assert_client

proc allocPath(): string =
  var dir = getEnv("TMPDIR")
  if dir.len == 0: dir = "/tmp"
  dir / ("term_assert_client_test_" & $getCurrentProcessId() & ".sock")

proc startServer(path: string): cint =
  discard unlink(cstring(path))
  let sh = posix.socket(AF_UNIX, SOCK_STREAM, 0)
  doAssert sh.cint != -1
  var addrUn: Sockaddr_un
  addrUn.sun_family = AF_UNIX.cushort
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
