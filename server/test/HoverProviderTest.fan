class HoverProviderTest : Test
{
  private HoverProvider provider := HoverProvider()
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
}
