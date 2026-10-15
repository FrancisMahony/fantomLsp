using concurrent
using util

**
** Main-thread state ownership, mailbox, generations, diagnostics cache
** merge, single outgoing path, idle polling and document lifecycle.
**
class WorkspaceStateTest : Test
{
  private File[] tempRoots := [,]
  private AtomicBool[] gates := [,]

  override Void teardown()
  {
    gates.each |g| { g.val = true }
    tempRoots.each |d| { try d.delete; catch (Err e) {} }
  }

  //////////////////////////////////////////////////////////////////////////
  // Open-buffer precedence / generations / folders
  //////////////////////////////////////////////////////////////////////////

  Void testOpenBufferBeatsLateIndexBatch()
  {
    root := newRoot
    open := write(root, "src/Open.fan", "class DiskOpen\n{\n  Void diskSlot() {}\n}\n")
    other := write(root, "src/Other.fan", "class DiskOther {}\n")
    server := NoCompileServer()
    server.workspaceManager.addFolder(WorkspaceManager.fileToUri(root))
    key := WorkspaceManager.fileToUri(open)

    // Parse the disk text before the open, as an in-flight index would.
    lateOpen := WorkspaceManager.parseIndexFile(IndexFile(key, open, WorkspaceManager.fileToUri(root)))
    lateOther := WorkspaceManager.parseIndexFile(IndexFile(WorkspaceManager.fileToUri(other), other, WorkspaceManager.fileToUri(root)))
    server.didOpen(openParams(UriKey.toClientUri(key), "class BufferOpen\n{\n  Void bufferSlot() {}\n}\n"))

    server.mailbox.post(IndexBatch(server.indexGeneration, [lateOpen, lateOther], true))
    verifyEq(server.applyBackgroundResults, 1)
    verifyNotNull(server.symbolTable.findType("BufferOpen"))
    verifyNull(server.symbolTable.findType("DiskOpen"))
    verifyNull(server.symbolTable.findByName("diskSlot"))
    verifyNotNull(server.symbolTable.findType("DiskOther"))

    // Same through the real background producer.
    server.startIndex
    verify(server.awaitBackground)
    verifyNotNull(server.symbolTable.findType("BufferOpen"))
    verifyNull(server.symbolTable.findType("DiskOpen"))
    verifyNotNull(server.symbolTable.findType("DiskOther"))
  }

  Void testSupersededGenerationBatchesAreDropped()
  {
    root := newRoot
    a := write(root, "A.fan", "class GenOld {}\n")
    b := write(root, "B.fan", "class GenNew {}\n")
    server := NoCompileServer()
    folder := WorkspaceManager.fileToUri(root)
    server.workspaceManager.addFolder(folder)
    oldGen := server.indexGeneration
    oldEntry := WorkspaceManager.parseIndexFile(IndexFile(WorkspaceManager.fileToUri(a), a, folder))
    newEntry := WorkspaceManager.parseIndexFile(IndexFile(WorkspaceManager.fileToUri(b), b, folder))

    server.workspaceManager.removeFolder(folder)
    server.indexWorkspaceNow             // supersedes generation 0; indexes nothing
    server.workspaceManager.addFolder(folder)
    verify(server.indexGeneration > oldGen)

    server.mailbox.post(IndexBatch(oldGen, [oldEntry], true))
    server.mailbox.post(IndexBatch(server.indexGeneration, [newEntry], true))
    verifyEq(server.applyBackgroundResults, 1)
    verifyNull(server.symbolTable.findType("GenOld"))
    verifyNotNull(server.symbolTable.findType("GenNew"))
    verify(server.indexComplete)
  }

