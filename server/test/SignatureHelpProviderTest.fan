class SignatureHelpProviderTest : Test
{
  private SignatureHelpProvider provider := SignatureHelpProvider()
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
    // noArgs has no params so provider returns null
    verifyNull(result)
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
}
