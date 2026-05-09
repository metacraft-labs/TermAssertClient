## term_assert_client - companion library for child processes coordinating
## with a TermAssert harness.
##
## A child process spawned under TermAssert receives the harness IPC URI in
## the `TERM_ASSERT_URI` environment variable. The child can then call
## `connectHarness()` and request screenshots / a clean exit / a health
## check via tiny line-delimited JSON messages.
##
## This library deliberately avoids any pty / libvterm dependency so
## production app code can ship a "request screenshot under test" hook
## without dragging in the full harness stack.
##
## Wire protocol (line-delimited JSON):
##
## ```text
## -> {"cmd": "screenshot", "label": "main_menu"}
## <- {"ok": true}
## -> {"cmd": "exit", "code": 0}
## <- {"ok": true}
## -> {"cmd": "ping"}
## <- {"ok": true, "pong": true}
## ```
##
## Public API rules
## ----------------
## * `TuiTestClient` is a value `object` with an owning Unix-socket FD.
## * `=copy` is disabled; `=destroy` releases the FD.
## * No raw `ptr` is exposed.

import std/[json, os, posix, options]

type
  TuiTestClient* = object
    ## Owning handle for one connection to the harness IPC socket.
    fd*: cint
    closed*: bool

  TuiTestClientError* = object of CatchableError

proc `=copy`*(dest: var TuiTestClient; src: TuiTestClient) {.error.}

when defined(gcDestructors):
  proc `=destroy`*(c: TuiTestClient) =
    if not c.closed and c.fd > 2:
      discard posix.close(c.fd)
else:
  proc `=destroy`*(c: var TuiTestClient) =
    if not c.closed and c.fd > 2:
      discard posix.close(c.fd)

proc raiseClient(ctx: string) {.noreturn.} =
  raise newException(TuiTestClientError,
    ctx & ": " & osErrorMsg(osLastError()) & " (errno=" & $int(osLastError()) & ")")

proc connectHarness*(uri: string = ""): TuiTestClient =
  ## Connect to the TermAssert harness socket. Defaults to reading the
  ## URI from `$TERM_ASSERT_URI`. Raises `TuiTestClientError` on connect
  ## failure.
  var path = uri
  if path.len == 0:
    path = getEnv("TERM_ASSERT_URI")
  if path.len == 0:
    raise newException(TuiTestClientError,
      "TERM_ASSERT_URI is empty; pass a URI explicitly or run under the harness")

  let sh = posix.socket(AF_UNIX, SOCK_STREAM, 0)
  if sh.cint == -1:
    raiseClient("socket")
  let s = sh.cint
  var addrUn: Sockaddr_un
  addrUn.sun_family = AF_UNIX.cushort
  if path.len >= sizeof(addrUn.sun_path):
    discard posix.close(s)
    raise newException(TuiTestClientError,
      "URI too long for sockaddr_un: " & path)
  copyMem(addr addrUn.sun_path[0], cstring(path), path.len)
  addrUn.sun_path[path.len] = '\0'
  if connect(sh, cast[ptr SockAddr](addr addrUn),
             SockLen(sizeof(addrUn))) == -1:
    let e = osLastError()
    discard posix.close(s)
    raise newException(TuiTestClientError,
      "connect(" & path & "): " & osErrorMsg(e))
  result = TuiTestClient(fd: s, closed: false)

proc isConnected*(c: TuiTestClient): bool {.inline.} =
  not c.closed and c.fd >= 0

proc close*(c: var TuiTestClient) =
  if not c.closed and c.fd > 2:
    discard posix.close(c.fd)
    c.fd = -1
    c.closed = true

proc writeAll(fd: cint; data: string) =
  var off = 0
  while off < data.len:
    let n = posix.write(fd, unsafeAddr data[off], data.len - off)
    if n < 0:
      let e = osLastError()
      if cint(e) == EINTR: continue
      raiseClient("write")
    if n == 0:
      raise newException(TuiTestClientError, "short write")
    off += n

proc readLine(fd: cint): string =
  ## Read until newline; up to 64 KiB. Used to read the JSON reply.
  result = ""
  var byte0: char
  for i in 0 ..< 65536:
    let n = posix.read(fd, addr byte0, 1)
    if n < 0:
      let e = osLastError()
      if cint(e) == EINTR: continue
      raiseClient("read")
    if n == 0:
      return result
    if byte0 == '\n':
      return result
    result.add byte0

proc sendCmd*(c: var TuiTestClient; payload: JsonNode): JsonNode =
  ## Send `payload` as one line, read one line back, return the parsed
  ## reply.
  if not c.isConnected:
    raise newException(TuiTestClientError, "client is not connected")
  let line = $payload & "\n"
  writeAll(c.fd, line)
  let reply = readLine(c.fd)
  if reply.len == 0:
    raise newException(TuiTestClientError, "harness closed connection")
  try:
    return parseJson(reply)
  except CatchableError as e:
    raise newException(TuiTestClientError,
      "failed to parse harness reply: " & e.msg & " | line=" & reply)

proc requestScreenshot*(c: var TuiTestClient; label: string) =
  ## Ask the harness to capture the current parsed screen under `label`.
  let reply = c.sendCmd(%*{"cmd": "screenshot", "label": label})
  if not (reply.kind == JObject and reply.hasKey("ok") and reply["ok"].bval):
    raise newException(TuiTestClientError,
      "harness screenshot rejected: " & $reply)

proc requestExit*(c: var TuiTestClient; code: int) =
  ## Tell the harness this process is ready to exit; the harness will
  ## acknowledge and the child can then call `quit(code)`.
  let reply = c.sendCmd(%*{"cmd": "exit", "code": code})
  if not (reply.kind == JObject and reply.hasKey("ok") and reply["ok"].bval):
    raise newException(TuiTestClientError,
      "harness exit rejected: " & $reply)

proc ping*(c: var TuiTestClient): bool =
  ## Health check; returns true if the harness replied with pong.
  let reply = c.sendCmd(%*{"cmd": "ping"})
  result = reply.kind == JObject and reply.hasKey("pong") and
           reply["pong"].bval

# Re-export options for convenience.
export options
