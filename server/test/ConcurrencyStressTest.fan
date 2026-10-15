using concurrent

**
** Main-thread state-ownership stress test: 300 generated files are indexed
** from the `initialized` notification while 500 interleaved codeLens /
** definition / references / didChange messages go through `LspDispatcher`.
** No response may contain `error`; background compiles run for real.
**
class ConcurrencyStressTest : Test
{
  private File? root

  override Void teardown()
  {
    if (root != null) try root.delete; catch (Err e) {}
  }

  Void testIndexWhileServingRequests()
  {
    root = Env.cur.tempDir + `fantomLsp-test-${Uuid().toStr}/`
    podDir := root + `stresspod/`
    podName := "stress" + Uuid().toStr.replace("-", "")[0..<8]
    (podDir + `build.fan`).out.print("using build\nclass Build : BuildPod\n{\n  new make()\n  {\n    podName = \"$podName\"\n    summary = \"stress\"\n    depends = [\"sys 1.0\"]\n    srcDirs = [`fan/`]\n  }\n}\n").close
    300.times |i| { (podDir + `fan/Gen${i}.fan`).out.print(source(i, 0)).close }

    server := FantomLanguageServer()
    dispatcher := LspDispatcher(server)
    responses := [Str:Obj?][,]
    id := 0
    |Str, [Str:Obj?]| req := |Str method, [Str:Obj?] params|
    {
      r := dispatcher.dispatch(["jsonrpc": "2.0", "id": ++id, "method": method, "params": params])
      if (r != null) responses.add(r)
    }
    |Str, [Str:Obj?]| note := |Str method, [Str:Obj?] params|
    {
      dispatcher.dispatch(["jsonrpc": "2.0", "method": method, "params": params])
      dispatcher.pendingNotifications
    }

    req("initialize", ["rootUri": UriKey.toClientUri(WorkspaceManager.fileToUri(root)), "capabilities": [Str:Obj?][:]])
    note("initialized", [Str:Obj?][:])

    keys := (0..<5).toList.map |i->Str| { WorkspaceManager.fileToUri(podDir + `fan/Gen${i * 60}.fan`) }
    versions := Str:Int[:]
    keys.each |k, i|
    {
      note("textDocument/didOpen", ["textDocument": ["uri": UriKey.toClientUri(k), "languageId": "fantom",
        "version": 1, "text": source(i * 60, 0)]])
      versions[k] = 1
    }

    sawIncomplete := false
    midLoopApplies := 0
    Int? completedAt := null
    500.times |n|
    {
      if (!server.indexComplete) sawIncomplete = true
      // Pace the client so index batches really interleave with requests.
      Actor.sleep(3ms)
      entriesBefore := server.symbolTable.allEntries.size
      applyBefore := server.lastBackgroundApplyTicks
      k := keys[n % keys.size]
      td := ["uri": UriKey.toClientUri(k)]
      pos := ["line": 3 + (n % 4), "character": 10 + (n % 7)]
      switch (n % 4)
      {
        case 0: req("textDocument/codeLens", ["textDocument": td])
        case 1: req("textDocument/definition", ["textDocument": td, "position": pos])
        case 2: req("textDocument/references", ["textDocument": td, "position": pos, "context": ["includeDeclaration": true]])
        default:
          v := versions[k] + 1
          versions[k] = v
          note("textDocument/didChange", ["textDocument": ["uri": td["uri"], "version": v],
            "contentChanges": [["text": source(keys.index(k) * 60, v)]]])
      }
      // A partial index batch was applied by this dispatch: the index grew,
      // yet the generation is still incomplete (true interleaving).
      if (server.lastBackgroundApplyTicks != applyBefore && !server.indexComplete &&
          server.symbolTable.allEntries.size > entriesBefore)
        midLoopApplies++
      if (server.indexComplete && completedAt == null) completedAt = n
    }

    verify(sawIncomplete, "indexing finished before requests started; the test did not overlap")
    Env.cur.err.printLine("[stress] midLoopApplies=$midLoopApplies completedAt=$completedAt")
    verify(midLoopApplies >= 1, "no index batch was applied mid-loop while indexing was incomplete (completedAt=$completedAt)")
    verify(server.awaitBackground(180sec), "background work did not finish")
    req("textDocument/codeLens", ["textDocument": ["uri": UriKey.toClientUri(keys.first)]])

    errors := responses.findAll |r| { r.containsKey("error") }
    verifyEq(errors.size, 0, errors.first?.toStr)
    verifyEq(responses.size, 1 + 375 + 1)
    verify(responses.all |r| { r.containsKey("result") })

    // Index is complete and open buffers win over disk.
    verifyEq(server.symbolTable.findAllByName("Gen299").size, 1)
    keys.each |k, i|
    {
      v := versions[k]
      verifyNotNull(server.symbolTable.findByName("Gen${i * 60}.edit$v"), "open buffer for $k")
      verifyNull(server.symbolTable.findByName("Gen${i * 60}.edit0"), "disk entry leaked for $k")
    }
  }

  ** A file that references its neighbours, so definition/references have work.
  private static Str source(Int i, Int version)
  {
    next := (i + 1) % 300
    return "class Gen$i\n" +
           "{\n" +
           "  Gen$next? next\n" +
           "  Int edit$version() { return $version }\n" +
           "  Void call() { x := Gen$next(); x.call; edit$version }\n" +
           "  Str name() { \"Gen$i\" }\n" +
           "}\n"
  }
}
