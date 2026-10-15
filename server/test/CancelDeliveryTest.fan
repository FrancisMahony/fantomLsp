using concurrent

** T04b: cancellation must be read while dispatch is inside ensureFresh, not
** preloaded by the test or delivered after the ten-second freshness timeout.
class CancelDeliveryTest : Test
{
  private TestWorkspace ws := TestWorkspace()

  override Void teardown() { ws.cleanup }

  Void testMidWaitInProcess()
  {
    file := ws.root + `Wait.fan`
    file.out.print("class Wait {}\n").close
    started := AtomicBool(false)
    server := FantomLanguageServer()
    probe := CancelWaitDispatcher(server, |->Void| { started.val = true })
    input := CancelScriptInStream(prefix(file), suffix(file), |->Bool| { started.val })
    loop := LspMainLoop(server, input, probe)
    verifyEq(loop.run, 0)
    verifyEq(loop.messagesHandled, 6)
    verifyEq(probe.waitCalls, 1)
    verifyEq(probe.hoverCalls, 1)
    verifyEq(probe.shutdownCalls, 1)
    verifyEq(server.compileRequested, 1)
    verify(server.completedGen.isEmpty)
    verify(server.cancelTokens.isEmpty)
    verifyResponses(server.drainOutgoing)
  }

  Void testMidWaitChildStdio()
  {
    file := ws.root + `Wait.fan`
    file.out.print("class Wait {}\n").close
    marker := ws.root + `started`
    runtime := (ws.root + `runtime/`).create
    lib := (runtime + `lib/fan/`).create
    Env.cur.findPodFile("fantomLsp").copyTo(lib + `fantomLsp.pod`)
    javaHome := Env.cur.vars["JAVA_HOME"]
    java := javaHome == null ? "java" :
      (File.os(javaHome) + (Env.cur.os == "win32" ? `bin/java.exe` : `bin/java`)).osPath
    output := Buf(); errors := Buf()
    child := Process()
    child.command = [java, "-Dfan.home=${Env.cur.homeDir.osPath}", "-cp",
      (Env.cur.homeDir + `lib/java/sys.jar`).osPath, "fanx.tools.Fan",
      "fantomLsp::CancelDeliveryProbe", marker.osPath]
    child.dir = runtime
    child.env.keys.each |key|
    {
      if (key.upper == "FAN_ENV" || key.upper == "FAN_ENV_PATH") child.env.remove(key)
    }
    child.env["FAN_ENV"] = "util::PathEnv"
    child.env["FAN_ENV_PATH"] = runtime.osPath
    child.in = CancelScriptInStream(prefix(file), suffix(file), |->Bool| { marker.exists })
    child.out = output.out
    child.mergeErr = false
    child.err = errors.out
    finished := AtomicBool(false)
    childRef := Unsafe(child)
    watchdogPool := ActorPool()
    watchdog := Actor(watchdogPool) |Obj? msg->Obj?|
    {
      deadline := Duration.now + 20sec
      while (!finished.val && Duration.now < deadline) Actor.sleep(50ms)
      if (!finished.val) ((Process)childRef.val).kill
      return null
    }
    try
    {
      child.run
      watchdog.send(null)
      code := child.join
      finished.val = true
      text := errors.flip.readAllStr
      verifyEq(code, 0, text)
      verify(text.contains("T04b child PASS: handled=6 tokens=0 wait=1 hover=1 shutdown=1"), text)
      rpc := JsonRpc(output.flip.in, Buf().out)
      msgs := [Str:Obj?][,]
      while (true)
      {
        msg := rpc.readMessage
        if (msg == null) break
        msgs.add(msg)
      }
      verifyResponses(msgs)
    }
    finally { finished.val = true; watchdogPool.stop.join }
  }

