class CallHierarchyProviderTest : Test
{
  private TestWorkspace ws := TestWorkspace()
  private FantomLanguageServer? server
  private CallHierarchyProvider provider := CallHierarchyProvider()

  override Void teardown()
  {
    if (server != null) { server.awaitBackground; server.shutdown }
    ws.cleanup
  }

  private static Str uri(File f) { WorkspaceManager.fileToUri(f) }
  private static [Str:Obj?] item(Str key) { ["data": ["key": key]] }
  private static Str itemKey([Str:Obj?] item) { ((Str:Obj?)item["data"])["key"] }

  private FantomLanguageServer session()
  {
    s := FantomLanguageServer()
    server = s
    s.initialize(["rootUri": uri(ws.root), "initializationOptions":
      ["envPath": [ws.root.osPath], "semanticIndex": ["backgroundCompile": false]]])
    s.indexWorkspaceNow
    return s
  }

  Void testExactIncomingAndGroupedOutgoing()
  {
    alpha := ws.podName("alpha"); beta := ws.podName("beta")
    ws.buildPod(alpha, ["A.fan": "class A { Void close() {} }\n"])
    text := "using $alpha\nclass Other { Void close() {} }\nclass B\n{\n  Void go()\n  {\n    A a := A()\n    a.close()\n    a.close()\n    Other o := Other()\n    o.close()\n  }\n  Void unrelated() { Other().close() }\n}\n"
    ws.writePod(beta, ["B.fan": text], ["sys 1.0", "$alpha 1.0"])
    file := ws.root + `${beta}/fan/B.fan`
    s := session()
    s.didOpen(["textDocument": ["uri": uri(file), "languageId": "fantom", "version": 1, "text": text]])
    verify(s.ensureFresh(s.podRegistry.allPods.map |p->Str| { p.buildKey }))
    prepared := provider.prepare(s.docManager.getDocument(uri(file)), Position(7, 7), s) as List
    verifyEq(prepared.size, 1)
    verifyEq(itemKey(prepared.first), "$alpha::A.close")
    incoming := provider.incomingCalls(prepared.first, s) as List
    verifyEq(incoming.size, 1)
    call := incoming.first as [Str:Obj?]
    from := call["from"] as [Str:Obj?]
    verifyEq(itemKey(from), "$beta::B.go")
    verifyEq(from["name"], "go")
    verifyEq(from["uri"], s.clientUri(uri(file)))
    ranges := call["fromRanges"] as List
    verifyEq(ranges.size, 2)
    verifyEq(((Str:Obj?)ranges.first)["start"], Position(7, 6).toMap)

    outgoing := provider.outgoingCalls(item("$beta::B.go"), s) as List
    keys := outgoing.map |[Str:Obj?] edge->Str| { itemKey(edge["to"]) }
    verify(keys.contains("$alpha::A.close"))
    verify(keys.contains("$beta::Other.close"))
    verifyEq(keys.findAll |k| { k == "$alpha::A.close" }.size, 1)
    edge := outgoing.find |[Str:Obj?] e->Bool| { itemKey(e["to"]) == "$alpha::A.close" } as [Str:Obj?]
    verifyEq((edge["fromRanges"] as List).size, 2)
    // Neither display name nor URI is a binding fallback.
    verifyEq((provider.incomingCalls(["name": "close"], s) as List).size, 0)
    verifyEq((provider.outgoingCalls(["name": "go"], s) as List).size, 0)
    verifyNull(provider.prepare(s.docManager.getDocument(uri(file)), Position(2, 6), s))
    shifted := "// inserted\n" + text
    s.didChange(["textDocument": ["uri": uri(file), "version": 2],
      "contentChanges": [["text": shifted]]])
    incoming = provider.incomingCalls(prepared.first, s) as List
    call = incoming.first as [Str:Obj?]
    ranges = call["fromRanges"] as List
    verifyEq(ranges.size, 2)
    verifyEq(((Str:Obj?)ranges.first)["start"], Position(8, 6).toMap)
  }

