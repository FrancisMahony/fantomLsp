using compiler
using concurrent

class SemanticCompileTest : Test
{
  private TestWorkspace ws := TestWorkspace()
  private FantomLanguageServer? server

  override Void teardown()
  {
    if (server != null) server.awaitBackground
    ws.cleanup
  }

  private FantomLanguageServer session(File dir, Bool background := false, StdioWriteActor? writer := null)
  {
    s := FantomLanguageServer()
    server = s
    s.stdioWriter = writer
    s.initialize(["rootUri": WorkspaceManager.fileToUri(dir),
      "initializationOptions": ["semanticIndex": ["backgroundCompile": background]],
      "capabilities": ["workspace": ["codeLens": ["refreshSupport": true]]]])
    s.indexWorkspaceNow
    return s
  }

  private static Str key(File file) { WorkspaceManager.fileToUri(file) }
  private static Void open(FantomLanguageServer s, File file, Str text)
  {
    s.didOpen(["textDocument": ["uri": key(file), "languageId": "fantom", "version": 1, "text": text]])
  }
  private static Void edit(FantomLanguageServer s, File file, Str text)
  {
    s.didChange(["textDocument": ["uri": key(file), "version": 2], "contentChanges": [["text": text]]])
  }

  ** Open builds also publish diagnostics on the same writer. Count only the
  ** refresh requests, draining complete JSON-RPC frames rather than substrings.
  private static [Str:Obj?][] takeRefreshes(StdioWriteActor writer, Buf buf)
  {
    writer.send(null).get
    buf.flip
    rpc := JsonRpc(buf.in, Buf().out)
    refreshes := [Str:Obj?][,]
    while (true)
    {
      msg := rpc.readMessage
      if (msg == null) break
      if (msg["method"] == "workspace/codeLens/refresh") refreshes.add(msg)
    }
    buf.clear
    return refreshes
  }

  Void testOpenRealPodAndEveryOverlayIncludingTest()
  {
    name := ws.podName
    dir := ws.writePod(name, ["A.fan": "class A { Int answer() { 1 } }",
      "B.fan": "class B { Int go() { A().answer } }"])
    build := dir + `build.fan`
    // Add the test source directory using the actual literal syntax.
    build.out.print("using build\nclass Build : BuildPod\n{\n new make()\n {\n" +
      " podName = ${name.toCode}\n srcDirs = [`fan/`, `test/`]\n depends = [\"sys 1.0\"]\n }\n}\n").close
    testFile := dir + `test/Checks.fan`
    testFile.out.print("class Checks { Int go() { A().answer } }").close
    s := session(dir)
    a := dir + `fan/A.fan`; b := dir + `fan/B.fan`
    open(s, a, a.readAllStr); open(s, b, b.readAllStr); open(s, testFile, testFile.readAllStr)
    verify(s.awaitBackground)
    snap := s.semanticSnapshots[key(build)]
    verifyNotNull(snap)
    verifyEq(snap.podName, name)
    verify(snap.decls.containsKey("$name::Checks.go"))
    aText := "class A { Int answer() { \"wrong\" } Int newer() { 2 } }"
    bText := "class B { Int go() { A().newer } }"
    edit(s, a, aText); edit(s, b, bText)
    s.didSave(["textDocument": ["uri": key(a)]])
    verify(s.awaitBackground)
    snap = s.semanticSnapshots[key(build)]
    verifyEq(snap.openText[key(a)], aText)
    verifyEq(snap.openText[key(b)], bText)
    verifyEq(snap.fileHash[key(b)], bText.toBuf.toDigest("SHA-1").toHex)
    verify(snap.occByKey.containsKey("$name::A.newer"))
    verify(s.diagnosticsProvider.compilerDiagnostics(key(a)).any |d| { d.message.contains("return") })
    verify(s.diagnosticsProvider.compilerDiagnostics(key(b)).isEmpty)
    verify(snap.fileHash.containsKey(key(testFile)))
  }