  Void testFolderRemovalDropsEntriesAndLateBatches()
  {
    rootA := newRoot
    rootB := newRoot
    fileA := write(rootA, "pod/fan/InA.fan", "class InFolderA {}\n")
    write(rootA, "pod/build.fan", "class Build {}\n")
    write(rootB, "InB.fan", "class InFolderB {}\n")
    folderA := WorkspaceManager.fileToUri(rootA)
    folderB := WorkspaceManager.fileToUri(rootB)
    server := NoCompileServer()
    server.workspaceManager.addFolder(folderA)
    server.workspaceManager.addFolder(folderB)
    server.indexWorkspaceNow
    verifyNotNull(server.symbolTable.findType("InFolderA"))
    verifyNotNull(server.symbolTable.findType("InFolderB"))
    lateA := WorkspaceManager.parseIndexFile(IndexFile(WorkspaceManager.fileToUri(fileA), fileA, folderA))

    server.didChangeWorkspaceFolders(["event": [
      "added": [,],
      "removed": [["uri": UriKey.toClientUri(folderA), "name": "a"]],
    ]])
    verifyNull(server.symbolTable.findType("InFolderA"))
    verifyEq(server.referenceIndex.findReferences("InFolderA").size, 0)
    verifyNotNull(server.symbolTable.findType("InFolderB"))

    // A batch for the removed folder that arrives afterwards is ignored.
    server.mailbox.post(IndexBatch(server.indexGeneration, [lateA], false))
    verify(server.awaitBackground)
    verifyNull(server.symbolTable.findType("InFolderA"))
    verifyNotNull(server.symbolTable.findType("InFolderB"))
    verify(server.workspaceManager.getFolders.contains(folderB))
  }

  //////////////////////////////////////////////////////////////////////////
  // Compiler diagnostics: staleness, cache merge, single publish
  //////////////////////////////////////////////////////////////////////////

  Void testStaleCompileResultIsNotPublished()
  {
    server := NoCompileServer()
    key := "file:///stale/Stale.fan"
    server.didOpen(openParams(key, lines(8)))
    s1 := server.docVersions[key] as Int
    server.didChange(changeParams(key, 2, lines(8) + "// edit\n"))
    s2 := server.docVersions[key] as Int
    verifyNotEq(s1, s2)
    server.drainOutgoing

    server.mailbox.post(compileResult(key, s1, 3, "stale compile error"))
    server.applyBackgroundResults
    verifyEq(publishes(server.drainOutgoing).size, 0)
    verifyEq(server.diagnosticsProvider.compilerDiagnostics(key).size, 0)

    // The stale result is not cached either: the next publish omits it.
    note := server.didChange(changeParams(key, 3, lines(8) + "// edit 2\n"))
    verifyFalse(messages(note).contains("stale compile error"))

    s3 := server.docVersions[key] as Int
    server.mailbox.post(compileResult(key, s3, 3, "fresh compile error"))
    server.applyBackgroundResults
    out := publishes(server.drainOutgoing)
    verifyEq(out.size, 1)
    verify(messages(out.first).contains("fresh compile error"))

    // A result for a document that was closed meanwhile is dropped as well.
    server.didClose(["textDocument": ["uri": key]])
    server.mailbox.post(compileResult(key, s3, 3, "closed compile error"))
    server.applyBackgroundResults
    verifyEq(publishes(server.drainOutgoing).size, 0)
  }

  Void testReopenWithReusedVersionRejectsOldCompile()
  {
    server := NoCompileServer()
    key := "file:///stale/Reopen.fan"
    server.didOpen(openParams(key, lines(4)))
    old := server.docVersions[key] as Int
    server.didClose(["textDocument": ["uri": key]])
    verifyNull(server.docVersions[key])
    server.didOpen(openParams(key, lines(5)))   // same client version 1
    server.drainOutgoing
    server.mailbox.post(compileResult(key, old, 1, "from previous session"))
    server.applyBackgroundResults
    verifyEq(publishes(server.drainOutgoing).size, 0)
  }

