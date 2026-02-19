class SerializationTest : Test
{
  // ── extractUri ────────────────────────────────────────────────────────────────

  Void testExtractUri()
  {
    params := Str:Obj?["textDocument": Str:Obj?["uri": "file:///foo.fan"]]
    uri := Serialization.extractUri(params)
    verifyEq(uri, "file:///foo.fan")
  }

  Void testExtractUriFromDifferentDoc()
  {
    params := Str:Obj?["textDocument": Str:Obj?["uri": "file:///bar/baz.fan"]]
    uri := Serialization.extractUri(params)
    verifyEq(uri, "file:///bar/baz.fan")
  }

  // ── extractPosition ───────────────────────────────────────────────────────────

  Void testExtractPosition()
  {
    pos := Position(5, 10)
    params := Str:Obj?["position": pos.toMap]
    p := Serialization.extractPosition(params)
    verifyEq(p.line, 5)
    verifyEq(p.character, 10)
  }

  Void testExtractPositionZero()
  {
    pos := Position(0, 0)
    params := Str:Obj?["position": pos.toMap]
    p := Serialization.extractPosition(params)
    verifyEq(p.line, 0)
    verifyEq(p.character, 0)
  }

  // ── extractTextDocument ───────────────────────────────────────────────────────

  Void testExtractTextDocument()
  {
    params := Str:Obj?["textDocument": Str:Obj?["uri": "file:///my.fan"]]
    td := Serialization.extractTextDocument(params)
    verifyEq(td.uri, "file:///my.fan")
  }

  // ── publishDiagnostics ────────────────────────────────────────────────────────

  Void testPublishDiagnosticsFormat()
  {
    r := LspRange(Position(0, 0), Position(0, 5))
    diag := Diagnostic(r, Diagnostic.error, "test error")
    msg := Serialization.publishDiagnostics("file:///x.fan", [diag])
    verifyEq(msg["method"], "textDocument/publishDiagnostics")
    p := msg["params"] as [Str:Obj?]
    verifyNotNull(p)
    verifyEq(p["uri"], "file:///x.fan")
    diagList := p["diagnostics"] as List
    verifyNotNull(diagList)
    verifyEq(diagList.size, 1)
  }

  Void testPublishDiagnosticsEmpty()
  {
    msg := Serialization.publishDiagnostics("file:///y.fan", Diagnostic[,])
    p := msg["params"] as [Str:Obj?]
    diagList := p["diagnostics"] as List
    verifyEq(diagList.size, 0)
  }

  // ── serverCapabilities ────────────────────────────────────────────────────────

  Void testServerCapabilitiesHoverEnabled()
  {
    caps := Serialization.serverCapabilities(true, false, false, false, false, false, false, false, false, false, false, false)
    verifyEq(caps["hoverProvider"], true)
    verifyFalse(caps.containsKey("completionProvider"))
  }

  Void testServerCapabilitiesCompletionEnabled()
  {
    caps := Serialization.serverCapabilities(false, false, false, true, false, false, false, false, false, false, false, false)
    completionCaps := caps["completionProvider"] as [Str:Obj?]
    verifyNotNull(completionCaps)
    triggers := completionCaps["triggerCharacters"] as List
    verifyNotNull(triggers)
    verify(triggers.contains("."))
  }

  Void testServerCapabilitiesSignatureHelpEnabled()
  {
    caps := Serialization.serverCapabilities(false, false, false, false, true, false, false, false, false, false, false, false)
    sigCaps := caps["signatureHelpProvider"] as [Str:Obj?]
    verifyNotNull(sigCaps)
    triggers := sigCaps["triggerCharacters"] as List
    verifyNotNull(triggers)
    verify(triggers.contains("("))
    verify(triggers.contains(","))
  }

  Void testServerCapabilitiesAlwaysHasTextDocumentSync()
  {
    caps := Serialization.serverCapabilities(false, false, false, false, false, false, false, false, false, false, false, false)
    sync := caps["textDocumentSync"] as [Str:Obj?]
    verifyNotNull(sync)
    verifyEq(sync["openClose"], true)
  }

  Void testServerCapabilitiesDefinitionEnabled()
  {
    caps := Serialization.serverCapabilities(false, true, false, false, false, false, false, false, false, false, false, false)
    verifyEq(caps["definitionProvider"], true)
  }

  Void testServerCapabilitiesAllDisabledHasNoExtras()
  {
    caps := Serialization.serverCapabilities(false, false, false, false, false, false, false, false, false, false, false, false)
    verifyFalse(caps.containsKey("hoverProvider"))
    verifyFalse(caps.containsKey("definitionProvider"))
    verifyFalse(caps.containsKey("completionProvider"))
    verifyFalse(caps.containsKey("signatureHelpProvider"))
  }
}
