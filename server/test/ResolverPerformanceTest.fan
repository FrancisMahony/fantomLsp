** Dispatch-thread latency regressions on a large compiled file. Limits
** carry a wide machine margin; the pre-fix implementation took seconds for
** hover/definition and tens of seconds for code lens on this shape.
class ResolverPerformanceTest : Test
{
  private TestWorkspace ws := TestWorkspace()
  private FantomLanguageServer? server

  override Void teardown()
  {
    if (server != null) { server.awaitBackground; server.shutdown }
    ws.cleanup
  }

  private static Str uri(File f) { WorkspaceManager.fileToUri(f) }

  private FantomLanguageServer session()
  {
    s := FantomLanguageServer()
    server = s
    s.initialize(["rootUri": uri(ws.root), "initializationOptions":
      ["envPath": [ws.root.osPath], "semanticIndex": ["backgroundCompile": false]]])
    s.indexWorkspaceNow
    return s
  }

  ** count helper methods f<i>, each called from g<i>; ~11 lines per pair.
  private static Str bigSource(Int count)
  {
    buf := StrBuf().add("class Big\n{\n")
    count.times |i|
    {
      buf.add("  Int f${i}(Int x)\n  {\n    y := x + $i\n    return y + x\n  }\n")
      buf.add("  Int g${i}()\n  {\n    a := f${i}(1)\n    b := f${(i + 1) % count}(a)\n    return a + b + a\n  }\n")
    }
    return buf.add("}\n").toStr
  }

  private static Int ms(|->| f)
  {
    start := Duration.now
    f()
    return (Duration.now - start).toMillis
  }

  Void testLargeFileHoverDefinitionLensAndHierarchyLatency()
  {
    pod := ws.podName
    text := bigSource(150)
    sources := ["Big.fan": text]
    // Other closed workspace files must not be re-read per occurrence.
    20.times |i| { sources["Extra${i}.fan"] = "class Extra$i { Int v$i() { Big().f${i}(2) } }\n" }
    dir := ws.writePod(pod, sources)
    file := uri(dir + `fan/Big.fan`)
    s := session()
    verify(s.ensureFresh([uri(dir + `build.fan`)], 60sec))
    lines := TextDocumentManager.toLines(text)
    verify(lines.size >= 1000, "lines=$lines.size")
    snap := s.semanticSnapshots[uri(dir + `build.fan`)]
    verify(snap.occByFile[file].size >= 1500, "occs=${snap.occByFile[file].size}")

    // Open and shift by one line so every lookup goes through position mapping.
    shifted := "// edit\n" + text
    s.didOpen(["textDocument": ["uri": file, "languageId": "fantom", "version": 1, "text": text]])
    s.didChange(["textDocument": ["uri": file, "version": 2], "contentChanges": [["text": shifted]]])
    cur := TextDocumentManager.toLines(shifted)
    callLine := cur.size - 6
    verify(cur[callLine].contains("a := f149(1)"), cur[callLine])
    pos := Position(callLine, cur[callLine].index("f149"))
    params := ["textDocument": ["uri": file], "position": pos.toMap]
    // Warm-up on an unrelated position (JIT/class loading), then measure.
    s.hover(["textDocument": ["uri": file], "position": Position(3, 6).toMap])

    Obj? hover := null
    hoverMs := ms |->| { hover = s.hover(params) }
    verifyNotNull(hover)
    verify(hoverMs < 300, "hover ${hoverMs}ms")
    Obj? def := null
    defMs := ms |->| { def = s.definition(params) }
    verifyNotNull(def)
    verify(defMs < 300, "definition ${defMs}ms")
    res := s.resolver.resolveAt(file, pos)
    verifyEq(res.certainty, Certainty.proven)
    verifyEq(res.targets.first.key, "$pod::Big.f149")
    verifyEq(res.targets.first.range.start.line, cur.findIndex |l| { l.contains("Int f149(") })

    [Str:Obj?][]? lenses := null
    lensMs := ms |->| { lenses = s.codeLensProvider.lenses(s.docManager.parseDocument(file)) }
    verify(lensMs < 1000, "codeLens ${lensMs}ms")
    verifyEq(lenses.size, 300)
    lens := lenses.find |l| { (l["data"] as [Str:Obj?])["key"] == "$pod::Big.f3" }
    [Str:Obj?]? resolved := null
    resolveMs := ms |->| { resolved = s.codeLensProvider.resolve(lens) }
    verify(resolveMs < 500, "codeLens/resolve ${resolveMs}ms")
    // g3, g2 and Extra3 call f3 (all mapped exactly); the dirty buffer differs
    // from the compiled text, so the count is never claimed complete.
    command := resolved["command"] as [Str:Obj?]
    verifyEq(command["title"], "3+ references")
    starts := ((command["arguments"] as List)[2] as List).map |[Str:Obj?] l->Obj?| { ((Str:Obj?)l["range"])["start"] }
    verify(starts.contains(Position(cur.findIndex |l| { l.contains("a := f3(1)") }, 9).toMap))

    provider := CallHierarchyProvider()
    List? items := null
    prepareMs := ms |->| { items = provider.prepare(s.docManager.getDocument(file), pos, s) as List }
    verify(prepareMs < 300, "prepare ${prepareMs}ms")
    List? incoming := null
    incomingMs := ms |->| { incoming = provider.incomingCalls(items.first, s) as List }
    verify(incomingMs < 1000, "incoming ${incomingMs}ms")
    from := incoming.map |[Str:Obj?] e->Str| { ((Str:Obj?)((Str:Obj?)e["from"])["data"])["key"] }
    verifyEq(from.sort, ["$pod::Big.g148", "$pod::Big.g149"])
    outgoingMs := ms |->| { provider.outgoingCalls(["data": ["key": "$pod::Big.g149"]], s) }
    verify(outgoingMs < 1000, "outgoing ${outgoingMs}ms")
    echo("[perf] lines=$lines.size hover=$hoverMs def=$defMs lens=$lensMs resolve=$resolveMs " +
      "prepare=$prepareMs incoming=$incomingMs outgoing=${outgoingMs}ms")
  }

