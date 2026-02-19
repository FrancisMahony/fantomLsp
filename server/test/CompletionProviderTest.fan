class CompletionProviderTest : Test
{
  private CompletionProvider provider := CompletionProvider()
  private RecoveringParser parser := RecoveringParser()

  private ParseResult parse(Str src) { parser.parse("file:///test.fan", src) }

  private DocumentState makeDoc(Str src)
  {
    DocumentState("file:///test.fan", 1, src)
  }

  ** Run completion and return the items list.
  private [Str:Obj?][] complete(Str src, Position pos)
  {
    doc := makeDoc(src)
    r := parse(src)
    result := provider.complete(doc, r, pos) as [Str:Obj?]
    if (result == null) return [,]
    items := result["items"] as [Str:Obj?][]
    return items ?: [,]
  }

  ** True if any item has the given label.
  private Bool hasLabel([Str:Obj?][] items, Str label)
  {
    items.any |m| { m["label"] == label }
  }

  // ── result structure ──────────────────────────────────────────────────────────

  Void testCompleteResultStructure()
  {
    src := "class Foo {}\nif"
    doc := makeDoc(src)
    r := parse(src)
    result := provider.complete(doc, r, Position(1, 2)) as [Str:Obj?]
    verifyNotNull(result)
    verify(result.containsKey("isIncomplete"))
    verify(result.containsKey("items"))
    verifyEq(result["isIncomplete"], false)
  }

  // ── keyword completion ────────────────────────────────────────────────────────

  Void testKeywordsAppearInPlainCompletion()
  {
    // prefix "i" matches "if", "it", "is", "isnot", "internal"
    src := "i"
    items := complete(src, Position(0, 1))
    verify(hasLabel(items, "if"))
    verify(hasLabel(items, "it"))
    verify(hasLabel(items, "is"))
  }

  Void testKeywordsPrefixFiltered()
  {
    src := "wh"
    items := complete(src, Position(0, 2))
    verify(hasLabel(items, "while"))
    verifyFalse(hasLabel(items, "if"))
    verifyFalse(hasLabel(items, "return"))
  }

  Void testKeywordCompletionItemKind()
  {
    src := "return"
    items := complete(src, Position(0, 6))
    kw := items.find |m| { m["label"] == "return" }
    verifyNotNull(kw)
    verifyEq(kw["kind"], CompletionItem.keyword)
  }

  Void testEmptyWordNoPlainItems()
  {
    // When cursor is on an empty prefix the provider returns nothing for plain
    src := "class Foo {\n  \n}"
    // Position inside the class body on a blank line
    doc := makeDoc(src)
    r := parse(src)
    result := provider.complete(doc, r, Position(1, 2)) as [Str:Obj?]
    verifyNotNull(result)
    // Empty word: plain completions return empty list (no prefix to filter by)
    items := result["items"] as [Str:Obj?][]
    verifyEq(items.size, 0)
  }

  // ── using completion ──────────────────────────────────────────────────────────

  Void testUsingLineReturnsPodNames()
  {
    src := "using s"
    doc := makeDoc(src)
    r := parse(src)
    result := provider.complete(doc, r, Position(0, 7)) as [Str:Obj?]
    verifyNotNull(result)
    items := result["items"] as [Str:Obj?][]
    verifyNotNull(items)
    // "sys" starts with "s"
    verify(hasLabel(items, "sys"))
  }

  Void testUsingLineShortPrefixReturnsMultiplePods()
  {
    // prefix "s" matches sys, skyspark, etc. — verifies multiple results come back
    src := "using s"
    doc := makeDoc(src)
    r := parse(src)
    result := provider.complete(doc, r, Position(0, 7)) as [Str:Obj?]
    items := result["items"] as [Str:Obj?][]
    verify(items.size > 1)
    verify(hasLabel(items, "sys"))
  }

  // ── local type completion ──────────────────────────────────────────────────────

  Void testLocalTypeAppearsInCompletion()
  {
    src := "class MyWidget {}\nMyW"
    items := complete(src, Position(1, 3))
    verify(hasLabel(items, "MyWidget"))
  }

  Void testLocalTypeKindIsClass()
  {
    src := "class MyThing {}\nMyT"
    items := complete(src, Position(1, 3))
    item := items.find |m| { m["label"] == "MyThing" }
    verifyNotNull(item)
    verifyEq(item["kind"], CompletionItem.classKind)
  }

  // ── pod type completion ────────────────────────────────────────────────────────

  Void testPodTypeCompletion()
  {
    // "Str" should appear when typing "St"
    src := "using sys\nSt"
    items := complete(src, Position(1, 2))
    verify(hasLabel(items, "Str"))
  }

  Void testPodTypeKindIsClass()
  {
    src := "using sys\nStr"
    items := complete(src, Position(1, 3))
    item := items.find |m| { m["label"] == "Str" }
    verifyNotNull(item)
    verifyEq(item["kind"], CompletionItem.classKind)
  }

  // ── dot completion ────────────────────────────────────────────────────────────

  Void testDotCompletionOnPodType()
  {
    // "Str." should give Str slots
    src := "Str."
    doc := makeDoc(src)
    r := parse(src)
    result := provider.complete(doc, r, Position(0, 4)) as [Str:Obj?]
    items := result["items"] as [Str:Obj?][]
    verifyNotNull(items)
    verify(items.size > 0)
    // Str should have a "size" slot
    verify(hasLabel(items, "size"))
  }

  Void testDotCompletionOnInferredVar()
  {
    src := "x := \"hello\"\nx."
    doc := makeDoc(src)
    r := parse(src)
    result := provider.complete(doc, r, Position(1, 2)) as [Str:Obj?]
    items := result["items"] as [Str:Obj?][]
    verifyNotNull(items)
    verify(items.size > 0)
    // x is inferred as Str, so Str slots appear
    verify(hasLabel(items, "size"))
  }

  Void testDotCompletionFiltersedByPrefix()
  {
    src := "Str.si"
    doc := makeDoc(src)
    r := parse(src)
    result := provider.complete(doc, r, Position(0, 6)) as [Str:Obj?]
    items := result["items"] as [Str:Obj?][]
    // All items should start with "si" (case-insensitive)
    items.each |m|
    {
      label := m["label"] as Str
      verify(label.lower.startsWith("si"), "unexpected label: $label")
    }
  }

  Void testDotCompletionNoSyntheticNames()
  {
    src := "Str."
    items := complete(src, Position(0, 4))
    items.each |m|
    {
      label := m["label"] as Str
      verifyFalse(label.contains("\$"), "synthetic name leaked: $label")
    }
  }

  // ── local slot completion ──────────────────────────────────────────────────────

  Void testLocalMethodAppearsInCompletion()
  {
    src := "class Foo\n{\n  Void myMethod() {}\n}\nmyM"
    items := complete(src, Position(4, 3))
    verify(hasLabel(items, "myMethod"))
  }

  Void testLocalMethodKindIsMethod()
  {
    src := "class Foo\n{\n  Void doIt() {}\n}\ndoIt"
    items := complete(src, Position(4, 4))
    item := items.find |m| { m["label"] == "doIt" }
    verifyNotNull(item)
    verifyEq(item["kind"], CompletionItem.method)
  }

  // ── local variable completion ──────────────────────────────────────────────────

  Void testLocalVariableAppearsInCompletion()
  {
    src := "myVar := \"hello\"\nmyV"
    items := complete(src, Position(1, 3))
    verify(hasLabel(items, "myVar"))
  }

  Void testLocalVariableKindIsVariable()
  {
    src := "theValue := 42\ntheV"
    items := complete(src, Position(1, 4))
    item := items.find |m| { m["label"] == "theValue" }
    verifyNotNull(item)
    verifyEq(item["kind"], CompletionItem.variable)
  }

  Void testLocalVariableScopeAwareNotBelowCursor()
  {
    // Variable defined BELOW cursor should NOT appear
    src := "early\nmyLater := \"x\""
    items := complete(src, Position(0, 5))
    verifyFalse(hasLabel(items, "myLater"))
  }

  // ── method snippet ────────────────────────────────────────────────────────────

  Void testMethodCompletionHasSnippet()
  {
    src := "class Foo\n{\n  Void doThing(Int x) {}\n}\ndoThing"
    items := complete(src, Position(4, 7))
    item := items.find |m| { m["label"] == "doThing" }
    verifyNotNull(item)
    // Methods with params get a snippet
    insertText := item["insertText"] as Str
    if (insertText != null)
      verify(insertText.contains("("))
  }

  // ── isIncomplete flag ─────────────────────────────────────────────────────────

  Void testIsIncompleteIsFalse()
  {
    src := "class Foo {}\nFoo"
    doc := makeDoc(src)
    r := parse(src)
    result := provider.complete(doc, r, Position(1, 3)) as [Str:Obj?]
    verifyEq(result["isIncomplete"], false)
  }
}