  Void testEarlyOverlayRetryKeepsOriginalDiagnostics()
  {
    name := ws.podName
    dir := ws.writePod(name, ["A.fan": "class A { Int n := 1 }", "B.fan": "class B { Int n := 2 }"])
    s := session(dir)
    a := dir + `fan/A.fan`; b := dir + `fan/B.fan`
    open(s, a, "class A { UnknownType n }")
    open(s, b, "class B { Int fresh := 3 }")
    verify(s.awaitBackground)
    snap := s.semanticSnapshots[key(dir + `build.fan`)]
    verifyNotNull(snap)
    verify(snap.resolved)
    verifyEq(snap.fileHash[key(a)], a.readAllStr.toBuf.toDigest("SHA-1").toHex)
    verifyFalse(snap.openText.containsKey(key(a)))
    verifyEq(snap.openText[key(b)], "class B { Int fresh := 3 }")
    verify(snap.decls.containsKey("$name::B.fresh"))
    verify(s.diagnosticsProvider.compilerDiagnostics(key(a)).any |d| { d.message.contains("Unknown type") })
  }

  Void testFailedDiskRetainsSnapshotAndMarksFiles()
  {
    dir := ws.writePod(ws.podName, ["A.fan": "class A { Int n := 1 }"])
    s := session(dir); a := dir + `fan/A.fan`
    open(s, a, a.readAllStr); verify(s.awaitBackground)
    before := s.semanticSnapshots[key(dir + `build.fan`)]
    bad := "class A { UnknownType n }"
    a.out.print(bad).close
    edit(s, a, bad); s.didSave(["textDocument": ["uri": key(a)]])
    verify(s.awaitBackground)
    after := s.semanticSnapshots[key(dir + `build.fan`)]
    verifyEq(after.generation, before.generation)
    verifyEq(after.parseFailedFiles, [key(a)])
  }

  Void testFrontendParityNoTransientPodAndClosureLocals()
  {
    name := ws.podName
    text := "class A\n{\n Int bad() { \"wrong\" }\n Void go() { x := 1; [1].each |v| { echo(x); echo(v) }; x++ }\n}\n"
    dir := ws.writePod(name, ["A.fan": text])
    build := dir + `build.fan`; a := dir + `fan/A.fan`
    req := SemanticCompileRequest(1, key(build), name, build, [key(a)], [key(a): text], [key(a): 1])
    legacyInput := CompilerInput()
    legacyInput.podName = name; legacyInput.summary = "parity"; legacyInput.version = Version("1.0")
    legacyInput.mode = CompilerInputMode.file; legacyInput.output = CompilerOutputMode.podFile
    legacyInput.baseDir = dir; legacyInput.srcFiles = [`fan/`]; legacyInput.depends = [Depend("sys 1.0")]
    legacyInput.ns = ws.namespace; legacyInput.log = CompilerLog(Buf().out)
    legacy := Compiler(legacyInput)
    try { legacy.frontend } catch (CompilerErr e) {} finally { legacy.ns?.cleanup }
    verifyFalse(legacy.errs.isEmpty)
    // Warm up lazy library loads before measuring transient pod growth.
    result := SemanticCompile().compile(req)
    count := Pod.list.size
    3.times { result = SemanticCompile().compile(req) }
    verifyEq(Pod.list.size, count)
    verifyEq(result.diagnostics[key(a)].map |d->Str| { d.message }, legacy.errs.map |e->Str| { e.msg })
    verifyNotNull(result.snapshot)
    locals := result.snapshot.decls.vals.findAll |d| { SymbolKey.isLocal(d.key) }
    x := locals.find |d| { d.nameRange.start.line == 3 && d.nameRange.start.character == text.splitLines[3].index("x :=") }
    verifyNotNull(x)
    verify(result.snapshot.occByKey[x.key].size >= 3)
  }

  Void testInstalledFfiNamespaceAssociatedWithCompiler()
  {
    name := ws.podName
    text := "using [java] java.lang::System\nclass A { static Int now() { System.currentTimeMillis } }"
    dir := ws.writePod(name, ["A.fan": text])
    a := dir + `fan/A.fan`; build := dir + `build.fan`
    req := SemanticCompileRequest(1, key(build), name, build, [key(a)], [key(a): text], [key(a): 1])
    result := SemanticCompile().compile(req)
    verifyNotNull(result.snapshot)
    verify(result.diagnostics[key(a)].isEmpty, result.diagnostics[key(a)].toStr)
  }

