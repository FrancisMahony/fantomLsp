class InlayHintProviderTest : Test
{
  private InlayHintProvider provider := InlayHintProvider()
  private RecoveringParser parser := RecoveringParser()

  private [Str:Obj?][] hints(Str src)
  {
    doc := DocumentState("file:///test.fan", 1, src)
    return provider.hints(doc, parser.parse(doc.uri, src))
  }

  Void testInferredStringHint()
  {
    result := hints("x := \"hi\"")
    verifyEq(result.size, 1)
    verifyEq(result[0]["label"], ": Str")
    verifyEq((result[0]["position"] as [Str:Obj?])["character"], 2)
    verifyEq(result[0]["kind"], 1)
    verifyEq(result[0]["paddingLeft"], false)
    verifyEq(result[0]["paddingRight"], true)
  }

  Void testExplicitTypeHasNoHint()
  {
    verifyEq(hints("Int y := 1").size, 0)
  }

  Void testEmptyClassHasNoHints()
  {
    verifyEq(hints("class Foo\n{\n}").size, 0)
  }
}
