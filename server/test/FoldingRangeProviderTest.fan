class FoldingRangeProviderTest : Test
{
  private FoldingRangeProvider provider := FoldingRangeProvider()
  private RecoveringParser parser := RecoveringParser()

  Void testTypeAndMethodFold()
  {
    src := "class Foo {\n  Void bar() {\n    return\n  }\n}"
    result := parser.parse("file:///test.fan", src)
    ranges := provider.ranges(result)
    verify(ranges.size >= 1)
  }

  Void testEmptyFileNoFolds()
  {
    result := ParseResult.empty()
    ranges := provider.ranges(result)
    verifyEq(ranges.size, 0)
  }
}