  Void testTenRapidSavesCoalesceLatest()
  {
    dir := ws.writePod(ws.podName, ["A.fan": "class A {}"])
    s := session(dir); a := dir + `fan/A.fan`
    open(s, a, a.readAllStr); verify(s.awaitBackground)
    before := s.semanticCompileCount
    10.times |i|
    {
      s.didSave(["textDocument": ["uri": key(a)], "text": "class A { Int value$i := $i }"])
    }
    verify(s.awaitBackground)
    verify(s.semanticCompileCount - before <= 2, "Ten saves compiled ${s.semanticCompileCount - before} times")
    verify(s.semanticSnapshots[key(dir + `build.fan`)].decls.keys.any |k| { k.endsWith(".value9") })
  }

  Void testStaleSemanticDiagnosticsRejectedOnMainThread()
  {
    dir := ws.writePod(ws.podName, ["A.fan": "class A {}"])
    s := session(dir); a := dir + `fan/A.fan`; k := key(a)
    open(s, a, a.readAllStr); verify(s.awaitBackground); s.drainOutgoing
    req := SemanticCompileRequest(99, key(dir + `build.fan`), ws.podName, dir + `build.fan`,
      [k], [k: "class A {}"], [k: (Int)s.docVersions.get(k)])
    edit(s, a, "class A { Int fresh := 1 }")
    d := Diagnostic(LspRange(Position(0, 0), Position(0, 1)), Diagnostic.error, "stale", "fantomCompiler")
    s.mailbox.post(SemanticCompileResult(req, null, Str[,], [k: [d]]))
    s.applyBackgroundResults
    verify(s.diagnosticsProvider.compilerDiagnostics(k).isEmpty)
    messages := s.drainOutgoing
    verifyFalse(messages.toStr.contains("stale"))
  }

  Void testWarmupDisabledAndConfigurationEnable()
  {
    dir := ws.writePod(ws.podName, ["A.fan": "class A {}"])
    s := session(dir)
    verify(s.awaitBackground)
    verifyEq(s.semanticCompileCount, 0)
    verify(s.semanticSnapshots.isEmpty)
    s.didChangeConfiguration(["settings": ["fantom": ["semanticIndex": ["backgroundCompile": true]]]])
    verify(s.awaitBackground)
    verifyEq(s.semanticCompileCount, 1)
    verifyNotNull(s.semanticSnapshots[key(dir + `build.fan`)])
  }

  Void testWarmupThenOpenReopenAndSecondFilePublishDiskErrors()
  {
    dir := ws.writePod(ws.podName, ["A.fan": "class A { Int bad() { \"a\" } }",
      "B.fan": "class B { Int bad() { \"b\" } }"])
    s := session(dir, true)
    verify(s.awaitBackground)
    verifyNotNull(s.semanticSnapshots[key(dir + `build.fan`)])
    a := dir + `fan/A.fan`; b := dir + `fan/B.fan`
    open(s, a, a.readAllStr)
    verify(s.awaitBackground)
    verifyEq(s.diagnosticsProvider.compilerDiagnostics(key(a)).size, 1)
    verify(s.drainOutgoing.toStr.contains("Cannot return"))
    s.didClose(["textDocument": ["uri": key(a)]])
    open(s, a, a.readAllStr)
    verify(s.awaitBackground)
    verifyEq(s.diagnosticsProvider.compilerDiagnostics(key(a)).size, 1)
    verify(s.drainOutgoing.toStr.contains("Cannot return"))
    open(s, b, b.readAllStr)
    verify(s.awaitBackground)
    verifyEq(s.diagnosticsProvider.compilerDiagnostics(key(b)).size, 1)
    verify(s.drainOutgoing.toStr.contains("Cannot return"))
  }

  Void testSourceDirectoriesMatchInitInputNotRecursiveOrFwt()
  {
    name := ws.podName
    dir := ws.writePod(name, ["A.fan": "class A {}", "unlisted/A.fan": "class A {}",
      "Ignore.fwt": "class A {}"])
    build := dir + `build.fan`
    buildText := build.readAllStr.replace("srcDirs = [`fan/`]", "srcDirs = [`fan/`, `test/`]")
    build.out.print(buildText).close
    testFile := dir + `test/Checks.fan`
    testFile.out.print("class Checks {}").close
    s := session(dir, true)
    verify(s.awaitBackground)
    snap := s.semanticSnapshots[key(build)]
    verifyNotNull(snap)
    verifyEq(snap.fileHash.keys.sort, [key(dir + `fan/A.fan`), key(testFile)].sort)
    verify(snap.decls.containsKey("$name::Checks"))
    verifyEq(CompilerDiagnostics().sourceFiles(build), snap.fileHash.keys.sort)
    verify(CompilerDiagnostics().compileAndGetErrors(key(dir + `fan/A.fan`), "class A {}").isEmpty)
  }

