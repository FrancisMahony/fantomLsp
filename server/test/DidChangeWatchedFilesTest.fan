class DidChangeWatchedFilesTest : Test
{
  Void testIsFanSourceUri()
  {
    verify(WorkspaceManager.isFanSourceUri("file:///a/b.fan"))
    verify(WorkspaceManager.isFanSourceUri("file:///a/b.fwt"))
    verify(WorkspaceManager.isFanSourceUri("file:///A/B.FAN"))
    verifyFalse(WorkspaceManager.isFanSourceUri("file:///a/b.md"))
    verifyFalse(WorkspaceManager.isFanSourceUri("file:///a/build.fan.bak"))
  }

  Void testCreatedIndexesSymbols()
  {
    tmp := File.createTemp("watch", ".fan")
    try
    {
      tmp.out.print("class WatchedType {}\n").close
      uri := WorkspaceManager.fileToUri(tmp)
      server := FantomLanguageServer()
      server.didChangeWatchedFiles([
        "changes": [
          ["uri": uri, "type": 1],
        ],
      ])
      verifyNotNull(server.symbolTable.findType("WatchedType"))
    }
    finally tmp.delete
  }

  Void testDeletedRemovesSymbols()
  {
    tmp := File.createTemp("watch", ".fan")
    try
    {
      tmp.out.print("class ToDelete {}\n").close
      uri := WorkspaceManager.fileToUri(tmp)
      server := FantomLanguageServer()
      server.didChangeWatchedFiles(["changes": [["uri": uri, "type": 1]]])
      verifyNotNull(server.symbolTable.findType("ToDelete"))
      server.didChangeWatchedFiles(["changes": [["uri": uri, "type": 3]]])
      verifyNull(server.symbolTable.findType("ToDelete"))
    }
    finally tmp.delete
  }

  Void testSkipsOpenDocuments()
  {
    tmp := File.createTemp("watch", ".fan")
    try
    {
      tmp.out.print("class DiskVersion {}\n").close
      uri := WorkspaceManager.fileToUri(tmp)
      server := FantomLanguageServer()
      item := TextDocumentItem(uri, "fantom", 1, "class BufferVersion {}\n")
      server.docManager.open(item)
      server.didChangeWatchedFiles(["changes": [["uri": uri, "type": 2]]])
      verifyNull(server.symbolTable.findType("DiskVersion"))
    }
    finally tmp.delete
  }

  Void testIgnoresNonFan()
  {
    server := FantomLanguageServer()
    server.didChangeWatchedFiles(["changes": [["uri": "file:///x.md", "type": 1]]])
    verifyEq(server.symbolTable.allEntries.size, 0)
  }

  Void testIndexedThenOpenedHasOneSetOfEntries()
  {
    root := tempDir()
    file := root + `A b/Foo.fan`
    file.parent.create
    disk := "using concurrent::Actor\nclass Foo\n{\n  Str diskField\n}\n"
    buffer := "using concurrent::ActorPool\nclass Foo\n{\n  Int bufferField\n}\n"
    file.out.print(disk).close
    server := UriIntakeTestServer()
    key := WorkspaceManager.fileToUri(file)
    // Deliberately non-default spelling proves preservation, not re-encoding.
    client := UriKey.toClientUri(key).replace("file:", "FILE:")
    if (Env.cur.os == "win32") verify(client.contains("%3A"))
    server.workspaceManager.addFolder(WorkspaceManager.fileToUri(root))
    server.indexWorkspaceNow
    verifyEq(server.symbolTable.allEntries.size, 2)
    verifyNotNull(server.symbolTable.findByName("diskField"))
    notification := server.didOpen(["textDocument": ["uri": client, "languageId": "fantom", "version": 1, "text": buffer]])
    verifyEq(server.symbolTable.allEntries.size, 2)
    verifyNull(server.symbolTable.findByName("diskField"))
    verifyNotNull(server.symbolTable.findByName("bufferField"))
    verify(server.symbolTable.allEntries.all |entry| { entry.uri == key })
    verifyEq(server.docManager.openUris, [key])
    verifyEq(server.typeResolver.resolveType(key, "Actor", server.symbolTable), null)
    verifyEq(server.typeResolver.resolveType(key, "ActorPool", server.symbolTable), "concurrent::ActorPool")
    verifyEq(server.referenceIndex.findReferences("Str").size, 0)
    verifyEq(server.referenceIndex.findReferences("Int").size, 1)
    verifyDiagnosticUri(notification, client)

    // Disk events in a different spelling must never overwrite the buffer.
    server.didChangeWatchedFiles(["changes": [["uri": key, "type": 2], ["uri": client, "type": 3]]])
    verifyEq(server.symbolTable.allEntries.size, 2)
    verifyNotNull(server.symbolTable.findByName("bufferField"))

    // Request intake must use canonical keys even for APIs reading raw maps.
    symbols := server.documentSymbol(["textDocument": ["uri": client]]) as List
    verifyEq(symbols.size, 1)
    changed := server.didChange([
      "textDocument": ["uri": key, "version": 2],
      "contentChanges": [["text": buffer]],
    ])
    verifyDiagnosticUri(changed, client)
    saved := server.didSave(["textDocument": ["uri": key], "text": buffer])
    verifyDiagnosticUri(saved, client)
    server.publishCompilerDiagnostics(key)
    outgoing := server.drainOutgoing
    verifyEq(outgoing.size, 1)
    verifyDiagnosticUri(outgoing.first, client)
    closed := server.didClose(["textDocument": ["uri": key]])
    verifyDiagnosticUri(closed, client)
    verifyEq(server.clientUri(key), UriKey.toClientUri(key))
  }

  Void testMixedEncodingWatchedUpdateAndDelete()
  {
    root := tempDir()
    file := root + `A b/Foo.fan`
    file.parent.create
    file.out.print("class Before\n{\n  Str value\n}\n").close
    server := FantomLanguageServer()
    key := WorkspaceManager.fileToUri(file)
    client := UriKey.toClientUri(key)
    server.didChangeWatchedFiles(["changes": [["uri": key, "type": 1]]])
    file.out.print("class After\n{\n  Int value\n}\n").close
    server.didChangeWatchedFiles(["changes": [["uri": client, "type": 2]]])
    verifyEq(server.symbolTable.allEntries.size, 2)
    verifyNull(server.symbolTable.findType("Before"))
    verifyNotNull(server.symbolTable.findType("After"))
    verifyEq(server.referenceIndex.findReferences("Str").size, 0)
    verifyEq(server.referenceIndex.findReferences("Int").size, 1)
    server.didChangeWatchedFiles(["changes": [["uri": client, "type": 3]]])
    verifyEq(server.symbolTable.allEntries.size, 0)
    verifyEq(server.referenceIndex.findReferences("Int").size, 0)
  }

  private Void verifyDiagnosticUri([Str:Obj?]? notification, Str expected)
  {
    verifyNotNull(notification)
    params := notification["params"] as [Str:Obj?]
    verifyEq(params["uri"], expected)
  }
}

** Keep URI intake tests deterministic; actor scheduling is covered elsewhere.
internal class UriIntakeTestServer : FantomLanguageServer
{
  override Void scheduleCompilerDiagnostics(Str triggerUri) {}
}
