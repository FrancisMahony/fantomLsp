class CallHierarchyProviderTest : Test
{
  private CallHierarchyProvider provider := CallHierarchyProvider()
  private RecoveringParser parser := RecoveringParser()

  private ParseResult parse(Str src) { parser.parse("file:///test.fan", src) }

  private DocumentState makeDoc(Str src)
  {
    DocumentState("file:///test.fan", 1, src)
  }

  private SymbolTable makeTable(Str src)
  {
    t := SymbolTable()
    t.update("file:///test.fan", parse(src))
    return t
  }

  private ReferenceIndex makeIndex(Str src)
  {
    idx := ReferenceIndex()
    idx.update("file:///test.fan", parse(src))
    return idx
  }

  Void testPrepareOnMethod()
  {
    src := "class Foo\n{\n  Void bar() {}\n}"
    doc := makeDoc(src)
    pos := Position(2, 7)
    table := makeTable(src)
    result := provider.prepare(doc, pos, table)
    items := result as List
    verifyNotNull(items)
    verify(items.size > 0)
    item := items[0] as [Str:Obj?]
    verifyNotNull(item)
    verifyEq(item["name"], "bar")
  }

  Void testPrepareOnNonMethod()
  {
    src := "class Foo\n{\n  Str name := \"\"\n}"
    doc := makeDoc(src)
    pos := Position(2, 6)
    table := makeTable(src)
    result := provider.prepare(doc, pos, table)
    verifyNull(result)
  }

  Void testPrepareOnUnknownWord()
  {
    src := "class Foo\n{\n}"
    doc := makeDoc(src)
    pos := Position(0, 0)
    table := makeTable(src)
    result := provider.prepare(doc, pos, table)
    verifyNull(result)
  }

  Void testIncomingCallsEmpty()
  {
    idx := ReferenceIndex()
    item := [Str:Obj?]["name": "bar"]
    result := provider.incomingCalls(item, SymbolTable(), idx) as List
    verifyNotNull(result)
    verifyEq(result.size, 0)
  }

  Void testIncomingCallsEmptyName()
  {
    idx := ReferenceIndex()
    item := [Str:Obj?]["name": ""]
    result := provider.incomingCalls(item, SymbolTable(), idx) as List
    verifyNotNull(result)
    verifyEq(result.size, 0)
  }

  Void testOutgoingCallsEmptyName()
  {
    idx := ReferenceIndex()
    item := [Str:Obj?]["name": ""]
    result := provider.outgoingCalls(item, SymbolTable(), idx) as List
    verifyNotNull(result)
    verifyEq(result.size, 0)
  }

  Void testOutgoingCallsNoBody()
  {
    src := "class Foo\n{\n  Void bar() {}\n}"
    table := makeTable(src)
    idx := makeIndex(src)
    item := [Str:Obj?]["name": "bar", "uri": "file:///test.fan"]
    result := provider.outgoingCalls(item, table, idx) as List
    verifyNotNull(result)
    verifyEq(result.size, 0)
  }

  Void testOutgoingCallsFindsCallee()
  {
    src :=
      "class Foo\n" +
      "{\n" +
      "  Void caller()\n" +
      "  {\n" +
      "    helper()\n" +
      "  }\n" +
      "  Void helper() {}\n" +
      "}"
    table := makeTable(src)
    idx := makeIndex(src)
    item := [Str:Obj?]["name": "caller", "uri": "file:///test.fan"]
    result := provider.outgoingCalls(item, table, idx) as List
    verifyNotNull(result)
    verifyEq(result.size, 1)
    entry := result[0] as [Str:Obj?]
    verifyNotNull(entry)
    to := entry["to"] as [Str:Obj?]
    verifyNotNull(to)
    verifyEq(to["name"], "helper")
  }

  Void testOutgoingCallsIgnoresKeywords()
  {
    src :=
      "class Foo\n" +
      "{\n" +
      "  Void caller()\n" +
      "  {\n" +
      "    if (true) helper()\n" +
      "  }\n" +
      "  Void helper() {}\n" +
      "}"
    table := makeTable(src)
    idx := makeIndex(src)
    item := [Str:Obj?]["name": "caller", "uri": "file:///test.fan"]
    result := provider.outgoingCalls(item, table, idx) as List
    verifyNotNull(result)
    verifyEq(result.size, 1)
    entry := result[0] as [Str:Obj?]
    to := entry["to"] as [Str:Obj?]
    verifyEq(to["name"], "helper")
  }

  Void testOutgoingCallsFromRangePresent()
  {
    src :=
      "class Foo\n" +
      "{\n" +
      "  Void caller()\n" +
      "  {\n" +
      "    helper()\n" +
      "  }\n" +
      "  Void helper() {}\n" +
      "}"
    table := makeTable(src)
    idx := makeIndex(src)
    item := [Str:Obj?]["name": "caller", "uri": "file:///test.fan"]
    result := provider.outgoingCalls(item, table, idx) as List
    verifyNotNull(result)
    verify(result.size >= 1)
    entry := result[0] as [Str:Obj?]
    fromRanges := entry["fromRanges"] as List
    verifyNotNull(fromRanges)
    verifyEq(fromRanges.size, 1)
  }
}