  ** T13: a $/cancelRequest delivered by the reader thread while a real
  ** callHierarchy/incomingCalls request runs stops its fallback loop. The
  ** response is a normal null result for the actual request ID (no -32603).
  Void testMidRequestCallHierarchyCancel()
  {
    pod := "cancel" + ws.id
    file := midCancelFixture(pod)
    // 800 same-name calls: the uncancelled request stops at the 500 cap.
    full := midRequestCancel(file, "callHierarchy/incomingCalls", ["item": ["data": ["key": "$pod::A.other"]]])
    if (full == null) return
    total := 0
    (full as List).each |[Str:Obj?] e| { total += (e["fromRanges"] as List).size }
    verifyEq(total, HierarchyContext.fallbackCap)
  }

  ** T13: textDocument/references forwards the actual request ID; the reader
  ** thread's cancel stops its bounded heuristic fallback loop mid-request.
  Void testMidRequestReferencesCancel()
  {
    file := midCancelFixture("refcancel" + ws.id)
    text := file.readAllStr
    line := TextDocumentManager.toLines(text).findIndex |l| { l.contains("other()") && !l.contains("Void") }
    midRequestCancel(file, "textDocument/references", ["textDocument": ["uri": WorkspaceManager.fileToUri(file)],
      "position": Position(line, 4).toMap, "context": ["includeDeclaration": false]], true)
  }

  private File midCancelFixture(Str pod)
  {
    buf := StrBuf().add("class A\n{\n  Void other() {}\n")
    20.times |m|
    {
      buf.add("  Void go$m(Int x)\n  {\n")
      40.times |i| { buf.add("    v$i := x + $i\n    other()\n") }
      buf.add("  }\n")
    }
    return ws.writePod(pod, ["A.fan": buf.add("}\n").toStr]) + `fan/A.fan`
  }

  ** Runs method uncancelled (baseline) and then through the production loop
  ** with a reader-delivered mid-request cancel. Returns the baseline result,
  ** or null when the machine is too fast for a meaningful timing bound.
  private Obj? midRequestCancel(File file, Str method, [Str:Obj?] params, Bool open := false)
  {
    uri := WorkspaceManager.fileToUri(file)
    didOpen := ["jsonrpc": "2.0", "method": "textDocument/didOpen", "params": ["textDocument":
      ["uri": uri, "languageId": "fantom", "version": 1, "text": file.readAllStr]]]
    init := frame(["id": 1, "method": "initialize", "params": ["rootUri": WorkspaceManager.fileToUri(ws.root),
      "initializationOptions": ["envPath": [ws.root.osPath], "semanticIndex": ["backgroundCompile": false]]]])

    // Uncancelled baseline through the same production entry point.
    base := FantomLanguageServer()
    LspDispatcher(base).dispatch(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params":
      ["rootUri": WorkspaceManager.fileToUri(ws.root), "initializationOptions":
      ["envPath": [ws.root.osPath], "semanticIndex": ["backgroundCompile": false]]]])
    base.indexWorkspaceNow
    if (open) LspDispatcher(base).dispatch(didOpen)
    t0 := Duration.now
    full := LspDispatcher(base).dispatch(["jsonrpc": "2.0", "id": 9, "method": method, "params": params])
    baseline := (Duration.now - t0).toMillis
    base.shutdown
    verifyNull(full["error"], full.toStr)
    if (baseline < 700) { echo("T13 $method cancel fixture too fast ($baseline ms); mid-request bound not asserted"); return null }

