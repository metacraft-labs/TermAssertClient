## test_client_smoke - smoke test for the TermAssertClient library.
##
## Spins up a tiny Unix-socket server in the test process, exposes its
## path via $TERM_ASSERT_URI, then exercises connectHarness / ping /
## requestScreenshot / requestExit and verifies the wire protocol.

import std/[unittest, json, os, posix, options]
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

suite "TermAssertClient smoke":
  test "connect + ping + screenshot + exit":
    let path = allocPath()
    let lfd = startServer(path)
    defer:
      discard posix.close(lfd)
      discard unlink(cstring(path))
    putEnv("TERM_ASSERT_URI", path)

    # Spawn the client connection in this same process; the server side
    # runs in a tiny accept loop.
    var client = connectHarness()
    var addrUn: Sockaddr_un
    var alen = SockLen(sizeof(addrUn))
    let sh = posix.accept(SocketHandle(lfd),
                          cast[ptr SockAddr](addr addrUn), addr alen)
    doAssert sh.cint != -1
    let cfd = sh.cint
    defer: discard posix.close(cfd)

    # A line-by-line server. After every received command we send back
    # `{"ok": true}` (plus pong for ping).
    proc readReply(c: cint): string =
      result = ""
      while true:
        var ch: char
        let n = posix.read(c, addr ch, 1)
        if n <= 0: break
        if ch == '\n': break
        result.add ch

    proc reply(c: cint; payload: JsonNode) =
      let s = $payload & "\n"
      var off = 0
      while off < s.len:
        let n = posix.write(c, unsafeAddr s[off], s.len - off)
        if n <= 0: break
        off += n

    # Ping
    var senderThread: Thread[void]
    discard senderThread

    # Run the client requests in this thread, but read from the server
    # side first to demonstrate. Use a simple alternation: invoke the
    # client request via a helper and have the server immediately reply.
    proc serverReplyTo(c: cint; pong: bool = false) =
      let req = readReply(c)
      let parsed = parseJson(req)
      doAssert parsed.kind == JObject
      doAssert parsed.hasKey("cmd")
      var resp = newJObject()
      resp["ok"] = newJBool(true)
      if pong: resp["pong"] = newJBool(true)
      reply(c, resp)

    # We need the request and the reply to overlap. The test driver
    # uses a small fork-style: prime the request in a fire-and-forget
    # way, then service it.
    when compileOption("threads"):
      var srvThread: Thread[cint]
      proc srvProcPing(c: cint) {.thread.} =
        serverReplyTo(c, true)
      createThread(srvThread, srvProcPing, cfd)
      let pong = client.ping()
      joinThread(srvThread)
      check pong

      proc srvProcSnap(c: cint) {.thread.} =
        serverReplyTo(c)
      createThread(srvThread, srvProcSnap, cfd)
      client.requestScreenshot("first")
      joinThread(srvThread)

      proc srvProcExit(c: cint) {.thread.} =
        serverReplyTo(c)
      createThread(srvThread, srvProcExit, cfd)
      client.requestExit(0)
      joinThread(srvThread)

      check client.isConnected
    else:
      skip()
    delEnv("TERM_ASSERT_URI")
