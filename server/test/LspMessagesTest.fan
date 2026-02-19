class LspMessagesTest : Test
{
  // ── Position ─────────────────────────────────────────────────────────────────

  Void testPositionMake()
  {
    p := Position(3, 7)
    verifyEq(p.line, 3)
    verifyEq(p.character, 7)
  }

  Void testPositionToMap()
  {
    p := Position(2, 5)
    m := p.toMap
    verifyEq(m["line"], 2)
    verifyEq(m["character"], 5)
  }

  Void testPositionRoundtrip()
  {
    p := Position(10, 20)
    p2 := Position.fromMap(p.toMap)
    verifyEq(p2.line, 10)
    verifyEq(p2.character, 20)
  }

  Void testPositionZero()
  {
    p := Position(0, 0)
    verifyEq(p.line, 0)
    verifyEq(p.character, 0)
  }

  // ── LspRange ─────────────────────────────────────────────────────────────────

  Void testLspRangeMake()
  {
    r := LspRange(Position(0, 0), Position(1, 5))
    verifyEq(r.start.line, 0)
    verifyEq(r.start.character, 0)
    verifyEq(r.end.line, 1)
    verifyEq(r.end.character, 5)
  }

  Void testLspRangeToMap()
  {
    r := LspRange(Position(0, 3), Position(0, 8))
    m := r.toMap
    verifyNotNull(m["start"])
    verifyNotNull(m["end"])
    start := m["start"] as [Str:Obj?]
    verifyEq(start["character"], 3)
  }

  Void testLspRangeRoundtrip()
  {
    r := LspRange(Position(4, 2), Position(4, 10))
    r2 := LspRange.fromMap(r.toMap)
    verifyEq(r2.start.line, 4)
    verifyEq(r2.start.character, 2)
    verifyEq(r2.end.line, 4)
    verifyEq(r2.end.character, 10)
  }

  // ── Location ─────────────────────────────────────────────────────────────────

  Void testLocationToMap()
  {
    loc := Location("file:///foo.fan", LspRange(Position(0, 0), Position(1, 0)))
    m := loc.toMap
    verifyEq(m["uri"], "file:///foo.fan")
    verifyNotNull(m["range"])
  }

  // ── Diagnostic ───────────────────────────────────────────────────────────────

  Void testDiagnosticSeverityConstants()
  {
    verifyEq(Diagnostic.error,   1)
    verifyEq(Diagnostic.warning, 2)
    verifyEq(Diagnostic.info,    3)
    verifyEq(Diagnostic.hint,    4)
  }

  Void testDiagnosticToMap()
  {
    r := LspRange(Position(0, 0), Position(0, 5))
    d := Diagnostic(r, Diagnostic.error, "syntax error")
    m := d.toMap
    verifyEq(m["severity"], 1)
    verifyEq(m["message"], "syntax error")
    verifyNotNull(m["range"])
  }

  Void testDiagnosticNullSourceOmitted()
  {
    r := LspRange(Position(0, 0), Position(0, 5))
    d := Diagnostic(r, Diagnostic.warning, "warn")
    m := d.toMap
    verifyFalse(m.containsKey("source"))
  }

  Void testDiagnosticWithSource()
  {
    r := LspRange(Position(0, 0), Position(0, 5))
    d := Diagnostic(r, Diagnostic.warning, "unused import", "fantomLsp")
    m := d.toMap
    verifyEq(m["source"], "fantomLsp")
  }

  // ── CompletionItem ────────────────────────────────────────────────────────────

  Void testCompletionItemKindConstants()
  {
    verifyEq(CompletionItem.text,          1)
    verifyEq(CompletionItem.method,        2)
    verifyEq(CompletionItem.function,      3)
    verifyEq(CompletionItem.constructor,   4)
    verifyEq(CompletionItem.field,         5)
    verifyEq(CompletionItem.variable,      6)
    verifyEq(CompletionItem.classKind,     7)
    verifyEq(CompletionItem.keyword,       14)
    verifyEq(CompletionItem.enumMember,    20)
    verifyEq(CompletionItem.constant,      21)
  }

  Void testCompletionItemBasicToMap()
  {
    item := CompletionItem("myMethod", CompletionItem.method, "Int myMethod()")
    m := item.toMap
    verifyEq(m["label"], "myMethod")
    verifyEq(m["kind"], 2)
    verifyEq(m["detail"], "Int myMethod()")
    verifyFalse(m.containsKey("insertText"))
  }

  Void testCompletionItemWithSnippet()
  {
    item := CompletionItem("foo", CompletionItem.method, null, null, "foo(\$0)", 2)
    m := item.toMap
    verifyEq(m["insertText"], "foo(\$0)")
    verifyEq(m["insertTextFormat"], 2)
  }

  Void testCompletionItemDocumentationWrapped()
  {
    item := CompletionItem("Str", CompletionItem.classKind, null, "A string type")
    m := item.toMap
    docMap := m["documentation"] as [Str:Obj?]
    verifyNotNull(docMap)
    verifyEq(docMap["kind"], "markdown")
    verifyEq(docMap["value"], "A string type")
  }

  Void testCompletionItemNullFieldsOmitted()
  {
    item := CompletionItem("x", CompletionItem.variable)
    m := item.toMap
    verifyFalse(m.containsKey("detail"))
    verifyFalse(m.containsKey("documentation"))
    verifyFalse(m.containsKey("insertText"))
    verifyFalse(m.containsKey("insertTextFormat"))
  }

  // ── ParameterInformation ──────────────────────────────────────────────────────

  Void testParameterInformationToMap()
  {
    p := ParameterInformation("Int x", "the x value")
    m := p.toMap
    verifyEq(m["label"], "Int x")
    verifyEq(m["documentation"], "the x value")
  }

  Void testParameterInformationNullDocOmitted()
  {
    p := ParameterInformation("Str name")
    m := p.toMap
    verifyEq(m["label"], "Str name")
    verifyFalse(m.containsKey("documentation"))
  }

  // ── SignatureInformation ──────────────────────────────────────────────────────

  Void testSignatureInformationToMap()
  {
    params := [ParameterInformation("Int x"), ParameterInformation("Str y")]
    sig := SignatureInformation("Void foo(Int x, Str y)", null, params)
    m := sig.toMap
    verifyEq(m["label"], "Void foo(Int x, Str y)")
    paramList := m["parameters"] as List
    verifyNotNull(paramList)
    verifyEq(paramList.size, 2)
  }

  Void testSignatureInformationWithDoc()
  {
    sig := SignatureInformation("Int add(Int a, Int b)", "Adds two numbers")
    m := sig.toMap
    docMap := m["documentation"] as [Str:Obj?]
    verifyNotNull(docMap)
    verifyEq(docMap["kind"], "markdown")
    verifyEq(docMap["value"], "Adds two numbers")
  }

  Void testSignatureInformationEmptyParams()
  {
    sig := SignatureInformation("Void run()")
    m := sig.toMap
    paramList := m["parameters"] as List
    verifyEq(paramList.size, 0)
  }

  // ── TextEdit ──────────────────────────────────────────────────────────────────

  Void testTextEditToMap()
  {
    edit := TextEdit(LspRange(Position(0, 0), Position(0, 5)), "hello")
    m := edit.toMap
    verifyEq(m["newText"], "hello")
    verifyNotNull(m["range"])
  }

  // ── WorkspaceEdit ─────────────────────────────────────────────────────────────

  Void testWorkspaceEditToMap()
  {
    edit := TextEdit(LspRange(Position(0, 0), Position(0, 5)), "newName")
    ws := WorkspaceEdit(["file:///foo.fan": [edit]])
    m := ws.toMap
    changes := m["changes"] as [Str:Obj?]
    verifyNotNull(changes)
    edits := changes["file:///foo.fan"] as List
    verifyNotNull(edits)
    verifyEq(edits.size, 1)
  }

  // ── DocumentSymbol ────────────────────────────────────────────────────────────

  Void testDocumentSymbolKindConstants()
  {
    verifyEq(DocumentSymbol.classKind,     5)
    verifyEq(DocumentSymbol.methodKind,    6)
    verifyEq(DocumentSymbol.fieldKind,     8)
    verifyEq(DocumentSymbol.constructor,   9)
    verifyEq(DocumentSymbol.enumKind,      10)
    verifyEq(DocumentSymbol.interfaceKind, 11)
    verifyEq(DocumentSymbol.enumMember,    22)
  }

  Void testDocumentSymbolToMap()
  {
    r := LspRange(Position(0, 0), Position(5, 0))
    sr := LspRange(Position(0, 6), Position(0, 9))
    sym := DocumentSymbol("Foo", DocumentSymbol.classKind, r, sr)
    m := sym.toMap
    verifyEq(m["name"], "Foo")
    verifyEq(m["kind"], DocumentSymbol.classKind)
    verifyNotNull(m["range"])
    verifyNotNull(m["selectionRange"])
    verifyFalse(m.containsKey("children"))
  }

  Void testDocumentSymbolWithChildren()
  {
    r := LspRange(Position(0, 0), Position(10, 0))
    sr := LspRange(Position(0, 6), Position(0, 9))
    cr := LspRange(Position(1, 0), Position(1, 20))
    csr := LspRange(Position(1, 4), Position(1, 7))
    child := DocumentSymbol("bar", DocumentSymbol.methodKind, cr, csr)
    sym := DocumentSymbol("Foo", DocumentSymbol.classKind, r, sr, null, [child])
    m := sym.toMap
    children := m["children"] as List
    verifyNotNull(children)
    verifyEq(children.size, 1)
  }
}