  Void testStandaloneCanonicalKeysAndActualBufferProvenance()
  {
    file := ws.root + `Standalone.fan`
    file.out.print("class DiskOnly {}").close
    s := session(ws.root)
    text := "class Unsaved\n{\n Int n := 2\n Int go() { n }\n}\n"
    open(s, file, text)
    verify(s.awaitBackground)
    k := key(file)
    snap := s.semanticSnapshots[k]
    verifyNotNull(snap)
    verifyEq(snap.fileHash.keys, [k])
    verifyEq(snap.fileHash[k], text.toBuf.toDigest("SHA-1").toHex)
    verifyEq(snap.openText[k], text)
    verify(snap.decls.vals.all |d| { d.fileKey == k })
    verify(snap.decls.containsKey("lspStandalone::Unsaved"))
    verify(snap.occByFile.containsKey(k))
    verify(s.ensureFresh([k]))
  }

  Void testEnsureFreshResolvesUnregisteredSourceToBuildIdentity()
  {
    dir := ws.writePod(ws.podName, ["A.fan": "class A {}"])
    s := FantomLanguageServer(); server = s
    verify(s.podRegistry.allPods.isEmpty)
    verify(s.ensureFresh([key(dir + `fan/A.fan`)]))
    verifyNotNull(s.semanticSnapshots[key(dir + `build.fan`)])
    verifyNull(s.semanticSnapshots[key(dir + `fan/A.fan`)])
  }

  Void testDeleteAndRemovedFolderRejectLateSnapshots()
  {
    name := ws.podName
    dir := ws.writePod(name, ["A.fan": "class A {}"])
    s := session(dir, true); verify(s.awaitBackground)
    a := dir + `fan/A.fan`; build := dir + `build.fan`; bk := key(build)
    snap := s.semanticSnapshots[bk]
    req := SemanticCompileRequest(snap.generation, bk, name, build, [key(a)], Str:Str[:], Str:Int[:])
    a.delete
    s.didChangeWatchedFiles(["changes": [["uri": key(a), "type": 3]]])
    verifyNull(s.semanticSnapshots[bk])
    s.mailbox.post(SemanticCompileResult(req, snap, Str[,], Str:Diagnostic[][:]))
    s.applyBackgroundResults
    verifyNull(s.semanticSnapshots[bk])
    verify(s.awaitBackground)
    a.out.print("class A {}").close
    verify(s.ensureFresh([bk]))
    snap = s.semanticSnapshots[bk]
    req = SemanticCompileRequest(snap.generation, bk, name, build, [key(a)], Str:Str[:], Str:Int[:])
    s.didChangeWorkspaceFolders(["event": ["added": Obj[,], "removed": [["uri": key(dir), "name": "gone"]]]])
    verifyNull(s.semanticSnapshots[bk])
    s.mailbox.post(SemanticCompileResult(req, snap, Str[,], Str:Diagnostic[][:]))
    s.applyBackgroundResults
    verifyNull(s.semanticSnapshots[bk])
    verify(s.awaitBackground)
  }

  Void testPriorityQueueAndLatestGeneration()
  {
    dir := ws.writePod(ws.podName, ["A.fan": "class A {}"])
    build := dir + `build.fan`; a := dir + `fan/A.fan`
    pool := ActorPool(); box := Mailbox(pool); done := ConcurrentMap()
    worker := SemanticCompileActor(pool, box, done, AtomicInt())
    try
    {
      // Artificial build identities let identical source inputs test scheduling
      // independently of compile timing. Lowest numerical priority must win.
      [["warm", 2], ["open", 1], ["fresh", 0]].each |pair, i|
      {
        worker.request(SemanticCompileRequest(i+1, pair[0], ws.podName, build,
          [key(a)], Str:Str[:], Str:Int[:], File[,], pair[1]))
      }
      worker.request(SemanticCompileRequest(4, "fresh", ws.podName, build,
        [key(a)], [key(a): "class Latest {}"], [key(a): 1], File[,], 2))
      deadline := Duration.now + 10sec
      while (done.size < 3 && Duration.now < deadline) Actor.sleep(10ms)
      verifyEq(done.size, 3)
      results := box.drain
      verifyEq(results.map |r->Str| { ((SemanticCompileResult)r).buildKey }, ["fresh", "open", "warm"])
      verifyEq(((SemanticCompileResult)results.first).generation, 4)
      verify(((SemanticCompileResult)results.first).snapshot.decls.containsKey("${ws.podName}::Latest"))
      verifyEq(worker.compileCount.val, 3)
    }
    finally { pool.stop.join }
  }