  ** The parser fallback resolves only same-name candidates and at
  ** most fallbackCap of them per request; unrelated calls cost nothing.
  Void testIncomingFallbackIsNamePrefilteredAndCapped()
  {
    pod := ws.podName
    buf := StrBuf().add("class A\n{\n  Void close() {}\n  Void other() {}\n  Void go()\n  {\n")
    600.times { buf.add("    other()\n") }
    buf.add("    close()\n  }\n}\n")
    ws.writePod(pod, ["A.fan": buf.toStr])
    s := session()
    verifyEq(s.semanticSnapshots.size, 0)
    ctx := HierarchyContext(s)
    calls := ctx.callsFor("$pod::A.close", true)
    verifyEq(ctx.attempts, 1)
    verifyEq(calls.size, 1)
    verifyEq(calls.first.enclosingSlotKey, "$pod::A.go")

    ctx = HierarchyContext(s)
    calls = ctx.callsFor("$pod::A.other", true)
    verifyEq(ctx.attempts, HierarchyContext.fallbackCap)
    verifyEq(calls.size, HierarchyContext.fallbackCap)
    verify(calls.all |o| { o.key == "$pod::A.other" })
  }

  ** Cancellation is polled inside the long loops (between fallback attempts
  ** and between files), not only at request entry; the memo scope unwinds.
  Void testCancellationPolledMidLoop()
  {
    pod := ws.podName
    buf := StrBuf().add("class A\n{\n  Void other() {}\n  Void go()\n  {\n")
    600.times { buf.add("    other()\n") }
    buf.add("  }\n}\n")
    sources := ["A.fan": buf.toStr]
    30.times |i| { sources["U${i}.fan"] = "class U$i { Void u() { A().other() } }\n" }
    ws.writePod(pod, sources)
    s := session()
    polls := 0
    check := |->Bool| { polls++; return polls > 10 }
    ctx := HierarchyContext(s)
    verifyErr(ResolverCancelledErr#) { s.resolver.cancellable(check) |->Obj?| { ctx.callsFor("$pod::A.other", true) } }
    verify(ctx.attempts > 0 && ctx.attempts <= 10, "attempts=$ctx.attempts")
    polls = 0
    verifyErr(ResolverCancelledErr#) { s.resolver.cancellable(check) |->Obj?| { s.resolver.references("$pod::A.other") } }
    verifyEq(polls, 11)
    // No stale check survives the scope: the uncancelled request completes.
    full := HierarchyContext(s)
    verifyEq(full.callsFor("$pod::A.other", true).size, HierarchyContext.fallbackCap)
    // Without a snapshot, heuristic slot matches are `unique`, never proven
    // references (existing contract), so the result is a completed audit.
    refs := s.resolver.references("$pod::A.other")
    verifyFalse(refs.complete)
  }

  ** Request memo must never serve text from before an edit made inside the
  ** same scope, and is released when the outermost scope exits.
  Void testBatchScopeObservesInScopeEdits()
  {
    pod := ws.podName
    text := "class A\n{\n  Void close() {}\n  Void go() { close() }\n}\n"
    dir := ws.writePod(pod, ["A.fan": text])
    file := uri(dir + `fan/A.fan`)
    s := session()
    verify(s.ensureFresh([uri(dir + `build.fan`)]))
    s.didOpen(["textDocument": ["uri": file, "languageId": "fantom", "version": 1, "text": text]])
    r := s.resolver
    r.batch |->Obj?|
    {
      verifyEq(r.resolveAt(file, Position(3, 14)).targets.first.key, "$pod::A.close")
      s.didChange(["textDocument": ["uri": file, "version": 2],
        "contentChanges": [["text": "// x\n" + text]]])
      res := r.resolveAt(file, Position(4, 14))
      verifyEq(res.certainty, Certainty.proven)
      verifyEq(res.targets.first.source, "semantic")
      verifyEq(res.occurrenceRange.start.line, 4)
      // The edited line itself is rejected, never matched by spelling.
      s.didChange(["textDocument": ["uri": file, "version": 3],
        "contentChanges": [["text": "// x\n" + text.replace("{ close() }", "{ close()  }")]]])
      verifyNotEq(r.resolveAt(file, Position(4, 14)).targets.first?.source, "semantic")
      return null
    }
    refs := r.references("$pod::A.close", false, true)
    verifyFalse(refs.complete)
  }
}