  Void testDidChangeKeepsMergedCompilerDiagnostics()
  {
    server := NoCompileServer()
    key := "file:///merge/Merge.fan"
    src := "class Merge\n{\n  Void a()\n  {\n    x := 1\n    y := bogus\n  }\n}\n"
    server.didOpen(openParams(key, src))
    server.mailbox.post(compileResult(key, server.docVersions[key], 5, "Unknown variable 'bogus'"))
    server.applyBackgroundResults
    published := publishes(server.drainOutgoing)
    verifyEq(published.size, 1)
    verify(messages(published.first).contains("Unknown variable 'bogus'"))

    // Insert a line above the error: parser diagnostics are recomputed and the
    // compiler diagnostic survives, shifted by one line.
    edited := "// header\n" + src
    note := server.didChange(changeParams(key, 2, edited))
    verify(messages(note).contains("Unknown variable 'bogus'"))
    verify(messages(note).contains("Unused local 'x'"))
    verifyEq(compilerLines(note), [6])

    // Edit after the error line: unchanged.
    edited2 := edited.replace("  }\n}\n", "  }\n  Void b() {}\n}\n")
    note = server.didChange(changeParams(key, 3, edited2))
    verifyEq(compilerLines(note), [6])

    // didSave without changes keeps the merged diagnostics as well.
    saved := server.didSave(["textDocument": ["uri": key], "text": edited2])
    verifyEq(compilerLines(saved), [6])

    // Editing the error line drops it.
    note = server.didChange(changeParams(key, 4, edited2.replace("bogus", "bogus2")))
    verifyEq(compilerLines(note), Int[,])
    verifyEq(server.diagnosticsProvider.compilerDiagnostics(key).size, 0)
  }

  Void testRealCompileDiagnosticsSurviveDidChange()
  {
    root := newRoot
    write(root, "build.fan", "using build\nclass Build : BuildPod\n{\n  new make()\n  {\n    podName = \"t02probe\"\n    summary = \"t02\"\n    depends = [\"sys 1.0\"]\n    srcDirs = [`fan/`]\n  }\n}\n")
    src := "class Probe\n{\n  Void m()\n  {\n    echo(undefinedThing)\n  }\n}\n"
    file := write(root, "fan/Probe.fan", src)
    key := WorkspaceManager.fileToUri(file)
    server := FantomLanguageServer()
    server.didOpen(openParams(UriKey.toClientUri(key), src))
    verify(server.awaitBackground(120sec))
    out := publishes(server.drainOutgoing)
    verifyEq(out.size, 1)
    verifyEq(compilerLines(out.first), [4])

    note := server.didChange(changeParams(key, 2, "// top\n" + src))
    verifyEq(compilerLines(note), [5])
    verify(server.awaitBackground(120sec))
  }

  //////////////////////////////////////////////////////////////////////////
  // Main loop: single outgoing path and idle polling
  //////////////////////////////////////////////////////////////////////////

  Void testEachMessageWrittenExactlyOnce()
  {
    key := "file:///once/Once.fan"
    input := frames([
      request(1, "initialize", ["capabilities": [Str:Obj?][:]]),
      notification("initialized", [Str:Obj?][:]),
      notification("textDocument/didOpen", openParams(key, lines(3))),
      notification("textDocument/didChange", changeParams(key, 2, lines(4))),
      request(2, "textDocument/hover", ["textDocument": ["uri": key], "position": ["line": 0, "character": 7]]),
      request(3, "textDocument/codeLens", ["textDocument": ["uri": key]]),
    ])
    out := Buf()
    pool := ActorPool()
    server := NoCompileServer()
    server.stdioWriter = StdioWriteActor(pool, out.out)
    loop := LspMainLoop(server, input)
    loop.run
    verify(server.awaitBackground)

    // A background compile result is published once, then never again.
    server.mailbox.post(compileResult(key, server.docVersions[key], 0, "bg error"))
    server.applyBackgroundResults
    server.applyBackgroundResults
    server.stdioWriter.send(null).get(5sec)
    msgs := parseFrames(out.flip.readAllStr)

    verifyEq(msgs.findAll |m| { m["id"] == 1 }.size, 1)
    verifyEq(msgs.findAll |m| { m["id"] == 2 }.size, 1)
    verifyEq(msgs.findAll |m| { m["id"] == 3 }.size, 1)
    pubs := msgs.findAll |m| { m["method"] == "textDocument/publishDiagnostics" }
    verifyEq(pubs.size, 3)
    verifyEq(pubs.findAll |m| { messages(m).contains("bg error") }.size, 1)
    verifyEq(msgs.size, 6)
    verifyEq(server.drainOutgoing.size, 0)
    verify(msgs.all |m| { m["error"] == null })
  }