  Void testWatchedDiskAndDirtyCloseTriggers()
  {
    name := ws.podName
    dir := ws.writePod(name, ["A.fan": "class A {}", "B.fan": "class B {}"])
    s := session(dir); a := dir + `fan/A.fan`; b := dir + `fan/B.fan`; build := dir + `build.fan`
    open(s, a, a.readAllStr); verify(s.awaitBackground)
    b.out.print("class B { Int fresh := 1 }").close
    s.didChangeWatchedFiles(["changes": [["uri": key(b), "type": 2]]])
    verify(s.awaitBackground)
    verify(s.semanticSnapshots[key(build)].decls.containsKey("$name::B.fresh"))
    b.delete
    s.didChangeWatchedFiles(["changes": [["uri": key(b), "type": 3]]])
    verify(s.awaitBackground)
    verifyFalse(s.semanticSnapshots[key(build)].decls.containsKey("$name::B"))
    edit(s, a, "class A { Int unsaved := 2 }")
    s.didSave(["textDocument": ["uri": key(a)]])
    verify(s.awaitBackground)
    verify(s.semanticSnapshots[key(build)].decls.containsKey("$name::A.unsaved"))
    s.didClose(["textDocument": ["uri": key(a)]])
    verify(s.awaitBackground)
    verifyFalse(s.semanticSnapshots[key(build)].decls.containsKey("$name::A.unsaved"))
    verify(s.semanticSnapshots[key(build)].openText.isEmpty)
  }

  Void testNamespaceUsesRebuiltDependencyWithoutJvmLoad()
  {
    dep := ws.podName("dependency"); name := ws.podName("caller")
    ws.buildPod(dep, ["Api.fan": "class Api { static Int value() { 1 } }"])
    dir := ws.writePod(name, ["A.fan": "using $dep\nclass A { Int go() { Api.value } }"], ["sys 1.0", "$dep 1.0"])
    a := dir + `fan/A.fan`; build := dir + `build.fan`
    req := SemanticCompileRequest(1, key(build), name, build, [key(a)], [key(a): a.readAllStr], [key(a): 1], [ws.root])
    result := SemanticCompile().compile(req)
    verify(result.diagnostics[key(a)].isEmpty)
    verifyNotNull(result.snapshot)
    ws.buildPod(dep, ["Api.fan": "class Api { static Str value() { \"changed\" } }"])
    result = SemanticCompile().compile(req)
    verify(result.diagnostics[key(a)].any |d| { d.message.contains("Cannot return 'sys::Str'") })
    verifyNull(Pod.find(dep, false))
    (ws.libDir + `${dep}.pod`).delete
  }

  Void testEnsureFreshDuplicateBuildIdentitiesAndRefresh()
  {
    name := ws.podName
    one := ws.writePod(name, ["A.fan": "class A {}"])
    two := (ws.root + `other/`).create
    (two + `fan/A.fan`).out.print("class Other {}").close
    (two + `build.fan`).out.print((one + `build.fan`).readAllStr).close
    buf := Buf(); pool := ActorPool(); writer := StdioWriteActor(pool, buf.out)
    try
    {
      s := session(ws.root, false, writer)
      keys := [key(one + `build.fan`), key(two + `build.fan`)]
      verify(s.ensureFresh(keys))
      verifyEq(s.semanticSnapshots.size, 2)
      verify(s.semanticSnapshots[keys[0]].decls.containsKey("$name::A"))
      verify(s.semanticSnapshots[keys[1]].decls.containsKey("$name::Other"))
      keys.each |k| { verify((Int)s.completedGen.get(k) >= s.semanticSnapshots[k].generation) }
      writer.send(null).get
      buf.flip
      rpc := JsonRpc(buf.in, Buf().out)
      refresh := rpc.readMessage
      verifyEq(refresh["method"], "workspace/codeLens/refresh")
      verify(refresh["id"] is Str)
      verifyNull(rpc.readMessage) // immediate refresh only; trailing one follows
      buf.clear
      Actor.sleep(1100ms)
      writer.send(null).get
      buf.flip
      trailing := rpc.readMessage
      verifyEq(trailing["method"], "workspace/codeLens/refresh")
      verifyNotEq(trailing["id"], refresh["id"])
      verifyNull(rpc.readMessage)
      buf.clear
      Actor.sleep(1100ms)
      verify(s.ensureFresh([keys.first]))
      writer.send(null).get
      buf.flip
      next := rpc.readMessage
      verifyEq(next["method"], "workspace/codeLens/refresh")
      verifyNotEq(next["id"], refresh["id"])
      s.cancelRequest("stop")
      // Only exercises the cancellation-map check, NOT production delivery
      // of cancellation while the main dispatch thread waits in ensureFresh.
      verifyFalse(s.ensureFresh(keys, 10sec, "stop"))
    }
    finally { if (server != null) server.awaitBackground; writer.send(null).get; pool.stop.join }
  }