    started := AtomicBool(false)
    server := FantomLanguageServer()
    probe := CancelHierarchyDispatcher(server, method, |->Void| { started.val = true })
    prefix := init + (open ? frame(didOpen.dup) : "") + frame(["id": 5, "method": method, "params": params])
    suffix := frame(["method": "\$/cancelRequest", "params": ["id": 5]]) +
      frame(["id": 6, "method": "shutdown", "params": [Str:Obj?][:]]) +
      frame(["method": "exit", "params": [Str:Obj?][:]])
    loop := LspMainLoop(server, CancelScriptInStream(prefix, suffix, |->Bool| { started.val }), probe)
    verifyEq(loop.run, 0)
    msgs := server.drainOutgoing.findAll |m| { m["id"] != null }
    response := msgs.find |m| { m["id"] == 5 }
    verifyNotNull(response, msgs.toStr)
    verifyNull(response["error"], response.toStr)
    verify(response.containsKey("result"))
    verifyNull(response["result"])
    verify(probe.elapsed >= 150, "cancel not mid-request: $probe.elapsed ms")
    verify(probe.elapsed * 5 < baseline * 3, "cancel ignored: $probe.elapsed ms vs baseline $baseline ms")
    verify(server.cancelTokens.isEmpty)
    echo("T13 mid-request $method cancel: $probe.elapsed ms (uncancelled $baseline ms)")
    return full["result"]
  }

  Void testCancelKeyCompatibilityAndRequestRetirement()
  {
    server := FantomLanguageServer()
    server.cancelRequest(7)
    verify(server.isCancelled("7"))
    verifyFalse(server.isCancelled(7))
    server.cancelRequest("missing")
    response := LspDispatcher(server).dispatch(
      ["id": "missing", "method": "unknown", "params": [Str:Obj?][:]])
    verifyEq((response["error"] as Map)["code"], -32601)
    verify(server.cancelTokens.isEmpty)
    server.cancelRequest(null)
    verify(server.cancelTokens.isEmpty)
  }

  private Void verifyResponses([Str:Obj?][] msgs)
  {
    verifyEq(msgs.size, 3)
    verifyEq(msgs.map |m->Int| { (Int)m["id"] }, [1, 1, 3])
    verify(msgs.all |m| { m["error"] == null })
    result := msgs[0]["result"] as Map
    verifyEq(result["fresh"], false)
    elapsed := (Int)result["elapsedMs"]
    verify(elapsed >= 150, "not a mid-wait cancellation: $elapsed ms")
    verify(elapsed < 3000, "cancel waited $elapsed ms (freshness timeout is 10000 ms)")
    verifyEq(msgs[1]["result"], "hover-once")
    verifyNull(msgs[2]["result"])
    echo("T04b mid-wait cancel response: $elapsed ms; FIFO responses [1, 1, 3]")
  }

  private static Str prefix(File file)
  {
    frame(["id": 1, "method": "workspace/symbol", "params": ["query": WorkspaceManager.fileToUri(file)]])
  }

  private static Str suffix(File file)
  {
    // Reusing the ID immediately after the queued cancel catches token leaks.
    frame(["method": "\$/cancelRequest", "params": ["id": 1]]) +
    frame(["method": "\$/cancelRequest", "params": ["id": "unknown"]]) +
    frame(["id": 1, "method": "textDocument/hover", "params": [Str:Obj?][:]]) +
    frame(["id": 3, "method": "shutdown", "params": [Str:Obj?][:]]) +
    frame(["method": "exit", "params": [Str:Obj?][:]])
  }

  private static Str frame([Str:Obj?] msg)
  {
    msg["jsonrpc"] = "2.0"
    body := JsonRpc.encode(msg)
    return "Content-Length: ${body.toBuf.size}\r\n\r\n$body"
  }
}

** Test-only probe: production loop, reader, framing, dispatcher response path,
** and ensureFresh. No extra protocol method or production scheduling hook.
internal class CancelWaitDispatcher : LspDispatcher
{
  private FantomLanguageServer target
  private |->Void| started
  Int waitCalls := 0
  Int hoverCalls := 0
  Int shutdownCalls := 0

  new make(FantomLanguageServer server, |->Void| started) : super(server)
  {
    target = server; this.started = started
    // Quiesce only the worker, NOT the server. ensureFresh must still schedule
    // a nonzero generation, but it cannot finish before cancellation arrives.
    worker := (SemanticCompileActor)FantomLanguageServer#.field("compileActor").get(server)
    worker.stopRefresh
  }

