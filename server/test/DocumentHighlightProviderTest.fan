class DocumentHighlightProviderTest : Test
{
  private T09Fixture f := T09Fixture()
  override Void teardown() { f.cleanup }

  Void testLocalHighlightAndLinkedEditingOnlyM1()
  {
    f.source(T09Fixture.locals)
    hits := DocumentHighlightProvider().highlight(f.doc, f.at("x", 5), f.server)
    verifyEq(lines(hits), [4, 5])
    linked := LinkedEditingRangeProvider().ranges(f.doc, f.at("x", 5), f.server)
    ranges := linked["ranges"] as [Str:Obj?][]
    verifyEq(ranges.map |r->Int| { (Int)((Str:Obj?)r["start"])["line"] }.sort, [4, 5])
  }

  Void testSameNameSlotsCommentsStringsAndLocalsExcluded()
  {
    f.source("class A\n{\n  Void close() {}\n  Void go()\n  {\n    close()\n    Int close := 1\n    echo(close)\n    echo(\"close\") // close\n  }\n}\nclass Other { Void close() {} }\n")
    hits := DocumentHighlightProvider().highlight(f.doc, f.at("close", 2), f.server)
    verifyEq(lines(hits), [2, 5])
    linked := LinkedEditingRangeProvider().ranges(f.doc, f.at("close", 2), f.server)
    ranges := linked["ranges"] as [Str:Obj?][]
    verifyEq(ranges.map |r->Int| { (Int)((Str:Obj?)r["start"])["line"] }.sort, [2, 5])
  }

  Void testBufferLocalUsesTargetFileNotOpaqueKey()
  {
    f.source(T09Fixture.locals)
    f.change(f.doc.text.replace("Int x := 1", "Int y := 3").replace("return x\n  }\n  Int m2", "return y\n  }\n  Int m2"))
    verify(f.server.resolver.resolveAt(f.doc.uri, f.at("y", 5)).targets.first.key.contains("#buffer:"))
    verifyEq(lines(DocumentHighlightProvider().highlight(f.doc, f.at("y", 5), f.server)), [4, 5])
  }

  Void testEmptyAndAmbiguousReturnNoRanges()
  {
    f.source("class A\n{\n  Void close() {}\n  Void go(Obj obj) { obj->close() }\n}\n")
    provider := DocumentHighlightProvider()
    verify(provider.highlight(f.doc, Position(1, 0), f.server).isEmpty)
    verify(provider.highlight(f.doc, f.at("close", 3), f.server).isEmpty)
    verifyNull(LinkedEditingRangeProvider().ranges(f.doc, f.at("close", 3), f.server))
  }

  ** The file-scoped audit returns exactly the same-file subset of the
  ** whole-workspace references (slot, installed sys type, local, dyn),
  ** for fresh and edited buffers, and empty for non-candidate files.
  Void testFileScopedReferencesEqualWorkspaceFilter()
  {
    f.source("class A\n{\n  Void close() {}\n  Str go(Str s)\n  {\n    close()\n    Int x := 1\n    echo(x)\n    t := s.trim\n    return s + \"close\"\n  }\n}\nclass B { Void run() { A().close; Str? q := null } }\n")
    file := UriKey.canonical(f.doc.uri)
    r := f.server.resolver
    sameFile := |Str key, Bool decl->Str[]|
    {
      r.references(key, decl, false).occurrences.findAll |o| { o.fileKey == file }.map |o->Str| { "${o.range.start.line}:${o.range.start.character}-${o.range.end.character}" }.sort
    }
    scoped := |Str key, Bool decl->Str[]|
    {
      r.references(key, decl, false, file).occurrences.map |o->Str| { "${o.range.start.line}:${o.range.start.character}-${o.range.end.character}" }.sort
    }
    keys := ["$f.pod::A.close", "$f.pod::A", "sys::Str", "sys::Str.trim", "sys::Obj.echo"]
    keys.add(r.resolveAt(file, f.at("x", 7)).targets.first.key)
    check := |->|
    {
      keys.each |k| { [true, false].each |d| { verifyEq(scoped(k, d), sameFile(k, d), "$k decl=$d") } }
    }
    check()
    verifyEq(scoped("$f.pod::A.close", true).size, 3)
    verify(!scoped("sys::Str", true).isEmpty)
    // Edited (dirty, line-shifted) buffer: mapped and heuristic paths agree too.
    f.change("// edit\n" + f.doc.text.replace("echo(x)", "echo(x + 1)"))
    keys[-1] = r.resolveAt(file, f.at("x", 8)).targets.first.key
    check()
    // A file outside every candidate pod yields nothing (no workspace walk).
    other := f.ws.root + `elsewhere/X.fan`
    other.out.print("class X { Void close() {} }\n").close
    verify(r.references("$f.pod::A.close", true, false, WorkspaceManager.fileToUri(other)).occurrences.isEmpty)
  }

  Void testFileScopedReferencesExcludeNondependentPod()
  {
    alpha := f.ws.podName("alpha"); unrelated := f.ws.podName("unrelated")
    text := "class A { Void close() {} Void go() { close() } }\n"
    dir := f.ws.writePod(alpha, ["A.fan": text])
    other := f.ws.writePod(unrelated, ["U.fan": "class U { Void close() {} Void go() { close() } }\n"]) + `fan/U.fan`
    f.start(dir + `fan/A.fan`, text)
    file := T09Fixture.key(other)
    verifyEq(f.server.podRegistry.podForFile(file).podName, unrelated)
    [true, false].each |decl|
    {
      verifyScopedMatchesWorkspace("$alpha::A.close", file, decl, 0)
      // The same file is a candidate for its own identically spelled slot.
      verifyScopedMatchesWorkspace("$unrelated::U.close", file, decl, decl ? 2 : 1)
    }
  }

  Void testFileScopedReferencesAcrossDuplicateBuilds()
  {
    pod := f.ws.podName("duplicate")
    text := "class A { Void close() {} Void go() { close() } }\n"
    first := f.ws.writePod(pod, ["A.fan": text])
    second := f.ws.writePod(f.ws.podName("copy"), ["A.fan": text])
    build := second + `build.fan`
    buildText := build.readAllStr.replace(f.ws.podName("copy"), pod)
    build.out.print(buildText).close
    f.start(first + `fan/A.fan`, text)
    verifyEq(f.server.podRegistry.byName(pod).size, 2)
    [first, second].each |dir|
    {
      file := T09Fixture.key(dir + `fan/A.fan`)
      [true, false].each |decl|
      {
        verifyScopedMatchesWorkspace("$pod::A.close", file, decl, decl ? 2 : 1)
        scoped := f.server.resolver.references("$pod::A.close", decl, false, file)
        verifyFalse(scoped.complete, "duplicate-build public keys must remain unsafe")
        verify(scoped.uncoveredPods.contains(pod))
      }
    }
  }

  Void testFileScopedClosedSourceVsOutsideSrcDir()
  {
    pod := f.ws.podName
    text := "class A { Void close() {} }\n"
    use := "class B { Void go() { A().close() } }\n"
    dir := f.ws.writePod(pod, ["A.fan": text, "B.fan": use])
    outside := dir + `fanExtra/B.fan`
    outside.parent.create
    outside.out.print(use).close
    f.start(dir + `fan/A.fan`, text)
    insideKey := T09Fixture.key(dir + `fan/B.fan`)
    outsideKey := T09Fixture.key(outside)
    verifyNull(f.server.docManager.getDocument(insideKey))
    verifyNull(f.server.docManager.getDocument(outsideKey))
    owner := f.server.podRegistry.podForFile(insideKey)
    verifyEq(f.server.podRegistry.podForFile(outsideKey).buildKey, owner.buildKey)
    verify(f.server.podRegistry.filesOf(owner).contains(insideKey))
    verifyFalse(f.server.podRegistry.filesOf(owner).contains(outsideKey))
    [true, false].each |decl|
    {
      verifyScopedMatchesWorkspace("$pod::A.close", insideKey, decl, 1)
      verifyScopedMatchesWorkspace("$pod::A.close", outsideKey, decl, 0)
    }
  }

  private Void verifyScopedMatchesWorkspace(Str key, Str file, Bool decl, Int count)
  {
    r := f.server.resolver
    encode := |Occurrence o->Str| { "${o.fileKey}:${o.range.start.line}:${o.range.start.character}-${o.range.end.line}:${o.range.end.character}" }
    expected := r.references(key, decl, false).occurrences.findAll |o| { o.fileKey == file }.map(encode).sort
    actual := r.references(key, decl, false, file).occurrences.map(encode).sort
    verifyEq(actual, expected, "$key file=$file decl=$decl")
    verifyEq(actual.size, count, "$key file=$file decl=$decl")
  }

  ** Highlight goes through the production dispatcher with the actual
  ** request ID; a pending cancel yields a null result, not an error.
  Void testHighlightAndLinkedEditingCancelWithActualId()
  {
    f.source(T09Fixture.locals)
    d := LspDispatcher(f.server)
    params := ["textDocument": ["uri": f.doc.originalUri], "position": f.at("x", 5).toMap]
    ok := d.dispatch(["jsonrpc": "2.0", "id": 41, "method": "textDocument/documentHighlight", "params": params])
    verifyEq((ok["result"] as List).size, 2)
    ["textDocument/documentHighlight", "textDocument/linkedEditingRange", "textDocument/hover",
     "textDocument/definition", "textDocument/prepareRename"].each |m, i|
    {
      id := "c$i"
      f.server.cancelRequest(id)
      resp := d.dispatch(["jsonrpc": "2.0", "id": id, "method": m, "params": params])
      verifyNull(resp["error"], m)
      verifyNull(resp["result"], m)
    }
    verify(f.server.cancelTokens.isEmpty)
  }

  private static Int[] lines([Str:Obj?][] hits)
  {
    return hits.map |h->Int|
    {
      r := h["range"] as [Str:Obj?]
      return (Int)((Str:Obj?)r["start"])["line"]
    }.sort
  }
}