  Void testUnrelatedWarmupSnapshotsDoNotRefresh()
  {
    4.times |i| { ws.writePod(ws.podName("warm$i"), ["A.fan": "class A {}"]) }
    buf := Buf(); pool := ActorPool(); writer := StdioWriteActor(pool, buf.out)
    try
    {
      s := session(ws.root, true, writer)
      verify(s.awaitBackground)
      verifyEq(s.semanticCompileCount, 4)
      verifyEq(s.semanticSnapshots.size, 4)
      // Include the trailing debounce window: zero refreshes, not merely one
      // immediate refresh hiding a storm of pending unrelated snapshots.
      Actor.sleep(1100ms)
      writer.send(null).get
      verifyEq(buf.size, 0)
    }
    finally { if (server != null) server.awaitBackground; writer.send(null).get; pool.stop.join }
  }

  Void testWarmupRefreshesOnlyOpenBuildAndSaveStillRefreshes()
  {
    dir := ws.writePod(ws.podName("visible"), ["A.fan": "class A { Int n := 1 }"])
    3.times |i| { ws.writePod(ws.podName("unrelated$i"), ["B.fan": "class B {}"]) }
    buf := Buf(); pool := ActorPool(); writer := StdioWriteActor(pool, buf.out)
    try
    {
      s := session(ws.root, false, writer); a := dir + `fan/A.fan`
      open(s, a, a.readAllStr)
      verify(s.awaitBackground)
      refreshes := takeRefreshes(writer, buf)
      verifyEq(refreshes.size, 1)
      opened := refreshes.first
      verifyEq(opened["method"], "workspace/codeLens/refresh")

      // The config-triggered warm-up must keep the open build's refresh even
      // though all other pods have the same refresh-supporting client/writer.
      s.didChangeConfiguration(["settings": ["fantom": ["semanticIndex": ["backgroundCompile": true]]]])
      verify(s.awaitBackground)
      verifyEq(s.semanticCompileCount, 5)
      verifyEq(s.semanticSnapshots.size, 4)
      verifyEq(s.semanticSnapshots[key(dir + `build.fan`)].openText[key(a)], a.readAllStr)
      Actor.sleep(1100ms)
      refreshes = takeRefreshes(writer, buf)
      verify(refreshes.size >= 1 && refreshes.size <= 2,
        "Only open-build and coalesced final warm-up refreshes are allowed")
      warmed := refreshes.last
      verifyEq(warmed["method"], "workspace/codeLens/refresh")
      verifyNotEq(warmed["id"], opened["id"])

      s.didSave(["textDocument": ["uri": key(a)], "text": "class A { Int n := 2 }"])
      verify(s.awaitBackground)
      Actor.sleep(1100ms)
      refreshes = takeRefreshes(writer, buf)
      verifyEq(refreshes.size, 1)
      saved := refreshes.first
      verifyEq(saved["method"], "workspace/codeLens/refresh")
      verifyNotEq(saved["id"], warmed["id"])
    }
    finally { if (server != null) server.awaitBackground; writer.send(null).get; pool.stop.join }
  }