  Void testBackgroundResultAppliedWithoutClientMessages()
  {
    gate := AtomicBool(false)
    gates.add(gate)
    root := newRoot
    write(root, "Idle.fan", "class IdleIndexed {}\n")
    server := NoCompileServer()
    loop := LspMainLoop(server, BlockingInStream(gate))
    loop.handle(request(1, "initialize", ["rootUri": UriKey.toClientUri(WorkspaceManager.fileToUri(root)), "capabilities": [Str:Obj?][:]]))
    loop.handle(notification("initialized", [Str:Obj?][:]))
    key := "file:///idle/Doc.fan"
    loop.handle(notification("textDocument/didOpen", openParams(key, lines(3))))
    server.drainOutgoing
    handled := loop.messagesHandled

    // Index batches arrive through idle ticks only.
    deadline := Duration.now + 30sec
    while (!server.indexComplete && Duration.now < deadline) loop.tick
    verify(server.indexComplete)
    verifyNotNull(server.symbolTable.findType("IdleIndexed"))

    // A compile result posted now is published by the next idle tick.
    loop.tick   // settle any in-progress wait
    server.mailbox.post(compileResult(key, server.docVersions[key], 1, "idle error"))
    t0 := Duration.now
    Obj[] pubs := [,]
    while (pubs.isEmpty && Duration.now - t0 < 2sec)
    {
      loop.tick
      pubs = publishes(server.drainOutgoing)
    }
    elapsed := Duration.now - t0
    verifyEq(pubs.size, 1)
    verify(messages(pubs.first).contains("idle error"))
    verify(elapsed < 300ms, "applied after $elapsed.toMillis ms")
    verifyEq(loop.messagesHandled, handled)
    verify(loop.idleTicks > 0)
    gate.val = true
  }

  //////////////////////////////////////////////////////////////////////////
  // Lifecycle
  //////////////////////////////////////////////////////////////////////////

  Void testDidCloseRestoresDiskEntries()
  {
    root := newRoot
    file := write(root, "Closed.fan", "class DiskOnly\n{\n  Void diskSlot() {}\n}\n")
    other := write(root, "Other.fan", "class OtherOpen {}\n")
    server := NoCompileServer()
    server.workspaceManager.addFolder(WorkspaceManager.fileToUri(root))
    server.indexWorkspaceNow
    key := WorkspaceManager.fileToUri(file)
    server.didOpen(openParams(WorkspaceManager.fileToUri(other), other.readAllStr))
    server.didOpen(openParams(UriKey.toClientUri(key), "class BufferOnly {}\n"))
    verifyNull(server.symbolTable.findType("DiskOnly"))
    server.mailbox.post(compileResult(key, server.docVersions[key], 0, "buffer error"))
    server.applyBackgroundResults
    requestsBefore := server.scheduled.size

    note := server.didClose(["textDocument": ["uri": UriKey.toClientUri(key)]])
    verifyEq((note["params"] as Map)["diagnostics"], Obj?[,])
    verifyNotNull(server.symbolTable.findType("DiskOnly"))
    verifyNotNull(server.symbolTable.findByName("diskSlot"))
    verifyNull(server.symbolTable.findType("BufferOnly"))
    verifyNull(server.docVersions[key])
    verifyEq(server.diagnosticsProvider.compilerDiagnostics(key).size, 0)
    // The buffer differed from disk: the other open pod is recompiled.
    verifyEq(server.scheduled.size, requestsBefore + 1)

    // Closing a clean buffer re-reads disk without requesting a compile.
    server.didOpen(openParams(UriKey.toClientUri(key), file.readAllStr))
    before := server.scheduled.size
    server.didClose(["textDocument": ["uri": key]])
    verifyEq(server.scheduled.size, before)
    verifyNotNull(server.symbolTable.findType("DiskOnly"))
  }

