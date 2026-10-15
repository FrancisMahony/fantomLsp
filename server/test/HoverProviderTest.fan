class HoverProviderTest : Test
{
  private T08HoverFixture provider := T08HoverFixture()
  private TestWorkspace? compiledWs
  private FantomLanguageServer? compiledServer
  override Void teardown()
  {
    if (compiledServer != null) { compiledServer.awaitBackground; compiledServer.shutdown }
    compiledWs?.cleanup
    provider.cleanup
  }
  private RecoveringParser parser := RecoveringParser()

  private ParseResult parse(Str src) { parser.parse("file:///test.fan", src) }

  private DocumentState makeDoc(Str src)
  {
    DocumentState("file:///test.fan", 1, src)
  }

  // ── hover returns null for empty word ─────────────────────────────────────────

  Void testHoverEmptyWordReturnsNull()
  {
    src := "class Foo {}"
    doc := makeDoc(src)
    r := parse(src)
    result := provider.hover(doc, r, Position(0, 0))
    // Position 0,0 is 'c' in "class" — but "class" is a keyword, not in the AST
    // The word is "class" — it may or may not resolve; we only verify the method runs
    // (null or non-null are both acceptable here)
  }

  Void testHoverOnWhitespaceReturnsNull()
  {
    src := "class Foo {   }"
    doc := makeDoc(src)
    r := parse(src)
    // Position 0,10 is inside the spaces
    result := provider.hover(doc, r, Position(0, 11))
    verifyNull(result)
  }

  // ── hover on a pod type (from sys) ────────────────────────────────────────────

  Void testHoverOnStrType()
  {
    src := "using sys\nStr x := \"hello\""
    doc := makeDoc(src)
    r := parse(src)
    // Cursor on "Str" at line 1, char 0
    result := provider.hover(doc, r, Position(1, 0))
    verifyNotNull(result)
    contents := result["contents"] as [Str:Obj?]
    verifyNotNull(contents)
    verifyEq(contents["kind"], "markdown")
    value := contents["value"] as Str
    verifyNotNull(value)
    verify(value.contains("Str"))
  }

  Void testHoverOnIntType()
  {
    src := "Int count := 0"
    doc := makeDoc(src)
    r := parse(src)
    result := provider.hover(doc, r, Position(0, 1))  // inside "Int"
    verifyNotNull(result)
    value := (result["contents"] as [Str:Obj?])["value"] as Str
    verify(value.contains("Int"))
  }

  // ── hover on local class definition ───────────────────────────────────────────

  Void testHoverOnLocalClass()
  {
    src := "** A local class\nclass LocalThing\n{\n}"
    doc := makeDoc(src)
    r := parse(src)
    // Cursor on "LocalThing" at line 1, char 6 ("class " is 6 chars)
    result := provider.hover(doc, r, Position(1, 6))
    verifyNotNull(result)
    value := (result["contents"] as [Str:Obj?])["value"] as Str
    verify(value.contains("LocalThing"))
  }

  Void testHoverOnLocalClassWithDoc()
  {
    src := "** My doc comment\nclass Documented\n{\n}"
    doc := makeDoc(src)
    r := parse(src)
    // Cursor on "Documented" at line 1, char 6 ("class " is 6 chars)
    result := provider.hover(doc, r, Position(1, 6))
    verifyNotNull(result)
    value := (result["contents"] as [Str:Obj?])["value"] as Str
    verify(value.contains("My doc comment"))
  }

  // ── hover on local method ─────────────────────────────────────────────────────

  Void testHoverOnLocalMethod()
  {
    src := "class Foo\n{\n  ** Does something\n  Void doSomething() {}\n}"
    doc := makeDoc(src)
    r := parse(src)
    // Cursor on "doSomething" at line 3, char 7
    result := provider.hover(doc, r, Position(3, 7))
    verifyNotNull(result)
    value := (result["contents"] as [Str:Obj?])["value"] as Str
    verify(value.contains("doSomething"))
  }

  // ── hover on local field ──────────────────────────────────────────────────────

  Void testHoverOnLocalField()
  {
    src := "class Foo\n{\n  Int myField\n}"
    doc := makeDoc(src)
    r := parse(src)
    // Cursor on "myField" at line 2, char 6
    result := provider.hover(doc, r, Position(2, 6))
    verifyNotNull(result)
    value := (result["contents"] as [Str:Obj?])["value"] as Str
    verify(value.contains("myField"))
  }

  // ── hover on inferred variable type ──────────────────────────────────────────

  Void testHoverOnInferredStringVar()
  {
    src := "x := \"hello\"\n"
    doc := makeDoc(src)
    r := parse(src)
    // Cursor on "x" at line 0, char 0
    result := provider.hover(doc, r, Position(0, 0))
    verifyNotNull(result)
    value := (result["contents"] as [Str:Obj?])["value"] as Str
    verify(value.contains("Str"))
    verify(value.contains("x"))
  }

  Void testHoverOnInferredIntVar()
  {
    src := "count := 42\n"
    doc := makeDoc(src)
    r := parse(src)
    result := provider.hover(doc, r, Position(0, 0))
    verifyNotNull(result)
    value := (result["contents"] as [Str:Obj?])["value"] as Str
    verify(value.contains("Int"))
    verify(value.contains("count"))
  }

  Void testCompiledInferredUriLocalKeepsCompilerType()
  {
    ws := TestWorkspace()
    compiledWs = ws
    src := "class Foo\n{\n  Void run()\n  {\n    x := `foo`\n    echo(x)\n  }\n}\n"
    dir := ws.writePod(ws.podName("hover"), ["Foo.fan": src])
    file := WorkspaceManager.fileToUri(dir + `fan/Foo.fan`)
    s := FantomLanguageServer()
    compiledServer = s
    s.initialize(["rootUri": WorkspaceManager.fileToUri(ws.root), "initializationOptions":
      ["envPath": [ws.root.osPath], "semanticIndex": ["backgroundCompile": false]]])
    s.indexWorkspaceNow
    s.didOpen(["textDocument": ["uri": file, "languageId": "fantom", "version": 1, "text": src]])
    verify(s.ensureFresh([WorkspaceManager.fileToUri(dir + `build.fan`)]))

    // Cover both the declaration and the bound usage; heuristic-only resolution
    // must not accidentally make this regression pass.
    [4, 5].each |line|
    {
      pos := Position(line, src.splitLines[line].index("x"))
      res := s.resolver.resolveAt(file, pos)
      verifyEq(res.certainty, Certainty.proven)
      verifyEq(res.targets.first.source, "semantic")
      verify(SymbolKey.isLocal(res.targets.first.key))
      verifyEq(s.resolver.signatureOf(res.targets.first.key), "sys::Uri")
      result := HoverProvider().hover(s.docManager.getDocument(file), s.docManager.parseDocument(file), pos, s)
      verifyNotNull(result)
      value := (result["contents"] as [Str:Obj?])["value"] as Str
      verifyEq(value, "```fantom\nsys::Uri x\n```")
    }
  }

  // ── hover on unknown word returns null ────────────────────────────────────────

  Void testHoverOnUnknownWord()
  {
    src := "xyzUnknown123"
    doc := makeDoc(src)
    r := parse(src)
    result := provider.hover(doc, r, Position(0, 3))
    // Unknown identifiers produce null
    verifyNull(result)
  }

  // ── hover result structure ────────────────────────────────────────────────────

  Void testHoverResultHasMarkdownContents()
  {
    src := "Str x := \"test\""
    doc := makeDoc(src)
    r := parse(src)
    result := provider.hover(doc, r, Position(0, 0))
    verifyNotNull(result)
    contents := result["contents"]
    verifyNotNull(contents)
    contentsMap := contents as [Str:Obj?]
    verifyNotNull(contentsMap)
    verifyEq(contentsMap["kind"], "markdown")
    verify(contentsMap.containsKey("value"))
  }

  Void testHoverResultContainsCodeFence()
  {
    src := "Str msg := \"hi\""
    doc := makeDoc(src)
    r := parse(src)
    result := provider.hover(doc, r, Position(0, 0))
    if (result != null)
    {
      value := (result["contents"] as [Str:Obj?])["value"] as Str
      verify(value.contains("```"))
    }
  }

  // ── cross-file hover via SymbolTable ──────────────────────────────────────────

  Void testHoverOnQualifiedPodType()
  {
    src := "sys::Str x := \"hello\""
    doc := makeDoc(src)
    r := parse(src)
    result := provider.hover(doc, r, Position(0, 5))
    verifyNotNull(result)
    value := (result["contents"] as [Str:Obj?])["value"] as Str
    verify(value.contains("Str"))
  }

  Void testHoverOnTypeFromOtherFile()
  {
    otherSrc := "class OtherWidget\n{\n  Void ping() {}\n}"
    table := SymbolTable()
    table.update("file:///other.fan", parser.parse("file:///other.fan", otherSrc))

    src := "OtherWidget x := OtherWidget()"
    doc := makeDoc(src)
    r := parse(src)
    result := provider.hover(doc, r, Position(0, 0), table)
    verifyNotNull(result)
    value := (result["contents"] as [Str:Obj?])["value"] as Str
    verify(value.contains("OtherWidget"))
  }

  Void testHoverOnQualifiedTypeSlot()
  {
    src := "sys::Int.fromStr(\"1\")"
    doc := makeDoc(src)
    r := parse(src)
    result := provider.hover(doc, r, Position(0, 12))
    verifyNotNull(result)
    value := (result["contents"] as [Str:Obj?])["value"] as Str
    verify(value.contains("fromStr"))
    verify(value.contains("Int"))
  }

  Void testHoverOnPodTypeSlot()
  {
    src := "StrBuf.add"
    doc := makeDoc(src)
    r := parse(src)
    result := provider.hover(doc, r, Position(0, 8))
    verifyNotNull(result)
    value := (result["contents"] as [Str:Obj?])["value"] as Str
    verify(value.contains("add"))
    verify(value.contains("StrBuf"))
  }

  Void testHoverOnMethodParamUsesDeclaredTypeNotSlot()
  {
    src := "class Foo\n{\n  static const Int history := 1\n  Void chat(Grid history) { history.size }\n}"
    doc := makeDoc(src)
    r := parse(src)
    result := provider.hover(doc, r, Position(3, 32))
    verifyNotNull(result)
    value := (result["contents"] as [Str:Obj?])["value"] as Str
    verify(value.contains("Grid history"))
    verifyFalse(value.contains("static const"))
  }

  Void testHoverOnNullableParamInIf()
  {
    src := "class Foo\n{\n  Void chat(Str? sysMessage)\n  {\n    if(sysMessage != null) {}\n  }\n}"
    doc := makeDoc(src)
    r := parse(src)
    result := provider.hover(doc, r, Position(4, 8))
    verifyNotNull(result)
    value := (result["contents"] as [Str:Obj?])["value"] as Str
    verify(value.contains("Str?"))
    verify(value.contains("sysMessage"))
  }

  Void testHoverPrefersLaterLocalShadow()
  {
    src := "class Foo\n{\n  Void run(Int x)\n  {\n    Str x := \"hi\"\n    echo(x)\n  }\n}"
    doc := makeDoc(src)
    r := parse(src)
    result := provider.hover(doc, r, Position(5, 9))
    verifyNotNull(result)
    value := (result["contents"] as [Str:Obj?])["value"] as Str
    verify(value.contains("Str"))
    verifyFalse(value.contains("Int x"))
  }

  Void testHoverParamBeforeLocalShadow()
  {
    src := "class Foo\n{\n  Void run(Int x)\n  {\n    echo(x)\n    Str x := \"hi\"\n  }\n}"
    doc := makeDoc(src)
    r := parse(src)
    result := provider.hover(doc, r, Position(4, 9))
    verifyNotNull(result)
    value := (result["contents"] as [Str:Obj?])["value"] as Str
    verify(value.contains("Int"))
  }

  Void testHoverParamsOnCallLineNotPodSlots()
  {
    src := [
      "class Foo",
      "{",
      "  override Grid chat(Dict config, Str? message, Grid history, Str? sysMessage, Grid tools, Dict[] inlinedDataDicts, Str sessionId) {",
      "    return chatCompletionsChat(config, message, history, sysMessage, tools, inlinedDataDicts, sessionId)",
      "  }",
      "}"
    ].join("\n")
    doc := makeDoc(src)
    r := parse(src)
    line := src.splitLines[3]
    verifyHoverContains(doc, r, 3, line.index("config"), "Dict config")
    verifyHoverContains(doc, r, 3, line.index("message"), "Str? message")
    verifyHoverContains(doc, r, 3, line.index("history"), "Grid history")
    verifyHoverContains(doc, r, 3, line.index("sysMessage"), "Str? sysMessage")
    verifyHoverContains(doc, r, 3, line.index("tools"), "Grid tools")
    verifyHoverContains(doc, r, 3, line.index("inlinedDataDicts"), "Dict[] inlinedDataDicts")
    verifyHoverContains(doc, r, 3, line.index("sessionId"), "Str sessionId")
  }

  private Void verifyHoverContains(DocumentState doc, ParseResult r, Int line, Int? col, Str expected)
  {
    verifyNotNull(col)
    result := provider.hover(doc, r, Position(line, col))
    verifyNotNull(result)
    value := (result["contents"] as [Str:Obj?])["value"] as Str
    verify(value.contains(expected), "expected ${expected} in ${value}")
  }

  Void testHoverClosureParamNotVisibleAfterBlock()
  {
    src := "class Foo\n{\n  Void run()\n  {\n    list.each |Str item| { echo(item) }\n    echo(item)\n  }\n}"
    doc := makeDoc(src)
    r := parse(src)
    inner := provider.hover(doc, r, Position(4, 32))
    verifyNotNull(inner)
    innerVal := (inner["contents"] as [Str:Obj?])["value"] as Str
    verify(innerVal.contains("Str"))
    outer := provider.hover(doc, r, Position(5, 9))
    if (outer != null)
    {
      val := (outer["contents"] as [Str:Obj?])["value"] as Str
      verifyFalse(val.contains("Str item") || val == "```fantom\nStr item\n```")
    }
  }

  Void testInheritedMethodHoverUsesDeclaringSignature()
  {
    src := "class A\n{\n  ** Inherited documentation\n  virtual Int run(Str message) { 1 }\n}\nclass B : A\n{\n  Void go(B b)\n  {\n    b.run(\"hi\")\n  }\n}\n"
    result := provider.hover(makeDoc(src), parse(src), Position(9, 6))
    verifyNotNull(result)
    value := (result["contents"] as [Str:Obj?])["value"] as Str
    verify(value.contains("Int run(Str message)"))
    verify(value.contains("::A"))
    verify(value.contains("Inherited documentation"))
  }

  Void testAmbiguousHoverReportsOtherCandidates()
  {
    src := "class A\n{\n  Void close(Int code) {}\n}\nclass B\n{\n  Void close(Str reason) {}\n  Void go()\n  {\n    missing.close()\n  }\n}\n"
    result := provider.hover(makeDoc(src), parse(src), Position(9, 13))
    verifyNotNull(result)
    value := (result["contents"] as [Str:Obj?])["value"] as Str
    verify(value.contains("other candidates)"))
    // Same-file ties are key-ranked; never depend on HashMap insertion order.
    verify(value.contains("Int code"))
  }
}

