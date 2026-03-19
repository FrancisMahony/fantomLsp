class DiagnosticsProviderTest : Test
{
  private TextDocumentManager docManager := TextDocumentManager()
  private DiagnosticsProvider? provider
  private RecoveringParser parser := RecoveringParser()

  override Void setup()
  {
    provider = DiagnosticsProvider(docManager)
  }

  private ParseResult parse(Str src) { parser.parse("file:///test.fan", src) }

  Void testNoErrorsReturnsEmptyDiagnostics()
  {
    src := "class Foo { Void bar() { } }"
    result := parse(src)
    diags := provider.computeDiagnostics("file:///test.fan", result)
    verifyEq(diags.size, 0)
  }

  Void testEmptyParseResultReturnsEmptyDiagnostics()
  {
    result := ParseResult.empty()
    diags := provider.computeDiagnostics("file:///test.fan", result)
    verifyEq(diags.size, 0)
  }

  Void testSyntheticErrorConvertedToDiagnostic()
  {
    result := ParseResult("file:///test.fan")
    result.errors.add(ParseError(
      LspRange(Position(0, 0), Position(0, 10)),
      "Test error message"
    ))
    diags := provider.computeDiagnostics("file:///test.fan", result)
    verifyEq(diags.size, 1)
    verifyEq(diags[0].severity, Diagnostic.error)
    verifyEq(diags[0].message, "Test error message")
    verifyNotNull(diags[0].range)
    verifyEq(diags[0].source, "fantomLsp")
  }

  Void testMultipleErrorsConverted()
  {
    result := ParseResult("file:///test.fan")
    result.errors.add(ParseError(
      LspRange(Position(0, 0), Position(0, 10)),
      "Error 1"
    ))
    result.errors.add(ParseError(
      LspRange(Position(1, 0), Position(1, 10)),
      "Error 2"
    ))
    diags := provider.computeDiagnostics("file:///test.fan", result)
    verifyEq(diags.size, 2)
    verifyEq(diags[0].message, "Error 1")
    verifyEq(diags[1].message, "Error 2")
  }

  Void testDiagnosticHasCorrectProperties()
  {
    result := ParseResult("file:///test.fan")
    result.errors.add(ParseError(
      LspRange(Position(5, 10), Position(5, 20)),
      "Syntax error"
    ))
    diags := provider.computeDiagnostics("file:///test.fan", result)
    verifyEq(diags.size, 1)
    verifyNotNull(diags[0].range)
    verifyNotNull(diags[0].range.start)
    verifyNotNull(diags[0].range.end)
    verifyEq(diags[0].range.start.line, 5)
    verifyEq(diags[0].range.start.character, 10)
    verifyEq(diags[0].range.end.line, 5)
    verifyEq(diags[0].range.end.character, 20)
    verifyEq(diags[0].severity, Diagnostic.error)
    verifyEq(diags[0].source, "fantomLsp")
  }

  Void testCharLiteralContainingQuoteProducesNoDiagnostics()
  {
    // '"' inside a char literal must not be treated as an open string quote,
    // which would cause the closing ')' to be swallowed and produce a false
    // "Unclosed parenthesis '('" diagnostic.
    src :=
      "class Foo
       {
         Void bar()
         {
           parts := trimmed.split('\"')
         }
       }"
    result := parse(src)
    diags := provider.computeDiagnostics("file:///test.fan", result)
    verifyEq(diags.size, 0)
  }

  Void testTripleQuoteStringClosingOnSameLineAsParenNoDiagnostics()
  {
    // Closing """ followed by ) on the same line must not report unclosed paren
    src :=
      "class Foo
       {
         Void bar()
         {
           eval(\"\"\"do
                   x := 1 + (2 * 3)
                   end\"\"\")
         }
       }"
    result := parse(src)
    diags := provider.computeDiagnostics("file:///test.fan", result)
    verifyEq(diags.size, 0)
  }

  Void testTripleQuoteSingleLineNoDiagnostics()
  {
    // Triple-quoted string that opens and closes on the same line
    src :=
      "class Foo
       {
         Void bar()
         {
           x := eval(\"\"\"read(point and dis==\\\"My Point\\\")\"\"\")
         }
       }"
    result := parse(src)
    diags := provider.computeDiagnostics("file:///test.fan", result)
    verifyEq(diags.size, 0)
  }

  Void testBlockCommentWithParensNoDiagnostics()
  {
    // Parens and braces inside /* */ block comments must be ignored
    src :=
      "class Foo
       {
         Void bar() { }
         /*
         Void commented(Str x) {
           doSomething(
         }
         */
       }"
    result := parse(src)
    diags := provider.computeDiagnostics("file:///test.fan", result)
    verifyEq(diags.size, 0)
  }

  Void testMultipleTripleQuoteStringsNoDiagnostics()
  {
    // Multiple triple-quoted strings in sequence
    src :=
      "class Foo
       {
         Void bar()
         {
           eval(\"\"\"commit(diff(null, {site, dis:\\\"S1\\\"}, {add}))\"\"\")
           eval(\"\"\"do
                   x := read(point)
                   end\"\"\")
         }
       }"
    result := parse(src)
    diags := provider.computeDiagnostics("file:///test.fan", result)
    verifyEq(diags.size, 0)
  }

  Void testComplexValidCodeProducesNoDiagnostics()
  {
    src :=
      "class Example
       {
         Str name
         Int count := 0

         new make(Str name) { this.name = name }

         Void increment() { count++ }

         override Str toStr() { \"Example: \$name (\$count)\" }
       }"
    result := parse(src)
    diags := provider.computeDiagnostics("file:///test.fan", result)
    verifyEq(diags.size, 0)
  }
}
