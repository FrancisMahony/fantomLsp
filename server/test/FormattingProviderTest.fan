using build

class FormattingProviderTest : Test
{
  Void testBasicFormatting()
  {
    unformatted := "class Foo\n{\nStr name\nInt age\n}"

    doc := DocumentState("file:///test.fan", 1, unformatted)
    provider := FormattingProvider()
    opts := ["tabSize": 2, "insertSpaces": true]

    edits := provider.format(doc, opts)

    verifyEq(edits.size, 1)
    verify(edits[0].newText.contains("  Str name"))
    verify(edits[0].newText.contains("  Int age"))
  }

  Void testNestedFormatting()
  {
    unformatted := "class Outer\n{\nclass Inner\n{\nStr value\n}\n}"

    doc := DocumentState("file:///test.fan", 1, unformatted)
    provider := FormattingProvider()
    opts := ["tabSize": 2, "insertSpaces": true]

    edits := provider.format(doc, opts)

    verifyEq(edits.size, 1)
    formatted := edits[0].newText
    verify(formatted.contains("  class Inner"))
    verify(formatted.contains("    Str value"))
  }

  Void testMethodFormatting()
  {
    unformatted := "class Test\n{\nVoid run()\n{\necho(\"hi\")\n}\n}"

    doc := DocumentState("file:///test.fan", 1, unformatted)
    provider := FormattingProvider()
    opts := ["tabSize": 2, "insertSpaces": true]

    edits := provider.format(doc, opts)

    verifyEq(edits.size, 1)
    formatted := edits[0].newText
    verify(formatted.contains("  Void run()"))
    verify(formatted.contains("    echo"))
  }

  Void testBracketStylePreserve()
  {
    mixedBraces := "class User\n{\n  Str name\n}\n\nclass Cat {\n  Str breed\n}"

    doc := DocumentState("file:///test.fan", 1, mixedBraces)
    provider := FormattingProvider()
    opts := ["tabSize": 2, "insertSpaces": true, "bracketStyle": "preserve"]

    edits := provider.format(doc, opts)

    verifyEq(edits.size, 1)
    formatted := edits[0].newText
    verify(formatted.contains("class User\n{"))
    verify(formatted.contains("class Cat {"))
  }

  Void testBracketStyleKR()
  {
    mixedBraces := "class User\n{\n  Str name\n}\n\nclass Cat {\n  Str breed\n}"

    doc := DocumentState("file:///test.fan", 1, mixedBraces)
    provider := FormattingProvider()
    opts := ["tabSize": 2, "insertSpaces": true, "bracketStyle": "k&r"]

    edits := provider.format(doc, opts)

    verifyEq(edits.size, 1)
    formatted := edits[0].newText
    verify(formatted.contains("class User {"))
    verify(formatted.contains("class Cat {"))
    verifyFalse(formatted.contains("class User\n{"))
    verifyFalse(formatted.contains("class Cat\n{"))
  }

  Void testBracketStyleAllman()
  {
    mixedBraces := "class User {\n  Str name\n}\n\nclass Cat {\n  Str breed\n}"

    doc := DocumentState("file:///test.fan", 1, mixedBraces)
    provider := FormattingProvider()
    opts := ["tabSize": 2, "insertSpaces": true, "bracketStyle": "allman"]

    edits := provider.format(doc, opts)

    verifyEq(edits.size, 1)
    formatted := edits[0].newText
    verify(formatted.contains("class User\n{"))
    verify(formatted.contains("class Cat\n{"))
    verifyFalse(formatted.contains("class User {"))
    verifyFalse(formatted.contains("class Cat {"))
  }
}
