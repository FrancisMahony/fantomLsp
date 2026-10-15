class LspSessionTest : Test
{
  private FantomLanguageServer server := FantomLanguageServer()
  private LspDispatcher? dispatcher
  private Int nextId := 1

  override Void setup()
  {
    server = FantomLanguageServer()
    dispatcher = LspDispatcher(server)
    nextId = 1
  }

  private [Str:Obj?]? req(Str method, [Str:Obj?] params)
  {
    id := nextId++
    return dispatcher.dispatch(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
  }

  private Void note(Str method, [Str:Obj?] params)
  {
    dispatcher.dispatch(["jsonrpc": "2.0", "method": method, "params": params])
  }

  private static Str sampleSrc()
  {
    "using sys\n" +
    "class Sample\n" +
    "{\n" +
    "  static Grid nvCmmsReadAll(Obj conn, DateTime? modStart := null, Number? limit := null)\n" +
    "  {\n" +
    "    return echo(conn, modStart, limit)\n" +
    "  }\n" +
    "  Void unusedLocal()\n" +
    "  {\n" +
    "    x := 1\n" +
    "  }\n" +
    "}\n"
  }

  private Void openSample()
  {
    req("initialize", [
      "rootUri": "file:///lsp-session-test",
      "capabilities": [Str:Obj?][:],
      "initializationOptions": ["maxFiles": 10],
    ])
    note("initialized", [Str:Obj?][:])
    note("textDocument/didOpen", [
      "textDocument": [
        "uri": "file:///sample.fan",
        "languageId": "fantom",
        "version": 1,
        "text": sampleSrc,
      ],
    ])
  }

  Void testInitializeAdvertisesCodeLens()
  {
    resp := req("initialize", ["capabilities": [Str:Obj?][:]])
    result := resp["result"] as [Str:Obj?]
    caps := result["capabilities"] as [Str:Obj?]
    verifyEq((caps["codeLensProvider"] as [Str:Obj?])["resolveProvider"], true)
    info := result["serverInfo"] as [Str:Obj?]
    verifyEq(info["version"], "0.3.0")
  }

  Void testCodeLensIsKnownRequest()
  {
    openSample
    resp := req("textDocument/codeLens", [
      "textDocument": ["uri": "file:///sample.fan"],
    ])
    verifyNull(resp["error"])
    verifyNotNull(resp["result"])
  }

  Void testCodeLensResolveIsKnownRequest()
  {
    req("initialize", ["capabilities": [Str:Obj?][:]])
    lens := Str:Obj?["range": LspRange(Position(0, 0), Position(0, 1)).toMap]
    resp := req("codeLens/resolve", lens)
    verifyNull(resp["error"])
    verifyEq(resp["result"], lens)
  }

  Void testCodeLensDisabledByInitializationAndConfiguration()
  {
    ws := TestWorkspace()
    try
    {
      text := "class A\n{\n  Void close() {}\n}\n"
      dir := ws.writePod(ws.podName, ["A.fan": text])
      uri := WorkspaceManager.fileToUri(dir + `fan/A.fan`)
      req("initialize", ["rootUri": WorkspaceManager.fileToUri(ws.root),
        "capabilities": [Str:Obj?][:], "initializationOptions":
          ["codeLens": ["enabled": false], "semanticIndex": ["backgroundCompile": false]]])
      server.indexWorkspaceNow
      note("textDocument/didOpen", ["textDocument": ["uri": uri,
        "languageId": "fantom", "version": 1, "text": text]])
      params := Str:Obj?["textDocument": ["uri": uri]]
      verifyEq((req("textDocument/codeLens", params)["result"] as List).size, 0)
      note("workspace/didChangeConfiguration", ["settings": ["fantom": ["codeLens": ["enabled": true]]]])
      verifyEq((req("textDocument/codeLens", params)["result"] as List).size, 1)
      note("workspace/didChangeConfiguration", ["settings": ["fantom": ["codeLens": ["enabled": false]]]])
      verifyEq((req("textDocument/codeLens", params)["result"] as List).size, 0)
    }
    finally
    {
      server.awaitBackground
      server.shutdown
      ws.cleanup
    }
  }

  Void testDidOpenParserDiagsHaveNoUnusedNull()
  {
    openSample
    notes := dispatcher.pendingNotifications
    diagsNote := notes.find |n| { n["method"] == "textDocument/publishDiagnostics" }
    verifyNotNull(diagsNote)
    params := diagsNote["params"] as [Str:Obj?]
    diags := params["diagnostics"] as List
    diags.each |d|
    {
      dm := d as [Str:Obj?]
      msg := dm["message"] as Str ?: ""
      verifyFalse(msg.contains("Unused local 'null'"))
    }
    unusedX := diags.find |d|
    {
      dm := d as [Str:Obj?]
      return (dm["message"] as Str) == "Unused local 'x'"
    }
    verifyNotNull(unusedX)
  }

  Void testHoverOnClassName()
  {
    openSample
    resp := req("textDocument/hover", [
      "textDocument": ["uri": "file:///sample.fan"],
      "position": ["line": 1, "character": 7],
    ])
    verifyNull(resp["error"])
    result := resp["result"] as [Str:Obj?]
    verifyNotNull(result)
    contents := result["contents"] as [Str:Obj?]
    val := contents["value"] as Str ?: ""
    verify(val.contains("Sample"))
  }

  Void testUnknownMethodMinus32601()
  {
    resp := req("textDocument/notARealMethod", [Str:Obj?][:])
    err := resp["error"] as [Str:Obj?]
    verifyEq(((Num)err["code"]).toInt, -32601)
  }

  Void testCollisionRequestsUsePreciseBindingsAndClientUri()
  {
    f := T09Fixture()
    try
    {
      alpha := f.ws.podName("alpha"); beta := f.ws.podName("beta")
      f.ws.buildPod(alpha, ["A.fan": "class A\n{\n  Void close(Int code) {}\n}\n"])
      text := "using $alpha\nclass Other\n{\n  Void close(Str reason) {}\n}\nclass B\n{\n  Void go(A a, Other o)\n  {\n    a.close(1)\n    o.close(\"other\")\n  }\n}\n"
      dir := f.ws.writePod(beta, ["B.fan": text], ["sys 1.0", "$alpha 1.0"])
      f.start(dir + `fan/B.fan`, text)
      server = f.server
      dispatcher = LspDispatcher(server)
      params := Str:Obj?["textDocument": ["uri": f.doc.originalUri],
        "position": f.at("close", 9).toMap]
      definition := req("textDocument/definition", params)["result"] as [Str:Obj?]
      verifyEq(definition["uri"], server.clientUri(T09Fixture.key(f.ws.root + `${alpha}/fan/A.fan`)))
      refs := req("textDocument/references", params)["result"] as List
      verifyEq(refs.size, 1)
      verifyEq(((Str:Obj?)refs.first)["uri"], f.doc.originalUri)
      params["context"] = ["includeDeclaration": true]
      verifyEq((req("textDocument/references", params)["result"] as List).size, 2)
      hover := req("textDocument/hover", params)["result"] as [Str:Obj?]
      verify(((Str:Obj?)hover["contents"])["value"].toStr.contains("Int code"))

      params["newName"] = "finish"
      response := dispatcher.dispatch(["jsonrpc": "2.0", "id": "collision-rename",
        "method": "textDocument/rename", "params": params])
      verifyNull(response["error"])
      verifyEq(response["id"], "collision-rename")
      edits := ((Str:Obj?)response["result"])["changes"] as [Str:Obj?]
      verifyEq(edits.size, 2)
      localEdits := edits[f.doc.originalUri] as List
      verifyEq(localEdits.size, 1)
      verifyEq(((Str:Obj?)localEdits.first)["newText"], "finish")
      verifyEq((((Str:Obj?)localEdits.first)["range"] as [Str:Obj?])["start"], f.at("close", 9).toMap)

      // A real JSON-RPC string ID reaches the cancellation guard unchanged.
      server.cancelRequest("cancelled-rename")
      response = dispatcher.dispatch(["jsonrpc": "2.0", "id": "cancelled-rename",
        "method": "textDocument/rename", "params": params])
      verifyNull(response["error"])
      verifyNull(response["result"])
      verifyFalse(server.isCancelled("cancelled-rename"))
    }
    finally { f.cleanup }
  }
}