  Void testDidCloseNonSourceDocumentDropsBufferEntries()
  {
    root := newRoot
    file := write(root, "notes.txt", "class OnDiskTxt {}\n")
    server := NoCompileServer()
    server.workspaceManager.addFolder(WorkspaceManager.fileToUri(root))
    key := WorkspaceManager.fileToUri(file)
    server.didOpen(openParams(UriKey.toClientUri(key), "class TxtBuffer\n{\n  Void txtSlot() {}\n}\n"))
    verifyNotNull(server.symbolTable.findType("TxtBuffer"))

    server.didClose(["textDocument": ["uri": UriKey.toClientUri(key)]])
    verifyNull(server.symbolTable.findType("TxtBuffer"))
    verifyNull(server.symbolTable.findByName("txtSlot"))
    verifyNull(server.symbolTable.findType("OnDiskTxt"))
    verify(server.symbolTable.allEntries.all |e| { e.uri != key })
    verifyEq(server.referenceIndex.findReferencesInFile(key, "Void").size, 0)
  }

  Void testCloseAfterLastFolderRemovedDoesNotResurrectDisk()
  {
    root := newRoot
    file := write(root, "Removed.fan", "class RemovedDisk\n{\n  Void diskSlot() {}\n}\n")
    folder := WorkspaceManager.fileToUri(root)
    key := WorkspaceManager.fileToUri(file)
    server := NoCompileServer()
    server.workspaceManager.addFolder(folder)
    server.indexWorkspaceNow
    server.didOpen(openParams(UriKey.toClientUri(key), "class RemovedBuffer {}\n"))

    // Remove the only folder: the session now has no folders at all.
    server.didChangeWorkspaceFolders(["event": ["added": [,], "removed": [["uri": UriKey.toClientUri(folder), "name": "r"]]]])
    verify(server.workspaceManager.getFolders.isEmpty)
    verifyNotNull(server.symbolTable.findType("RemovedBuffer"))   // still open

    server.didClose(["textDocument": ["uri": UriKey.toClientUri(key)]])
    verifyNull(server.symbolTable.findType("RemovedDisk"))
    verifyNull(server.symbolTable.findType("RemovedBuffer"))
    verifyEq(server.symbolTable.allEntries.size, 0)

    // Watched-file events for the removed folder do not resurrect it either.
    server.didChangeWatchedFiles(["changes": [["uri": key, "type": 2]]])
    verifyNull(server.symbolTable.findType("RemovedDisk"))
    verify(server.awaitBackground)
    verifyEq(server.symbolTable.allEntries.size, 0)
  }

  Void testStandaloneSessionCloseRestoresDisk()
  {
    // Folder-less sessions keep standalone semantics: close re-reads disk.
    root := newRoot
    file := write(root, "Loose.fan", "class LooseDisk {}\n")
    key := WorkspaceManager.fileToUri(file)
    server := NoCompileServer()
    server.didOpen(openParams(key, "class LooseBuffer {}\n"))
    server.didClose(["textDocument": ["uri": key]])
    verifyNotNull(server.symbolTable.findType("LooseDisk"))
    verifyNull(server.symbolTable.findType("LooseBuffer"))
  }

