using concurrent

**
** T13 user smoke regression: a sustained, paced interactive burst through the
** production main loop (reader thread, cancel tokens, dispatcher, mailbox
** apply) on an explicitly supplied real workspace, starting as soon as the
** index completes so background warm-up compiles overlap the burst exactly as
** in the failed F5 session. Read-only: no workspace file is written; the
** document is opened from its disk text. Opt in with FANTOM_LSP_RECOVERY_ROOT
** and FANTOM_LSP_RECOVERY_FILE; skipped by default, invalid opt-ins fail.
**
** Latency is measured from the moment the client frame is released to the
** reader thread until the handler returns (queueing included).
**
class InteractiveRecoveryTest : Test
{
  ** Pacing: one "click" cycle every cycleMs for cycles cycles.
  ** One full hover/move/click cycle per second for 100 s: several times the
  ** request rate in the user's failing log (about 240 messages in 5 min).
  static const Int cycleMs := 1000
  static const Int cycles := 100

  Void testSustainedBurstRecoveryCancelAndFairness()
  {
    rootPath := Env.cur.vars["FANTOM_LSP_RECOVERY_ROOT"]?.trim
    filePath := Env.cur.vars["FANTOM_LSP_RECOVERY_FILE"]?.trim
    if (rootPath == null && filePath == null)
    {
      echo("T13 InteractiveRecoveryTest: SKIPPED (opt-in requires FANTOM_LSP_RECOVERY_ROOT and FANTOM_LSP_RECOVERY_FILE)")
      return
    }
    verify(rootPath != null && !rootPath.isEmpty, "FANTOM_LSP_RECOVERY_ROOT must name a workspace directory")
    verify(filePath != null && !filePath.isEmpty, "FANTOM_LSP_RECOVERY_FILE must name the real fixture file")
    root := File.os(rootPath).normalize
    fixture := File.os(filePath).normalize
    verify(root.exists && root.isDir, "recovery root is not an existing directory: $root")
    verify(fixture.parent.exists && fixture.parent.isDir, "recovery fixture parent is not an existing directory: $fixture.parent")
    verify(fixture.exists && !fixture.isDir && fixture.ext == "fan", "recovery fixture is not an existing .fan file: $fixture")
    rootKey := UriKey.canonical(WorkspaceManager.fileToUri(root))
    fileKey := UriKey.canonical(WorkspaceManager.fileToUri(fixture))
    verify(fileKey.startsWith(rootKey.endsWith("/") ? rootKey : rootKey + "/"), "recovery fixture must be inside the supplied workspace root")
    text := fixture.readAllStr
    lines := TextDocumentManager.toLines(text)
    uri := UriKey.toClientUri(WorkspaceManager.fileToUri(fixture))
    td := ["uri": uri]

    // Positions that were slow or common in the failed session: sys types,
    // dynamic calls, closure signature return types, slots and locals.
    spots := Position[,]
    [["->status", 2], ["->toStr", 2], ["s->Str|", 3], ["Str[] ids", 0], ["Dict manifest", 0],
     ["List", 0], ["nvAiSetupDiscoveryAttempt", 0], ["ids :=", 0], ["skills.map", 0], ["Int ", 0]].each |pair|
    {
      needle := (Str)pair[0]
      i := lines.findIndex |l| { l.contains(needle) }
      if (i != null) spots.add(Position(i, lines[i].index(needle) + (Int)pair[1]))
    }
    verify(spots.size >= 8, "fixture spots=$spots.size")

    // Code-lens resolve payloads in the provider's data shape.
    typeName := lines.eachWhile |l| { m := Regex<|^\s*(?:\w+\s+)*class\s+(\w+)|>.matcher(l); return m.find ? m.group(1) : null }
    lensKeys := Str[,]
    lines.each |l|
    {
      m := Regex<|^\s+static\s+[\w\[\]?:]+\s+(\w+)\(|>.matcher(l)
      if (m.find && lensKeys.size < 2) lensKeys.add("nv5Ai::${typeName}.${m.group(1)}")
    }

    ready := AtomicBool(false)
    start := AtomicInt(0)
    released := ConcurrentMap()
    events := BurstEvent[,]
    methods := Str:Str[:]
    cancelOf := Str:Str[:]   // request id -> cancel release key
    nextId := 100
    req := |Int at, Str method, Obj params->Str|
    {
      id := (nextId++).toStr
      events.add(BurstEvent(at, frame(["id": id, "method": method, "params": params]), "req:$id"))
      methods[id] = method
      return id
    }
    cancel := |Int at, Str id|
    {
      events.add(BurstEvent(at, frame(["method": "\$/cancelRequest", "params": ["id": id]]), "cancel:$id"))
      cancelOf[id] = "cancel:$id"
    }

    events.add(BurstEvent(-1, frame(["id": 1, "method": "initialize", "params": ["rootUri": UriKey.toClientUri(WorkspaceManager.fileToUri(root)),
      "capabilities": Str:Obj?[:]]])))
    events.add(BurstEvent(-1, frame(["method": "initialized", "params": Str:Obj?[:]])))
    events.add(BurstEvent(-1, frame(["method": "textDocument/didOpen", "params": ["textDocument":
      ["uri": uri, "languageId": "fantom", "version": 1, "text": text]]])))
    events.add(BurstEvent(-1, frame(["id": 2, "method": "workspace/symbol", "params": ["query": BurstDispatcher.waitQuery]])))
    events.add(BurstEvent.gate)

    Str? lastHighlight := null
    cycles.times |c|
    {
      t := c * cycleMs
      a := spots[c % spots.size]
      b := spots[(c + 3) % spots.size]
      at := |Position p->Obj| { ["textDocument": td, "position": p.toMap] }
      if (lastHighlight != null) cancel(t, lastHighlight)
      h1 := req(t, "textDocument/hover", at(a))
      // The mouse moved on: VS Code cancels the pending hover.
      cancel(t + 100, h1)
      req(t + 100, "textDocument/hover", at(b))
      lastHighlight = req(t + 150, "textDocument/documentHighlight", at(b))
      req(t + 250, "textDocument/definition", at(b))
      req(t + 400, "textDocument/codeAction", ["textDocument": td, "range": LspRange(Position(b.line, 0), Position(b.line, 0)).toMap,
        "context": ["diagnostics": [,]]])
      if (c % 2 == 0)
        req(t + 450, "textDocument/inlayHint", ["textDocument": td, "range": LspRange(Position(b.line / 60 * 60, 0), Position(b.line / 60 * 60 + 60, 0)).toMap])
      if (c % 10 == 5)
      {
        req(t + 500, "textDocument/codeLens", ["textDocument": td])
        lensKeys.each |k, i| { req(t + 520 + i * 10, "codeLens/resolve", ["range": LspRange(spots[0], spots[0]).toMap, "data": ["uri": uri, "key": k]]) }
      }
    }
    lastBurst := events.last
    end := lastBurst.at
    // Recovery probe immediately after the final burst frame, with no quiet
    // grace period. Equal schedule times preserve frame order in the reader.
    // Probe a non-dynamic declaration so it measures residual queueing only.
    probeSpot := spots.find |p| { lines[p.line].contains("Dict manifest") } ?: spots[0]
    probe := req(end, "textDocument/hover", ["textDocument": td, "position": probeSpot.toMap])
    events.add(BurstEvent(end + 1700, frame(["id": 3, "method": "shutdown", "params": Str:Obj?[:]])))
    events.add(BurstEvent(end + 1750, frame(["method": "exit", "params": Str:Obj?[:]])))

    server := FantomLanguageServer()
    dispatcher := BurstDispatcher(server, ready)
    loop := LspMainLoop(server, BurstScriptIn(events, ready, start, released), dispatcher)
    verifyEq(loop.run, 0)

    // Exactly one non-error response per request; cancellation never errs.
    responses := server.drainOutgoing.findAll |m| { m["id"] != null && m["method"] == null }
    byId := Str:[Str:Obj?][:]
    responses.each |m| { k := m["id"].toStr; verifyFalse(byId.containsKey(k), "duplicate response " + k); byId[k] = m }
    methods.each |m, id|
    {
      r := byId[id]
      verifyNotNull(r, "missing response " + id + " " + m)
      verifyNull(r?.get("error"), m + " " + id + ": " + r?.get("error"))
    }
    verify(server.cancelTokens.isEmpty, "leaked cancel tokens")

    ms := |Int ticks->Int| { ticks / 1ms.ticks }
    lat := Str:Int[][:]
    cancelled := 0; lateCancel := Str[,]
    methods.each |m, id|
    {
      if (id == probe) return
      rel := released["req:$id"] as Int
      endT := dispatcher.ended[id]
      verifyNotNull(rel, "missing release timestamp $id")
      verifyNotNull(endT, "missing completion timestamp $id")
      l := lat[m]
      if (l == null) { l = Int[,]; lat[m] = l }
      l.add(ms(endT - rel))
      key := cancelOf[id]
      crel := key == null ? null : released[key] as Int
      if (crel != null && endT > crel)
      {
        cancelled++
        startT := dispatcher.started[id]
        // Once the cancel is visible, the request must finish within 100 ms
        // (already running), or return immediately (still queued).
        own := startT >= crel ? ms(endT - startT) : ms(endT - crel)
        if (own > 100) lateCancel.add("$m#$id ${own}ms")
      }
    }
    own := Str[,]
    methods.each |m, id|
    {
      s := dispatcher.started[id]; e := dispatcher.ended[id]
      if (s != null && e != null) own.add(ms(e - s).toStr.padl(6) + "ms " + m + " " + (dispatcher.params[id]?.get("position") ?: ""))
    }
    echo("T13 slowest handler times:\n  " + own.sortr[0..<own.size.min(12)].join("\n  "))
    summary := StrBuf()
    interactive := Int[,]
    lat.keys.sort.each |m|
    {
      l := lat[m].sort
      summary.add("\n  ${m.padr(32)} n=${l.size.toStr.padl(3)} p50=${pct(l, 50)} p95=${pct(l, 95)} max=${l.last}ms")
      if (m == "textDocument/hover" || m == "textDocument/definition" || m == "textDocument/documentHighlight") interactive.addAll(l)
    }
    interactive.sort
    lastRelease := released[lastBurst.key] as Int
    verifyNotNull(lastRelease, "missing final burst frame release timestamp")
    verifyNotNull(released["req:$probe"], "missing recovery probe release timestamp")
    verifyNotNull(dispatcher.ended[probe], "missing recovery probe completion timestamp")
    Int lastBurstEnd := dispatcher.ended.findAll |v, k| { k != probe && methods.containsKey(k) }.vals.max ?: 0
    tail := ms(lastBurstEnd - lastRelease)
    probeMs := ms(dispatcher.ended[probe] - (Int)released["req:$probe"])
    echo("T13 sustained burst (root ${root.osPath}, ${cycles * cycleMs}ms pacing window, ${methods.size} requests, warm-up compiles=${server.semanticCompileCount}, snapshots=${server.semanticSnapshots.size}):" +
      summary + "\n  interactive p95=${pct(interactive, 95)} max=${interactive.last}ms; cancels after-start=$cancelled late=$lateCancel; " +
      "drain after last release=${tail}ms; recovery probe hover=${probeMs}ms")

    verify(pct(interactive, 95) <= 300, "interactive p95 ${pct(interactive, 95)}ms")
    verify(interactive.last <= 1000, "interactive max ${interactive.last}ms")
    verify(lateCancel.isEmpty, "late cancels $lateCancel")
    verify(tail <= 1000, "queue drained ${tail}ms after the last burst frame")
    verify(probeMs <= 200, "recovery probe ${probeMs}ms")
    verify(byId[probe]?.get("result") != null, "recovery probe returned no hover")
  }

  private static Int pct(Int[] sorted, Int p)
  { sorted.isEmpty ? 0 : sorted[(sorted.size * p / 100).min(sorted.size - 1)] }

  private static Str frame([Str:Obj?] msg)
  {
    msg["jsonrpc"] = "2.0"
    body := JsonRpc.encode(msg)
    return "Content-Length: ${body.toBuf.size}\r\n\r\n$body"
  }
}

** One scripted client frame: at < 0 releases immediately, otherwise at ms
** after the gate opened. A gate blocks until the server reports readiness.
internal class BurstEvent
{
  new make(Int at, Str frame, Str? key := null, Bool gate := false)
  { this.at = at; this.frame = frame; this.key = key; this.isGate = gate }
  static BurstEvent gate() { BurstEvent(-1, "", null, true) }
  Int at
  Str frame
  Str? key
  Bool isGate
}

** Paced client: releases each frame at its scheduled time on the reader
** thread, recording release ticks for latency accounting.
internal class BurstScriptIn : InStream
{
  new make(BurstEvent[] events, AtomicBool ready, AtomicInt start, ConcurrentMap released) : super(null)
  { this.events = events; this.ready = ready; this.start = start; this.released = released }