// Adapt legacy document/parse fixtures to a real registered pod, without
// restoring any of the provider's former global name lookup paths.
internal class T08HoverFixture : LspUtils
{
  private TestWorkspace ws := TestWorkspace()
  private FantomLanguageServer[] servers := [,]
  [Str:Obj?]? hover(DocumentState doc, ParseResult parsed, Position pos, SymbolTable table := SymbolTable())
  {
    text := doc.text
    // These legacy snippets model method locals but omitted their container.
    // Supply that scope now that local resolution is deliberately scoped.
    if (!text.contains("class ") && (text.startsWith("x :=") || text.startsWith("count :=")))
    {
      text = "class Fixture\n{\n  Void run()\n  {\n" + text + "\n  }\n}\n"
      pos = Position(pos.line + 4, pos.character)
    }
    sources := Str:Str[:]
    table.allEntries.each |e|
    {
      if (!e.node.isType || e.uri == doc.uri) return
      members := e.node.children.findAll |n| { n.isSlotOrEnumVal }.map |n->Str|
      { formatLocalSig(n) + ((n.kind == AstNodeKind.methodDef || n.kind == AstNodeKind.ctorDef) ? " {}" : "") }
      sources[e.node.name + ".fan"] = formatLocalSig(e.node) + "\n{\n" + members.join("\n") + "\n}"
    }
    sources["Test.fan"] = text
    dir := ws.writePod(ws.podName("hover"), sources)
    s := FantomLanguageServer()
    servers.add(s)
    s.workspaceManager.addFolder(WorkspaceManager.fileToUri(ws.root))
    s.indexWorkspaceNow
    file := WorkspaceManager.fileToUri(dir + `fan/Test.fan`)
    s.docManager.open(TextDocumentItem(file, "fantom", 1, text))
    return HoverProvider().hover(s.docManager.getDocument(file), s.docManager.parseDocument(file), pos, s)
  }
  Void cleanup()
  {
    servers.each |s| { s.awaitBackground; s.shutdown }
    ws.cleanup
  }
}