  Void testWatchedDeleteIsNotResurrectedByLateBatch()
  {
    root := newRoot
    file := write(root, "Gone.fan", "class GoneType {}\n")
    open := "file:///watched/Open.fan"
    folder := WorkspaceManager.fileToUri(root)
    key := WorkspaceManager.fileToUri(file)
    server := NoCompileServer()
    server.workspaceManager.addFolder(folder)
    late := WorkspaceManager.parseIndexFile(IndexFile(key, file, folder))
    server.indexWorkspaceNow
    server.didOpen(openParams(open, lines(2)))
    before := server.scheduled.size
    file.delete
    server.didChangeWatchedFiles(["changes": [["uri": UriKey.toClientUri(key), "type": 3]]])
    verifyNull(server.symbolTable.findType("GoneType"))
    verifyEq(server.scheduled.size, before + 1)

    server.mailbox.post(IndexBatch(server.indexGeneration, [late], true))
    server.applyBackgroundResults
    verifyNull(server.symbolTable.findType("GoneType"))
  }

  //////////////////////////////////////////////////////////////////////////
  // Structural invariants
  //////////////////////////////////////////////////////////////////////////

  Void testBackgroundActorsHoldOnlyConstState()
  {
    [IndexActor#, SemanticCompileActor#, Mailbox#, StdinReaderActor#].each |t|
    {
      verify(t.isConst, t.qname)
      t.fields.each |f|
      {
        if (f.isStatic || f.parent == Actor#) return
        verify(f.type.isConst || f.type.toNonNullable == Unsafe#, "$f.qname : $f.type")
        verifyFalse(f.type.fits(FantomLanguageServer#), f.qname)
      }
    }
    req := CompileRequest(1, "k", Str:Str["k": "text"], Str:Int["k": 1])
    verify(req.isImmutable)
    verify(req.texts.isImmutable)
    verify(CompileResult(1, Str:Diagnostic[][:], Str:Int[:]).isImmutable)
    verify(IndexRequest(1, ["a"], ["b"], 0).isImmutable)
  }

  Void testCompileRequestIsAnImmutableSnapshot()
  {
    server := NoCompileServer()
    key := "file:///snap/Snap.fan"
    other := "file:///snap/A.fan"
    server.didOpen(openParams(other, "class A {}\n"))
    server.didOpen(openParams(key, "class Snap {}\n"))
    req := server.buildCompileRequest(UriKey.toClientUri(key))
    verify(req.isImmutable)
    verifyEq(req.triggerKey, key)
    verifyEq(req.texts.keys, [key, other])   // trigger first
    verifyEq(req.texts[key], "class Snap {}\n")
    verifyEq(req.stamps[key], server.docVersions[key])
    server.didChange(changeParams(key, 2, "class Snap2 {}\n"))
    verifyEq(req.texts[key], "class Snap {}\n")
    verifyNotEq(req.stamps[key], server.docVersions[key])
  }

  Void testParserDiagnosticsArePure()
  {
    doc := DocumentState("file:///p.fan", 1, "class P\n{\n  Void m()\n  {\n    unused := 1\n  }\n}\n")
    result := RecoveringParser().parse(doc.uri, doc.text)
    diags := DiagnosticsProvider().computeParserDiagnosticsFor(doc, result)
    verify(diags.any |d| { d.message == "Unused local 'unused'" })
  }

  Void testMailboxPreservesEveryMessageAcrossProducers()
  {
    mailbox := Mailbox(ActorPool())
    pool := ActorPool()
    futures := Future[,]
    4.times |p|
    {
      futures.add(Actor(pool) |Obj? n->Obj?|
      {
        250.times |i| { mailbox.post("$n-$i") }
        return null
      }.send(p))
    }
    got := Obj[,]
    deadline := Duration.now + 10sec
    while (got.size < 1000 && Duration.now < deadline) { got.addAll(mailbox.drain); Actor.sleep(1ms) }
    futures.each |f| { f.get(5sec) }
    got.addAll(mailbox.drain)
    verifyEq(got.size, 1000)
    verifyEq(got.unique.size, 1000)
    verifyFalse(mailbox.hasPending)
    4.times |p|
    {
      seq := got.findAll |Str s->Bool| { s.startsWith("$p-") }.map |Str s->Int| { s[s.index("-") + 1..-1].toInt }
      verifyEq(seq, (0..<250).toList)
    }
  }

  //////////////////////////////////////////////////////////////////////////
  // Helpers
  //////////////////////////////////////////////////////////////////////////

  private File newRoot()
  {
    dir := Env.cur.tempDir + `fantomLsp-test-${Uuid().toStr}/`
    dir.create
    tempRoots.add(dir)
    return dir
  }

  private File write(File root, Str rel, Str text)
  {
    f := root + rel.toUri
    f.parent.create
    f.out.print(text).close
    return f
  }

  internal static Str lines(Int n)
  {
    buf := StrBuf()
    buf.add("class Gen$n\n{\n")
    n.times |i| { buf.add("  Void m$i() {}\n") }
    buf.add("}\n")
    return buf.toStr
  }

  internal static [Str:Obj?] openParams(Str uri, Str text)
  {
    ["textDocument": ["uri": uri, "languageId": "fantom", "version": 1, "text": text]]
  }

  internal static [Str:Obj?] changeParams(Str uri, Int version, Str text)
  {
    ["textDocument": ["uri": uri, "version": version], "contentChanges": [["text": text]]]
  }

  internal static [Str:Obj?] request(Int id, Str method, [Str:Obj?] params)
  {
    ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
  }

  internal static [Str:Obj?] notification(Str method, [Str:Obj?] params)
  {
    ["jsonrpc": "2.0", "method": method, "params": params]
  }

  private static CompileResult compileResult(Str key, Obj? stamp, Int line, Str msg)
  {
    d := Diagnostic(LspRange(Position(line, 4), Position(line, 9)), Diagnostic.error, msg, "fantomCompiler")
    return CompileResult(99, [key: [d]], [key: (Int)stamp])
  }

  private static [Str:Obj?][] publishes([Str:Obj?][] msgs)
  {
    msgs.findAll |m| { m["method"] == "textDocument/publishDiagnostics" }
  }

  private static Str[] messages([Str:Obj?]? note)
  {
    params := note?.get("params") as [Str:Obj?]
    List diags := params?.get("diagnostics") as List ?: [,]
    return diags.map |Obj? d->Str| { ((Map)d)["message"] }
  }

  private static Int[] compilerLines([Str:Obj?]? note)
  {
    params := note?.get("params") as [Str:Obj?]
    List diags := params?.get("diagnostics") as List ?: [,]
    result := Int[,]
    diags.each |Obj? d|
    {
      m := d as Map
      if (m["source"] != "fantomCompiler") return
      start := (m["range"] as Map)["start"] as Map
      result.add(((Num)start["line"]).toInt)
    }
    return result
  }

  internal static InStream frames([Str:Obj?][] msgs)
  {
    buf := Buf()
    msgs.each |m|
    {
      body := JsonRpc.encode(m)
      bytes := Buf().print(body)
      buf.print("Content-Length: ${bytes.size}\r\n\r\n").print(body)
    }
    return buf.flip.in
  }

  internal static [Str:Obj?][] parseFrames(Str raw)
  {
    result := [Str:Obj?][,]
    in := Buf().print(raw).flip.in
    while (true)
    {
      line := in.readLine
      if (line == null) break
      if (!line.startsWith("Content-Length:")) continue
      len := line["Content-Length:".size..-1].trim.toInt
      in.readLine   // blank separator
      body := in.readBufFully(null, len).readAllStr
      result.add(JsonInStream(body.in).readJson)
    }
    return result
  }
}

** Records compile requests without starting background compiles.
internal class NoCompileServer : FantomLanguageServer
{
  Str[] scheduled := [,]
  override Void scheduleCompilerDiagnostics(Str triggerUri) { scheduled.add(triggerUri) }
}

** stdin that delivers nothing until the gate opens, then EOF.
internal class BlockingInStream : InStream
{
  private const AtomicBool gate
  new make(AtomicBool gate) : super(null) { this.gate = gate }
  override Int? read() { while (!gate.val) Actor.sleep(5ms); return null }
  override Int? readBuf(Buf buf, Int n) { read; return null }
  override This unread(Int b) { this }
}