  private BurstEvent[] events
  private AtomicBool ready
  private AtomicInt start
  private ConcurrentMap released
  private Buf? cur
  private Int index := 0

  override Int? read()
  {
    while (cur == null || cur.remaining == 0)
    {
      if (index >= events.size) return null
      e := events[index++]
      if (e.isGate)
      {
        deadline := Duration.now + 180sec
        while (!ready.val && Duration.now < deadline) Actor.sleep(10ms)
        if (!ready.val) throw IOErr("index never completed")
        start.val = Duration.nowTicks
      }
      else if (e.at >= 0)
      {
        wait := start.val + e.at * 1ms.ticks - Duration.nowTicks
        if (wait > 0) Actor.sleep(Duration(wait))
      }
      if (e.key != null) released[e.key] = Duration.nowTicks
      cur = e.frame.toBuf
    }
    return cur.read
  }

  override Int? readBuf(Buf buf, Int n)
  {
    b := read
    if (b == null) return null
    buf.write(b)
    return 1
  }

  override This unread(Int b) { throw UnsupportedErr("unread") }
}

** Production dispatcher with timing only. The setup wait request blocks the
** dispatch thread until the background index is applied (setup, not timed).
internal class BurstDispatcher : LspDispatcher
{
  static const Str waitQuery := "__t13_wait_index__"
  private FantomLanguageServer target
  private AtomicBool ready
  Str:Int started := [:]
  Str:Int ended := [:]
  Str:[Str:Obj?] params := [:]

  new make(FantomLanguageServer server, AtomicBool ready) : super(server)
  { target = server; this.ready = ready }

  protected override Obj? handleRequest(Obj id, Str method, [Str:Obj?] params)
  {
    if (method == "workspace/symbol" && params["query"] == waitQuery)
    {
      deadline := Duration.now + 170sec
      while (!target.indexComplete && Duration.now < deadline)
      {
        target.applyBackgroundResults
        Actor.sleep(20ms)
      }
      ready.val = true
      return target.indexComplete
    }
    k := id.toStr
    this.params[k] = params
    started[k] = Duration.nowTicks
    try return super.handleRequest(id, method, params)
    finally ended[k] = Duration.nowTicks
  }
}
