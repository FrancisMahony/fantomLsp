using compiler

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

  Void testUnusedUsingWarning()
  {
    src := "using util\nclass Foo {}"
    docManager.open(TextDocumentItem("file:///test.fan", "fantom", 1, src))
    result := parse(src)
    diags := provider.computeParserDiagnostics("file:///test.fan", result)
    warn := diags.find |d| { d.severity == Diagnostic.warning && d.message.contains("Unused using") }
    verifyNotNull(warn)
  }

  Void testUnusedLocalWarning()
  {
    src :=
      "class Foo
       {
         Void foo()
         {
           x := 1
         }
       }"
    docManager.open(TextDocumentItem("file:///test.fan", "fantom", 1, src))
    result := parse(src)
    diags := provider.computeParserDiagnostics("file:///test.fan", result)
    warn := diags.find |d| { d.message == "Unused local 'x'" }
    verifyNotNull(warn)
    verifyEq(warn.severity, Diagnostic.warning)
    verifyEq(warn.source, "fantomLsp")
  }

  Void testUsedLocalNoWarning()
  {
    src :=
      "class Foo
       {
         Void foo()
         {
           x := 1
           echo(x)
         }
       }"
    docManager.open(TextDocumentItem("file:///test.fan", "fantom", 1, src))
    result := parse(src)
    diags := provider.computeParserDiagnostics("file:///test.fan", result)
    warn := diags.find |d| { d.message == "Unused local 'x'" }
    verifyNull(warn)
  }

  Void testDefaultParamNullNotUnusedLocal()
  {
    src :=
      "class Foo
       {
         static Grid nvCmmsReadAll(Obj conn, DateTime? modStart := null, Number? limit := null)
         {
           return echo(conn, modStart, limit)
         }
       }"
    docManager.open(TextDocumentItem("file:///test.fan", "fantom", 1, src))
    result := parse(src)
    diags := provider.computeParserDiagnostics("file:///test.fan", result)
    verifyNull(diags.find |d| { d.message.contains("Unused local 'null'") })
    verifyNull(diags.find |d| { d.message.contains("Unused local 'modStart'") })
    verifyNull(diags.find |d| { d.message.contains("Unused local 'limit'") })
  }

  Void testCompilerCoordinatesAreOneBasedAndSourceStable()
  {
    errors := [CompilerErr("Bad return", Loc("sample.fan", 2, 3)),
      CompilerErr("Unknown", Loc("sample.fan"))]
    diags := DiagnosticsProvider.compilerDiagnosticsFor("class A\n  wrong\n", errors)
    verifyEq(diags[0].range.start.line, 1)
    verifyEq(diags[0].range.start.character, 2)
    verifyEq(diags[0].range.end.line, 1)
    verifyEq(diags[0].range.end.character, 7)
    verifyEq(diags[0].message, "Bad return")
    verifyEq(diags[0].source, "fantomCompiler")
    verifyEq(diags[1].range.start.line, 0)
    verifyEq(diags[1].range.start.character, 0)
  }
}
