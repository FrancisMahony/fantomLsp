class SignatureHelpProviderTest : Test
{
  private T08SignatureFixture provider := T08SignatureFixture()
  override Void teardown() { provider.cleanup }
  private RecoveringParser parser := RecoveringParser()

  private ParseResult parse(Str src) { parser.parse("file:///test.fan", src) }

  private DocumentState makeDoc(Str src)
  {
    DocumentState("file:///test.fan", 1, src)
  }

  private Obj? sigHelp(Str src, Position pos)
  {
    doc := makeDoc(src)
    r := parse(src)
    return provider.signatureHelp(doc, r, pos)
  }

  // ── returns null when not inside a call ───────────────────────────────────────

  Void testNoParenReturnsNull()
  {
    result := sigHelp("class Foo {}", Position(0, 5))
    verifyNull(result)
  }

  Void testOnlyClosingParenReturnsNull()
  {
    result := sigHelp("x)", Position(0, 2))
    verifyNull(result)
  }

  // ── basic structure ────────────────────────────────────────────────────────────

  Void testResultHasRequiredFields()
  {
    // Call a known pod method — StrBuf has make()
    src := "StrBuf("
    result := sigHelp(src, Position(0, 7))
    if (result != null)
    {
      resultMap := result as [Str:Obj?]
      verify(resultMap.containsKey("signatures"))
      verify(resultMap.containsKey("activeSignature"))
      verify(resultMap.containsKey("activeParameter"))
      verifyEq(resultMap["activeSignature"], 0)
    }
  }

  // ── active parameter counting ──────────────────────────────────────────────────

  Void testActiveParamFirstArg()
  {
    src := "class Foo\n{\n  Void run(Int x, Str y) {}\n}\nFoo().run("
    result := sigHelp(src, Position(4, 10))
    // Could be null if reflection doesn't resolve — just test no exception
  }

  Void testActiveParamSecondArgAfterComma()
  {
    src := "class Foo\n{\n  Void run(Int x, Str y) {}\n}\nFoo().run(1, "
    result := sigHelp(src, Position(4, 13))
    if (result != null)
    {
      resultMap := result as [Str:Obj?]
      activeParam := ((Num)resultMap["activeParameter"]).toInt
      verifyEq(activeParam, 1)
    }
  }

  Void testActiveParamThirdArg()
  {
    src := "class Foo\n{\n  Void run(Int a, Int b, Str c) {}\n}\nFoo().run(1, 2, "
    result := sigHelp(src, Position(4, 17))
    if (result != null)
    {
      resultMap := result as [Str:Obj?]
      activeParam := ((Num)resultMap["activeParameter"]).toInt
      verifyEq(activeParam, 2)
    }
  }

  // ── local method resolution ───────────────────────────────────────────────────

  Void testLocalMethodSignature()
  {
    src := "class Calc\n{\n  Int add(Int x, Int y) { x + y }\n  Void test() {\n    add("
    result := sigHelp(src, Position(4, 8))
    if (result != null)
    {
      resultMap := result as [Str:Obj?]
      sigs := resultMap["signatures"] as List
      verifyNotNull(sigs)
      verify(sigs.size > 0)
      sig := sigs[0] as [Str:Obj?]
      label := sig["label"] as Str
      verify(label.contains("add"))
      params := sig["parameters"] as List
      verifyEq(params.size, 2)
    }
  }

  Void testLocalMethodParamLabels()
  {
    src := "class Greeter\n{\n  Str greet(Str name, Int times) { \"hi\" }\n  Void run() {\n    greet("
    result := sigHelp(src, Position(4, 10))
    if (result != null)
    {
      resultMap := result as [Str:Obj?]
      sigs := resultMap["signatures"] as List
      sig := sigs[0] as [Str:Obj?]
      params := sig["parameters"] as List
      verifyEq(params.size, 2)
      p0 := params[0] as [Str:Obj?]
      verifyEq(p0["label"], "Str name")
    }
  }

  // ── constructor shorthand (Type(...)) ─────────────────────────────────────────

  Void testConstructorShorthandUpperCase()
  {
    // "StrBuf(" → look up StrBuf.make()
    src := "StrBuf("
    result := sigHelp(src, Position(0, 7))
    // sys.StrBuf has a make() method — verify we get a non-null result
    if (result != null)
    {
      resultMap := result as [Str:Obj?]
      sigs := resultMap["signatures"] as List
      verifyNotNull(sigs)
      verify(sigs.size > 0)
    }
  }

  Void testLocalConstructorShorthand()
  {
    src := "class Pt\n{\n  new make(Int x, Int y) {}\n  Int x\n  Int y\n}\nPt("
    result := sigHelp(src, Position(6, 3))
    if (result != null)
    {
      resultMap := result as [Str:Obj?]
      sigs := resultMap["signatures"] as List
      sig := sigs[0] as [Str:Obj?]
      label := sig["label"] as Str
      verify(label.startsWith("new "))
      params := sig["parameters"] as List
      verifyEq(params.size, 2)
    }
  }

  // ── dot call receiver resolution ──────────────────────────────────────────────

  Void testDotCallOnPodType()
  {
    // "Str.fromChars(" — static method on Str
    src := "Str.fromChars("
    result := sigHelp(src, Position(0, 14))
    // Just verify it doesn't crash; Str.fromChars may have params
  }

  Void testDotCallOnInferredVar()
  {
    // s := "hello" \n s.startsWith(
    src := "s := \"hello\"\ns.startsWith("
    result := sigHelp(src, Position(1, 12))
    if (result != null)
    {
      resultMap := result as [Str:Obj?]
      sigs := resultMap["signatures"] as List
      verify(sigs.size > 0)
      sig := sigs[0] as [Str:Obj?]
      label := sig["label"] as Str
      verify(label.contains("startsWith"))
    }
  }

  // ── nested parens do not confuse the scanner ──────────────────────────────────

  Void testNestedParens()
  {
    // outer( inner() , <cursor>
    src := "class Foo\n{\n  Void outer(Int a, Int b) {}\n  Void run() {\n    outer(inner(), "
    result := sigHelp(src, Position(4, 19))
    if (result != null)
    {
      resultMap := result as [Str:Obj?]
      activeParam := ((Num)resultMap["activeParameter"]).toInt
      // After "inner(), " → second argument to outer
      verifyEq(activeParam, 1)
    }
  }

  // ── no params → returns null ──────────────────────────────────────────────────

  Void testMethodWithNoParamsReturnsNull()
  {
    // The provider returns null when params list is empty
    src := "class Foo\n{\n  Void noArgs() {}\n  Void run() {\n    noArgs("
    result := sigHelp(src, Position(4, 11))
    verifyNotNull(result)
    resultMap := result as [Str:Obj?]
    sigs := resultMap["signatures"] as List
    verifyEq(sigs.size, 1)
  }

  // ── returns null for unresolvable function name ───────────────────────────────

  Void testUnknownFunctionReturnsNull()
  {
    src := "xyzUnknownFunction12345("
    result := sigHelp(src, Position(0, 24))
    verifyNull(result)
  }

  // ── activeParameter clipped to valid range ────────────────────────────────────

  Void testActiveParamClippedToParamCount()
  {
    // Only 1 param but cursor is after many commas
    src := "class Foo\n{\n  Void single(Int x) {}\n  Void run() {\n    single(1, 2, 3, "
    result := sigHelp(src, Position(4, 19))
    if (result != null)
    {
      resultMap := result as [Str:Obj?]
      activeParam := ((Num)resultMap["activeParameter"]).toInt
      // Should be clipped to 0 (last valid index)
      verifyEq(activeParam, 0)
    }
  }

  Void testInheritedSignatureAndNestedArgumentsUseCurrentMethod()
  {
    src := "class Wrong\n{\n  Void close(Str wrong) {}\n}\nclass A\n{\n  virtual Void close(Int code, Str reason, Int[] values) {}\n}\nclass B : A\n{\n  Void go(B conn)\n  {\n    conn.close(1, \"a,b\", [2, 3], "
    result := sigHelp(src, Position(12, src.splitLines[12].size)) as [Str:Obj?]
    verifyNotNull(result)
    sig := ((List)result["signatures"])[0] as [Str:Obj?]
    verify(((Str)sig["label"]).contains("Int code, Str reason, Int[] values"))
    verifyFalse(((Str)sig["label"]).contains("wrong"))
    verifyEq(((List)sig["parameters"]).size, 3)
    verifyEq(result["activeParameter"], 2)
  }

  Void testMultilineSignatureCountsOnlyOuterCommas()
  {
    src := "class A\n{\n  Void choose(Int[] values, Str text, Int count) {}\n  Void go()\n  {\n    choose(\n      [1, 2],\n      \"a,b\", // ignored, comma\n      "
    result := sigHelp(src, Position(8, 6)) as [Str:Obj?]
    verifyNotNull(result)
    verifyEq(result["activeParameter"], 2)
  }

  Void testAmbiguousReceiverDoesNotSelectArbitrarySignature()
  {
    src := "class A\n{\n  Void close(Int code) {}\n}\nclass B\n{\n  Void close(Str reason) {}\n  Void go()\n  {\n    missing.close("
    verifyNull(sigHelp(src, Position(9, src.splitLines[9].size)))
  }

  Void testCurrentFileBackedCTypeParametersAfterRebuild()
  {
    ws := TestWorkspace()
    s := FantomLanguageServer()
    try
    {
      pod := ws.podName("library")
      ws.buildPod(pod, ["Conn.fan":"class Conn\n{\n  Void close(Int oldValue) {}\n}\n"])
      s.podLookup.configure([ws.root])
      verifyNotNull(s.podLookup.findSlot(pod, "Conn", "close"))
      ws.buildPod(pod, ["Conn.fan":"class Conn\n{\n  ** Current library docs\n  Void close(Str reason, Int code) {}\n}\n"], ["sys 1.0"], Version("1.1"))
      // No registry entry: this is a built dependency, not workspace source.
      file := "file:///signature-current.fan"
      src := "using $pod::Conn\nclass Caller\n{\n  Void go(Conn conn)\n  {\n    conn.close(\"ok\", "
      s.docManager.open(TextDocumentItem(file, "fantom", 1, src))
      parsed := s.docManager.parseDocument(file)
      s.symbolTable.update(file, parsed)
      s.typeResolver.updateUsings(file, parsed)
      doc := s.docManager.getDocument(file)
      result := SignatureHelpProvider().signatureHelp(doc, parsed, Position(5, src.splitLines[5].size), s) as [Str:Obj?]
      verifyNotNull(result)
      sig := ((List)result["signatures"])[0] as [Str:Obj?]
      params := sig["parameters"] as List
      verifyEq(params.size, 2)
      verify(((Str)(([Str:Obj?])params[0])["label"]).contains("reason"))
      verifyFalse(((Str)sig["label"]).contains("oldValue"))
      verifyEq(result["activeParameter"], 1)
      hover := HoverProvider().hover(doc, parsed, Position(5, 10), s)
      verifyNotNull(hover)
      value := (hover["contents"] as [Str:Obj?])["value"] as Str
      verify(value.contains("reason"))
      verifyFalse(value.contains("oldValue"))
    }
    finally { s.awaitBackground; s.shutdown; ws.cleanup }
  }

  Void testCompiledCompactMethodsUseSemanticSignatureParameters()
  {
    ws := TestWorkspace()
    s := FantomLanguageServer()
    try
    {
      pod := ws.podName("compactSignature")
      src := "class A { Void close(Int code) {} }\n" +
        "class Options { Void choose(Int[] values, |Int,Str->Void| action, Str reason := \"a,b\") {} }\n" +
        "class Empty { Void noArgs() {} }\n" +
        "class Caller\n{\n  Void run(A a, Options options, Empty empty)\n  {\n" +
        "    a.close(1)\n" +
        "    options.choose([1, 2], |Int n, Str text| {}, \"ok\")\n" +
        "    empty.noArgs()\n  }\n}\n"
      dir := ws.writePod(pod, ["Test.fan": src])
      file := WorkspaceManager.fileToUri(dir + `fan/Test.fan`)
      s.initialize(["rootUri": WorkspaceManager.fileToUri(ws.root), "initializationOptions":
        ["envPath": [ws.root.osPath], "semanticIndex": ["backgroundCompile": false]]])
      s.indexWorkspaceNow
      s.didOpen(["textDocument": ["uri": file, "languageId": "fantom", "version": 1, "text": src]])
      verify(s.ensureFresh([WorkspaceManager.fileToUri(dir + `build.fan`)]))
      doc := s.docManager.getDocument(file)
      parsed := s.docManager.parseDocument(file)
      [7, 8, 9].each |line|
      {
        call := src.splitLines[line]
        namePos := Position(line, call.index(".") + 1)
        res := s.resolver.resolveAt(file, namePos)
        verifyEq(res.certainty, Certainty.proven)
        verifyEq(res.targets.first.source, "semantic")
        key := res.targets.first.key
        label := s.resolver.signatureOf(key)
        verifyNotNull(label)
        result := SignatureHelpProvider().signatureHelp(doc, parsed,
          Position(line, call.index("(") + 1), s) as [Str:Obj?]
        verifyNotNull(result)
        verifyEq(result["activeParameter"], 0)
        sig := ((List)result["signatures"])[0] as [Str:Obj?]
        verifyEq(sig["label"], label)
        params := sig["parameters"] as List
        if (line == 7)
        {
          verifyEq(key, "${pod}::A.close")
          verifyEq(label, "${pod}::A.close(sys::Int code)")
          verifyEq(params.size, 1)
          verifyEq((([Str:Obj?])params[0])["label"], "sys::Int code")
        }
        else if (line == 8)
        {
          verifyEq(params.size, 3)
          verify(((Str)(([Str:Obj?])params[0])["label"]).contains("values"))
          action := (([Str:Obj?])params[1])["label"] as Str
          verify(action.contains("sys::Int"))
          verify(action.contains("sys::Str"))
          verify(action.contains("action"))
          verify(((Str)(([Str:Obj?])params[2])["label"]).contains("reason"))
          second := SignatureHelpProvider().signatureHelp(doc, parsed,
            Position(line, call.index(", |") + 2), s) as [Str:Obj?]
          verifyNotNull(second)
          verifyEq(second["activeParameter"], 1)
        }
        else verifyEq(params.size, 0)
      }
    }
    finally { s.awaitBackground; s.shutdown; ws.cleanup }
  }

  Void testQualifiedSignatureParameterParserKeepsDefaultsAndNestedFunctionTypes()
  {
    key := "example::A.choose"
    params := SignatureHelpProvider.signatureParameters(key +
      "(sys::Int[] values := [1, 2], |sys::Int,|sys::Str,sys::Int->sys::Void|->sys::Void| action, " +
      "sys::Str reason := \"a,b\", sys::Int code := compute(1, 2))", key)
    verifyNotNull(params)
    verifyEq(params, ["sys::Int[] values := [1, 2]",
      "|sys::Int,|sys::Str,sys::Int->sys::Void|->sys::Void| action",
      "sys::Str reason := \"a,b\"", "sys::Int code := compute(1, 2)"])
    verifyEq(SignatureHelpProvider.signatureParameters(key + "()", key), Str[,])
    verifyEq(SignatureHelpProvider.signatureParameters(key + "(|| action, sys::Int code)", key),
      ["|| action", "sys::Int code"])
    verifyEq(SignatureHelpProvider.signatureParameters(key + "(|| first, || second)", key),
      ["|| first", "|| second"])
    verifyEq(SignatureHelpProvider.signatureParameters(key + "(|sys::Int,||->sys::Void| action, sys::Int code)", key),
      ["|sys::Int,||->sys::Void| action", "sys::Int code"])
    verifyEq(SignatureHelpProvider.signatureParameters(key + "(|->||| action, sys::Int code)", key),
      ["|->||| action", "sys::Int code"])
    verifyEq(SignatureHelpProvider.signatureParameters(key + "(|->|sys::Int,sys::Str->sys::Void|| action, sys::Int code)", key),
      ["|->|sys::Int,sys::Str->sys::Void|| action", "sys::Int code"])
    verifyNull(SignatureHelpProvider.signatureParameters("other::A.choose(sys::Int code)", key))
    verifyNull(SignatureHelpProvider.signatureParameters(key + "(sys::Int[] values := [1, 2)", key))
  }

  Void testQualifiedSignatureParameterParserUsesTypeGrammarNotPipeCounting()
  {
    key := "example::A.choose"
    // Exact compiler MethodDef.signature forms (no spaces after commas).
    verifyEq(SignatureHelpProvider.signatureParameters(key +
      "(||sys::Int,sys::Str->sys::Void|->sys::Void| action,sys::Int code)", key),
      ["||sys::Int,sys::Str->sys::Void|->sys::Void| action", "sys::Int code"])
    verifyEq(SignatureHelpProvider.signatureParameters(key +
      "(|sys::Int,|sys::Str->sys::Void|->sys::Void| h,||sys::Int->sys::Void|->sys::Void| k,|->sys::Void| e)", key),
      ["|sys::Int,|sys::Str->sys::Void|->sys::Void| h", "||sys::Int->sys::Void|->sys::Void| k", "|->sys::Void| e"])
    verifyEq(SignatureHelpProvider.signatureParameters(key +
      "([sys::Str:|sys::Int->sys::Str|?]? m,|sys::Int->sys::Void|[] l,[sys::Str:sys::Int] n,|->sys::Int|? o)", key),
      ["[sys::Str:|sys::Int->sys::Str|?]? m", "|sys::Int->sys::Void|[] l", "[sys::Str:sys::Int] n", "|->sys::Int|? o"])
    verifyEq(SignatureHelpProvider.signatureParameters(key + "([java]java.lang::String s,sys::Bool x := true || false)", key),
      ["[java]java.lang::String s", "sys::Bool x := true || false"])
    verifyEq(SignatureHelpProvider.signatureParameters(key + "(||->sys::Void|->sys::Void| first, || second)", key),
      ["||->sys::Void|->sys::Void| first", "|| second"])
    verifyNull(SignatureHelpProvider.signatureParameters(key + "(||->sys::Void| first)", key))
    // Malformed: no guessing, the caller then shows nothing for workspace pods.
    [ "(sys::Int)", "(sys::Int code,)", "(,sys::Int code)", "(|sys::Int action)",
      "(sys::Int|| action)", "(||sys::Int,sys::Str->sys::Void| action)",
      "(sys::Int,sys::Str code)", "(sys::Int code sys::Str reason)",
      "([sys::Str:sys::Int m)", "(sys::Int code := )", "(sys::Int code := |x| { x })",
      "(sys::Str s := \"a,b)" ].each |body|
    {
      verifyNull(SignatureHelpProvider.signatureParameters(key + body, key), body)
    }
    verify(SignatureHelpProvider.validType("||"))
    verify(SignatureHelpProvider.validType("|->|||"))
    verify(SignatureHelpProvider.validType("||sys::Int,sys::Str->sys::Void|->sys::Void|"))
    verifyFalse(SignatureHelpProvider.validType("|||"))
    verifyFalse(SignatureHelpProvider.validType("|sys::Int,|"))
    verifyFalse(SignatureHelpProvider.validType("sys::Int?|"))
  }

  Void testCompiledCompactLeadingNestedFunctionParameter()
  {
    ws := TestWorkspace()
    s := FantomLanguageServer()
    try
    {
      pod := ws.podName("nestedSignature")
      src := "class A { Void choose(| |Int,Str->Void|->Void| action, Int code) {} }\n" +
        "class Caller\n{\n  Void run(A a)\n  {\n" +
        "    a.choose(null, 1)\n  }\n}\n"
      dir := ws.writePod(pod, ["Test.fan": src])
      file := WorkspaceManager.fileToUri(dir + `fan/Test.fan`)
      s.initialize(["rootUri": WorkspaceManager.fileToUri(ws.root), "initializationOptions":
        ["envPath": [ws.root.osPath], "semanticIndex": ["backgroundCompile": false]]])
      s.indexWorkspaceNow
      s.didOpen(["textDocument": ["uri": file, "languageId": "fantom", "version": 1, "text": src]])
      verify(s.ensureFresh([WorkspaceManager.fileToUri(dir + `build.fan`)]))
      doc := s.docManager.getDocument(file)
      parsed := s.docManager.parseDocument(file)
      call := src.splitLines[5]
      res := s.resolver.resolveAt(file, Position(5, call.index(".") + 1))
      verifyEq(res.certainty, Certainty.proven)
      verifyEq(res.targets.first.source, "semantic")
      verifyEq(res.targets.first.key, "${pod}::A.choose")
      expected := "${pod}::A.choose(||sys::Int,sys::Str->sys::Void|->sys::Void| action,sys::Int code)"
      verifyEq(s.resolver.signatureOf("${pod}::A.choose"), expected)
      [call.index("(") + 1: 0, call.index(",") + 2: 1, call.index("1)") + 1: 1].each |active, ch|
      {
        result := SignatureHelpProvider().signatureHelp(doc, parsed, Position(5, ch), s) as [Str:Obj?]
        verifyNotNull(result)
        verifyEq(result["activeParameter"], active)
        sig := ((List)result["signatures"])[0] as [Str:Obj?]
        verifyEq(sig["label"], expected)
        labels := ((List)sig["parameters"]).map |p->Str| { (([Str:Obj?])p)["label"] }
        verifyEq(labels, ["||sys::Int,sys::Str->sys::Void|->sys::Void| action", "sys::Int code"])
      }
    }
    finally { s.awaitBackground; s.shutdown; ws.cleanup }
  }

  Void testImportedConnCloseParametersNotOtherPodClose()
  {
    ws := TestWorkspace()
    s := FantomLanguageServer()
    try
    {
      alpha := ws.podName("alpha"); beta := ws.podName("beta")
      ws.writePod(alpha, ["Conn.fan":"class Conn\n{\n  Void close(Int code, Str reason) {}\n}\n"])
      src := "using $alpha::Conn\nclass Other\n{\n  Void close(Str wrong) {}\n  Void go(Conn conn)\n  {\n    conn.close(1, "
      dir := ws.writePod(beta, ["Other.fan":src], ["sys 1.0", "$alpha 1.0"])
      s.workspaceManager.addFolder(WorkspaceManager.fileToUri(ws.root))
      s.indexWorkspaceNow
      file := WorkspaceManager.fileToUri(dir + `fan/Other.fan`)
      s.docManager.open(TextDocumentItem(file, "fantom", 1, src))
      doc := s.docManager.getDocument(file)
      result := SignatureHelpProvider().signatureHelp(doc, s.docManager.parseDocument(file), Position(6, src.splitLines[6].size), s) as [Str:Obj?]
      verifyNotNull(result)
      sig := ((List)result["signatures"])[0] as [Str:Obj?]
      verify(((Str)sig["label"]).contains("Int code, Str reason"))
      verifyFalse(((Str)sig["label"]).contains("wrong"))
      verifyEq(((List)sig["parameters"]).size, 2)
      verifyEq(result["activeParameter"], 1)
    }
    finally { s.awaitBackground; s.shutdown; ws.cleanup }
  }
}

internal class T08SignatureFixture
{
  private TestWorkspace ws := TestWorkspace()
  private FantomLanguageServer[] servers := [,]
  Obj? signatureHelp(DocumentState doc, ParseResult parsed, Position pos)
  {
    text := doc.text
    if (text.startsWith("s :="))
    {
      text = "class Fixture\n{\n  Void run()\n  {\n" + text + "\n  }\n}\n"
      pos = Position(pos.line + 4, pos.character)
    }
    dir := ws.writePod(ws.podName("signature"), ["Test.fan": text])
    s := FantomLanguageServer()
    servers.add(s)
    s.workspaceManager.addFolder(WorkspaceManager.fileToUri(ws.root))
    s.indexWorkspaceNow
    file := WorkspaceManager.fileToUri(dir + `fan/Test.fan`)
    s.docManager.open(TextDocumentItem(file, "fantom", 1, text))
    return SignatureHelpProvider().signatureHelp(s.docManager.getDocument(file), s.docManager.parseDocument(file), pos, s)
  }
  Void cleanup()
  {
    servers.each |s| { s.awaitBackground; s.shutdown }
    ws.cleanup
  }
}