  protected override Obj? handleRequest(Obj id, Str method, [Str:Obj?] params)
  {
    if (method == "workspace/symbol")
    {
      waitCalls++
      begin := Duration.now
      started()
      fresh := target.ensureFresh([(Str)params["query"]], 10sec, id)
      if (target.compileRequested != 1 || !target.completedGen.isEmpty)
        throw Err("Fixture failed to establish blocked nonzero compile generation")
      return ["fresh": fresh, "elapsedMs": (Duration.now - begin).toMillis]
    }
    if (method == "textDocument/hover")
    {
      hoverCalls++
      if (target.isCancelled(id)) throw Err("Queued cancel leaked into reused request ID")
      return "hover-once"
    }
    if (method == "shutdown") shutdownCalls++
    return super.handleRequest(id, method, params)
  }
}

** Test-only probe: indexes after initialize and times the real production
** handler for one method (no override of its work, ID forwarded unchanged).
internal class CancelHierarchyDispatcher : LspDispatcher
{
  private FantomLanguageServer target
  private |->Void| started
  private Str timed
  Int elapsed := -1

  new make(FantomLanguageServer server, Str timed, |->Void| started) : super(server)
  { target = server; this.timed = timed; this.started = started }

  protected override Obj? handleRequest(Obj id, Str method, [Str:Obj?] params)
  {
    if (method == "initialize")
    {
      result := super.handleRequest(id, method, params)
      target.indexWorkspaceNow
      return result
    }
    if (method == timed)
    {
      begin := Duration.now
      started()
      try return super.handleRequest(id, method, params)
      finally elapsed = (Duration.now - begin).toMillis
    }
    return super.handleRequest(id, method, params)
  }
}

class CancelDeliveryProbe
{
  static Void main(Str[] args)
  {
    marker := File.os(args[0])
    server := FantomLanguageServer()
    writer := StdioWriteActor(ActorPool(), Env.cur.out)
    server.stdioWriter = writer
    dispatcher := CancelWaitDispatcher(server, |->Void| { marker.out.print("started").close })
    loop := LspMainLoop(server, Env.cur.in, dispatcher)
    code := loop.run
    writer.send(null).get(5sec)
    if (loop.messagesHandled != 6 || !server.cancelTokens.isEmpty ||
        dispatcher.waitCalls != 1 || dispatcher.hoverCalls != 1 || dispatcher.shutdownCalls != 1)
      throw Err("Child FIFO/count/token invariant failed")
    Env.cur.err.printLine("T04b child PASS: handled=6 tokens=0 wait=1 hover=1 shutdown=1")
    Env.cur.exit(code)
  }
}

** The suffix is unavailable until the request's started marker, then delayed
** 200 ms so ensureFresh has entered its actual 100 ms polling wait.
internal class CancelScriptInStream : InStream
{
  private InStream first
  private InStream last
  private |->Bool| started
  private Bool released := false
  new make(Str prefix, Str suffix, |->Bool| started) : super(null)
  {
    first = prefix.toBuf.in; last = suffix.toBuf.in; this.started = started
  }
  override Int? read()
  {
    if (!released)
    {
      b := first.read
      if (b != null) return b
      deadline := Duration.now + 15sec
      while (!started() && Duration.now < deadline) Actor.sleep(5ms)
      if (!started()) throw IOErr("Request never reached started marker")
      Actor.sleep(200ms)
      released = true
    }
    return last.read
  }
  override Int? readBuf(Buf buf, Int n)
  {
    // Process's stdin pump asks for a large buffer. Return the prefix as a
    // short read so it reaches the child before waiting for its marker.
    if (!released)
    {
      got := first.readBuf(buf, n)
      if (got != null) return got
    }
    count := 0
    while (count < n)
    {
      b := read
      if (b == null) return count == 0 ? null : count
      buf.write(b); count++
    }
    return count
  }
  override This unread(Int b) { throw UnsupportedErr("unread") }
}