  Void testExplicitRefreshChoiceIsIndependentOfPriority()
  {
    dir := ws.writePod(ws.podName, ["A.fan": "class A {}"])
    buf := Buf(); pool := ActorPool(); writer := StdioWriteActor(pool, buf.out)
    try
    {
      s := session(dir, false, writer); bk := key(dir + `build.fan`)
      verify(s.requestSemanticCompile(bk, 0, false) > 0)
      verify(s.awaitBackground)
      Actor.sleep(1100ms)
      writer.send(null).get
      verifyEq(buf.size, 0)
      verifyNotNull(s.semanticSnapshots[bk])
      verify(s.requestSemanticCompile(bk, 2, true) > 0)
      verify(s.awaitBackground)
      writer.send(null).get
      buf.flip
      rpc := JsonRpc(buf.in, Buf().out)
      verifyEq(rpc.readMessage["method"], "workspace/codeLens/refresh")
      verifyNull(rpc.readMessage)
    }
    finally { if (server != null) server.awaitBackground; writer.send(null).get; pool.stop.join }
  }

  Void testFinalWarmupRefreshIncludesDependentSnapshotAndFailedJob()
  {
    dep := ws.podName("api")
    dir := ws.writePod(dep, ["A.fan": "class A { static Int n() { 1 } }"])
    ws.buildPod(dep, ["A.fan": "class A { static Int n() { 1 } }"])
    caller := ws.writePod(ws.podName("caller"),
      ["B.fan": "using $dep\nclass B { Int go() { A.n } }"], ["sys 1.0", "$dep 1.0"])
    failed := ws.writePod(ws.podName("failed"), ["Bad.fan": "class Bad { UnknownType x }"])
    buf := Buf(); pool := ActorPool(); writer := StdioWriteActor(pool, buf.out)
    try
    {
      s := session(ws.root, false, writer); a := dir + `fan/A.fan`
      open(s, a, a.readAllStr); verify(s.awaitBackground)
      takeRefreshes(writer, buf)
      s.didChangeConfiguration(["settings": ["fantom": ["semanticIndex": ["backgroundCompile": true]]]])
      verify(s.awaitBackground)
      verifyNotNull(s.semanticSnapshots[key(caller + `build.fan`)])
      verifyNull(s.semanticSnapshots[key(failed + `build.fan`)])
      verify(s.completedGen.get(key(failed + `build.fan`)) is Int)
      Actor.sleep(1100ms)
      refreshes := takeRefreshes(writer, buf)
      verify(refreshes.size >= 1 && refreshes.size <= 2)
      lenses := s.codeLens(["textDocument": ["uri": key(a)]]) as [Str:Obj?][]
      lens := lenses.find |l| { ((l["data"] as [Str:Obj?])["key"] as Str) == "$dep::A.n" }
      verifyNotNull(lens)
      resolved := s.codeLensResolve(lens) as [Str:Obj?]
      // The failed, unrelated pod does not contribute to this symbol's counts.
      verifyEq((resolved["command"] as [Str:Obj?])["title"], "1 references")
      Actor.sleep(1100ms)
      verifyEq(takeRefreshes(writer, buf).size, 0)
    }
    finally { if (server != null) server.awaitBackground; writer.send(null).get; pool.stop.join }
  }

  Void testSupersededFinalRefreshIsSuppressed()
  {
    buf := Buf(); pool := ActorPool(); writer := StdioWriteActor(pool, buf.out)
    worker := SemanticCompileActor(pool, Mailbox(pool), ConcurrentMap(), AtomicInt())
    epoch := AtomicInt(1)
    try
    {
      worker.refresh(SemanticRefreshRequest(writer)).get
      takeRefreshes(writer, buf)
      worker.refresh(SemanticRefreshRequest(writer, epoch, 1)).get
      epoch.increment
      Actor.sleep(1100ms)
      verifyEq(takeRefreshes(writer, buf).size, 0)
      worker.refresh(SemanticRefreshRequest(writer, epoch, 2)).get
      verifyEq(takeRefreshes(writer, buf).size, 1)
      worker.refresh(SemanticRefreshRequest(writer, epoch, 2)).get
      worker.stopRefresh
      Actor.sleep(1100ms)
      verifyEq(takeRefreshes(writer, buf).size, 0)
    }
    finally { worker.stopRefresh; writer.send(null).get; pool.stop.join }
  }

