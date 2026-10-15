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

  Void testTripleQuoteIndentation()
  {
    // Triple-quote opens after "  Str x := " (11 chars),
    // so content lines should be indented to column 14 (11 + 3 for """)
    unformatted := "class Foo\n{\nStr x := \"\"\"\nhello\nworld\n\"\"\"\n}"

    doc := DocumentState("file:///test.fan", 1, unformatted)
    provider := FormattingProvider()
    opts := ["tabSize": 2, "insertSpaces": true]

    edits := provider.format(doc, opts)

    verifyEq(edits.size, 1)
    formatted := edits[0].newText
    lines := formatted.splitLines
      // "  Str x := \"\"\"" -> triple-quote starts at col 11, content indented to col 14
      verifyEq(lines[2], "  Str x := \"\"\"")
      // lines 3 and 4 are content, indented to column 14
      verify(lines[3].startsWith("              "))
      verify(lines[3].trim == "hello")
      verify(lines[4].startsWith("              "))
      verify(lines[4].trim == "world")
      // closing triple-quote also indented to column 14
      verify(lines[5].trim == "\"\"\"")
      verify(lines[5].startsWith("              "))
  }

  Void testTripleQuoteSingleLine()
  {
    // Single-line triple-quote should not affect subsequent lines
    unformatted := "class Foo\n{\nStr x := \"\"\"hello\"\"\"\nStr y := \"bar\"\n}"

    doc := DocumentState("file:///test.fan", 1, unformatted)
    provider := FormattingProvider()
    opts := ["tabSize": 2, "insertSpaces": true]

    edits := provider.format(doc, opts)

    verifyEq(edits.size, 1)
    formatted := edits[0].newText
    lines := formatted.splitLines
    verifyEq(lines[2], "  Str x := \"\"\"hello\"\"\"")
    verifyEq(lines[3], "  Str y := \"bar\"")
  }

  Void testListLiteralIndentation()
  {
    unformatted := "class Foo\n{\nObj method()\n{\nreturn Etc.makeDict([\n\"dis\" : \"hello\",\n\"equip\" : Marker.val,\n])\n}\n}"

    doc := DocumentState("file:///test.fan", 1, unformatted)
    provider := FormattingProvider()
    opts := ["tabSize": 2, "insertSpaces": true]

    edits := provider.format(doc, opts)

    verifyEq(edits.size, 1)
    formatted := edits[0].newText
    lines := formatted.splitLines
    verifyEq(lines[4], "    return Etc.makeDict([")
    verifyEq(lines[5], "        \"dis\" : \"hello\",")
    verifyEq(lines[6], "        \"equip\" : Marker.val,")
    verifyEq(lines[7], "    ])")
  }

  Void testMethodAfterClosingBrace()
  {
    unformatted := "class Foo {\n  Void setup() {\n    doWork()\n  }\n\nVoid doWork() {}\n}"

    doc := DocumentState("file:///test.fan", 1, unformatted)
    provider := FormattingProvider()
    opts := ["tabSize": 2, "insertSpaces": true]

    edits := provider.format(doc, opts)

    verifyEq(edits.size, 1)
    formatted := edits[0].newText
    verify(formatted.contains("  Void setup()"))
    verify(formatted.contains("  Void doWork()"))
  }

  Void testItBlockStaysOneLine()
  {
    src := "class Foo\n{\n  Void run()\n  {\n    list.each |x| {\n      echo(x)\n    }\n  }\n}"
    doc := DocumentState("file:///test.fan", 1, src)
    provider := FormattingProvider()
    allman := provider.format(doc, ["tabSize": 2, "insertSpaces": true, "bracketStyle": "allman"])[0].newText
    knr := provider.format(doc, ["tabSize": 2, "insertSpaces": true, "bracketStyle": "k&r"])[0].newText
    verify(allman.contains("list.each |x| {"))
    verify(knr.contains("list.each |x| {"))
    verifyFalse(allman.contains("|x|\n{"))
  }

  Void testFormatRangeInnerMethodOnly()
  {
    src := "class Foo\n{\nVoid run()\n{\necho(\"hi\")\n}\n}"
    doc := DocumentState("file:///test.fan", 1, src)
    provider := FormattingProvider()
    opts := ["tabSize": 2, "insertSpaces": true]
    // Inner method body lines (echo)
    range := LspRange(Position(4, 0), Position(4, 10))
    edits := provider.formatRange(doc, range, opts)
    verifyEq(edits.size, 1)
    verifyEq(edits[0].range.start.line, 4)
    verifyEq(edits[0].range.end.line, 4)
    origLines := src.splitLines
    verifyEq(edits[0].range.end.character, origLines[4].size)
    verify(edits[0].newText.contains("echo"))
    verifyFalse(edits[0].newText.contains("class Foo"))
  }

  Void testCallContinuationKeepsParenIndent()
  {
    src := [
      "class Foo",
      "{",
      "  Void run()",
      "  {",
      "    return bar(HxMsg(\"agentChat\",",
      "      config,",
      "      Etc.makeDict([",
      "        \"tools\": tools",
      "      ])",
      "    ))",
      "  }",
      "}"
    ].join("\n")
    doc := DocumentState("file:///test.fan", 1, src)
    provider := FormattingProvider()
    formatted := provider.format(doc, ["tabSize": 2, "insertSpaces": true])[0].newText
    lines := formatted.splitLines
    verifyEq(lines[4], "    return bar(HxMsg(\"agentChat\",")
    verifyEq(lines[5], "      config,")
    verifyEq(lines[6], "      Etc.makeDict([")
    verifyEq(lines[7], "        \"tools\": tools")
    verifyEq(lines[8], "      ])")
    verifyEq(lines[9], "    ))")
  }

  Void testOnTypeCloseBraceIndentsToMatchDepth()
  {
    src := "class Foo\n{\n  Void run()\n  {\n    echo(\"hi\")\n    }"
    doc := DocumentState("file:///test.fan", 1, src)
    provider := FormattingProvider()
    edits := provider.onTypeCloseBrace(doc, 5)
    verifyEq(edits.size, 1)
    verifyEq(edits[0].newText, "  }")
  }
}