  Void testFieldInitializerOwnerAndNonCallExclusion()
  {
    pod := ws.podName
    text := "class A\n{\n  static Int helper() { 1 }\n  Int field := helper()\n}\n"
    dir := ws.writePod(pod, ["A.fan": text])
    s := session()
    verify(s.ensureFresh([uri(dir + `build.fan`)]))
    result := provider.incomingCalls(item("$pod::A.helper"), s) as List
    verifyEq(result.size, 1)
    from := ((Str:Obj?)result.first)["from"] as [Str:Obj?]
    verifyEq(itemKey(from), "$pod::A.field")
    verifyEq(from["kind"], DocumentSymbol.fieldKind)
    verifyEq((provider.outgoingCalls(item("$pod::A.field"), s) as List).size, 1)
    doc := DocumentState(uri(dir + `fan/A.fan`), 1, text)
    verifyNull(provider.prepare(doc, Position(3, 7), s))
    verifyNull(provider.prepare(doc, Position(0, 0), s))
    snap := s.semanticSnapshots[uri(dir + `build.fan`)]
    // Slot literals/field references must not become calls even with an owner.
    o := Occurrence(uri(dir + `fan/A.fan`), LspRange(Position(3, 15), Position(3, 21)),
      "$pod::A.helper", OccKind.slotLiteral, null, "$pod::A.field")
    s.semanticSnapshots[uri(dir + `build.fan`)] = SemanticSnapshot(pod, snap.generation,
      snap.fileHash, snap.openText, [o.fileKey: [o]], snap.decls, [:], [,], true)
    verifyEq((provider.incomingCalls(item("$pod::A.helper"), s) as List).size, 0)
  }

  Void testHeuristicUsesReceiverAndCallerScope()
  {
    pod := ws.podName
    text := "class A\n{\n  Void close() {}\n}\nclass Other\n{\n  Void close() {}\n}\nclass B\n{\n  Void go()\n  {\n    A a := A()\n    a.close()\n    Other o := Other()\n    o.close()\n  }\n}\n"
    ws.writePod(pod, ["B.fan": text])
    s := session()
    verifyEq(s.semanticSnapshots.size, 0)
    incoming := provider.incomingCalls(item("$pod::A.close"), s) as List
    verifyEq(incoming.size, 1)
    edge := incoming.first as [Str:Obj?]
    verifyEq(itemKey(edge["from"]), "$pod::B.go")
    verifyEq((edge["fromRanges"] as List).size, 1)
    outgoing := provider.outgoingCalls(item("$pod::B.go"), s) as List
    keys := outgoing.map |[Str:Obj?] e->Str| { itemKey(e["to"]) }
    verify(keys.contains("$pod::A.close"))
    verify(keys.contains("$pod::Other.close"))
  }

  Void testUriCallbacksPreserveWorkspaceSymbolsAndActionEdits()
  {
    s := session()
    file := uri(ws.root + `A.fan`)
    original := file.replace("A.fan", "%41.fan")
    text := "using sys\nclass A {}\n// comment\n"
    s.didOpen(["textDocument": ["uri": original, "languageId": "fantom", "version": 1, "text": text]])
    callback := |Str key->Str| { s.clientUri(key) }
    symbols := WorkspaceSymbolProvider().search("A", s.symbolTable, callback) as List
    verifyEq((((Str:Obj?)symbols.first)["location"] as [Str:Obj?])["uri"], original)
    doc := s.docManager.getDocument(file)
    actions := CodeActionProvider().codeActions(doc, s.docManager.parseDocument(file),
      LspRange(Position(2, 0), Position(2, 2)), [:], callback) as List
    verify(actions.size >= 2)
    actions.each |[Str:Obj?] action|
    {
      edit := action["edit"] as [Str:Obj?]
      changes := edit["changes"] as [Str:Obj?]
      verifyEq(changes.keys, [original])
    }
    // Link existence/lookup behavior is unchanged; an unavailable pod stays absent.
    parsed := RecoveringParser().parse(file, "using noSuchHierarchyTestPod\n")
    verifyEq(DocumentLinkProvider().links(doc, parsed, callback).size, 0)
  }
}