  Void testQuietWarmupEmitsExactlyOneFinalRefreshWithOpenDocument()
  {
    4.times |i| { ws.writePod(ws.podName("warm$i"), ["A.fan": "class A {}"]) }
    standalone := ws.root + `Visible.fan`
    standalone.out.print("class Visible { Int n := 1 }").close
    buf := Buf(); pool := ActorPool(); writer := StdioWriteActor(pool, buf.out)
    try
    {
      s := session(ws.root, false, writer)
      open(s, standalone, standalone.readAllStr)
      verify(s.awaitBackground)
      takeRefreshes(writer, buf)
      s.didChangeConfiguration(["settings": ["fantom": ["semanticIndex": ["backgroundCompile": true]]]])
      verify(s.awaitBackground)
      verifyEq(s.semanticSnapshots.size, 5)
      Actor.sleep(1100ms)
      verifyEq(takeRefreshes(writer, buf).size, 1)
      Actor.sleep(1100ms)
      verifyEq(takeRefreshes(writer, buf).size, 0)
    }
    finally { if (server != null) server.awaitBackground; writer.send(null).get; pool.stop.join }
  }

  Void testQuietLatestInputsKeepPendingExplicitRefresh()
  {
    dir := ws.writePod(ws.podName, ["A.fan": "class A {}"])
    buf := Buf(); pool := ActorPool(); writer := StdioWriteActor(pool, buf.out)
    try
    {
      s := session(dir, false, writer); bk := key(dir + `build.fan`)
      verify(s.requestSemanticCompile(bk, 0, true) > 0)
      latest := s.requestSemanticCompile(bk, 2, false)
      verify(s.awaitBackground)
      verifyEq(s.semanticSnapshots[bk].generation, latest)
      verifyEq(s.semanticCompileCount, 1)
      writer.send(null).get
      buf.flip
      rpc := JsonRpc(buf.in, Buf().out)
      verifyEq(rpc.readMessage["method"], "workspace/codeLens/refresh")
      verifyNull(rpc.readMessage)
    }
    finally { if (server != null) server.awaitBackground; writer.send(null).get; pool.stop.join }
  }

  Void testShutdownSuppressesPendingTrailingRefresh()
  {
    dir := ws.writePod(ws.podName, ["A.fan": "class A {}"])
    buf := Buf(); pool := ActorPool(); writer := StdioWriteActor(pool, buf.out)
    try
    {
      s := session(dir, false, writer); bk := key(dir + `build.fan`)
      verify(s.ensureFresh([bk]))
      verify(s.ensureFresh([bk]))
      writer.send(null).get
      buf.clear
      s.shutdown
      Actor.sleep(1100ms)
      writer.send(null).get
      verifyEq(buf.size, 0)
      verifyEq(s.requestSemanticCompile(bk), 0)
    }
    finally { writer.send(null).get; pool.stop.join }
  }

  Void testEnsureFreshMissingBuildCannotSucceed()
  {
    s := FantomLanguageServer(); server = s
    missing := key(ws.root + `missing/build.fan`)
    verifyFalse(s.ensureFresh([missing]))
    verifyNull(s.semanticSnapshots[missing])
    // One schedulable build must not conceal an unschedulable member.
    dir := ws.writePod(ws.podName, ["A.fan": "class A {}"])
    verifyFalse(s.ensureFresh([key(dir + `build.fan`), missing]))
    verify(s.awaitBackground)
  }

  Void testEnsureFreshNonliteralPodNameCannotSucceed()
  {
    dir := ws.writePod(ws.podName, ["A.fan": "class A {}"])
    build := dir + `build.fan`
    build.out.print("using build\nclass Build : BuildPod\n{\n new make()\n {\n" +
      " podName = Env.cur.vars[\"POD_NAME\"]\n srcDirs = [`fan/`]\n depends = [\"sys 1.0\"]\n }\n}\n").close
    s := FantomLanguageServer(); server = s
    verifyFalse(s.ensureFresh([key(build)]))
    verifyNull(s.semanticSnapshots[key(build)])
    verifyEq(s.semanticCompileCount, 0)
  }

  Void testEnsureFreshAfterShutdownCannotSucceed()
  {
    dir := ws.writePod(ws.podName, ["A.fan": "class A {}"])
    s := session(dir)
    bk := key(dir + `build.fan`)
    s.shutdown
    verifyFalse(s.ensureFresh([bk]))
    verifyNull(s.semanticSnapshots[bk])
    verifyEq(s.semanticCompileCount, 0)
  }
}
