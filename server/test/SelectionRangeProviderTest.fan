class SelectionRangeProviderTest : Test
{
  private SelectionRangeProvider provider := SelectionRangeProvider()
  private RecoveringParser parser := RecoveringParser()

  Void testMethodNameHasWordThenMethodThenType()
  {
    src := "class Foo\n{\n  Void bar()\n  {\n  }\n}"
    doc := DocumentState("file:///test.fan", 1, src)
    r := parser.parse("file:///test.fan", src)
    // "bar" is on line 2
    results := provider.selectionRanges(doc, r, [Position(2, 7)])
    verifyEq(results.size, 1)
    word := results[0] as [Str:Obj?]
    verifyNotNull(word)
    wr := word["range"] as [Str:Obj?]
    start := wr["start"] as [Str:Obj?]
    end := wr["end"] as [Str:Obj?]
    verifyEq(start["line"], 2)
    verifyEq(start["character"], 7)
    verifyEq(end["character"], 10)

    method := word["parent"] as [Str:Obj?]
    verifyNotNull(method)
    type := method["parent"] as [Str:Obj?]
    verifyNotNull(type)
    verifyNull(type["parent"])
  }
}
