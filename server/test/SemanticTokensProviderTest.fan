class SemanticTokensProviderTest : Test
{
  private SemanticTokensProvider provider := SemanticTokensProvider()
  private RecoveringParser parser := RecoveringParser()
  private SymbolTable symbolTable := SymbolTable()
  private TypeResolver typeResolver := TypeResolver()

  private ParseResult parse(Str src) { parser.parse("file:///test.fan", src) }

  private DocumentState makeDoc(Str src)
  {
    DocumentState("file:///test.fan", 1, src)
  }

  Void testProvideTokensReturnsData()
  {
    src := "class Foo {}"
    doc := makeDoc(src)
    r := parse(src)
    symbolTable.update("file:///test.fan", r)

    result := provider.provideTokens(doc, symbolTable, typeResolver)
    verifyNotNull(result)
    verify(result is [Str:Obj?])
    resultMap := result as [Str:Obj?]
    data := resultMap["data"] as Int[]
    verifyNotNull(data)
  }

  Void testClassTokenEncoding()
  {
    src := "class MyClass {}"
    doc := makeDoc(src)
    r := parse(src)
    symbolTable.update("file:///test.fan", r)

    result := provider.provideTokens(doc, symbolTable, typeResolver)
    resultMap := result as [Str:Obj?]
    data := resultMap["data"] as Int[]

    verifyNotNull(data)
    verify(data.size >= 5)
  }

  Void testMethodTokens()
  {
    src := "class Foo\n{\n  Void myMethod() {}\n}"
    doc := makeDoc(src)
    r := parse(src)
    symbolTable.update("file:///test.fan", r)

    result := provider.provideTokens(doc, symbolTable, typeResolver)
    resultMap := result as [Str:Obj?]
    data := resultMap["data"] as Int[]

    verifyNotNull(data)
    verify(data.size >= 10)
  }

  Void testFieldTokens()
  {
    src := "class Foo\n{\n  Int myField\n}"
    doc := makeDoc(src)
    r := parse(src)
    symbolTable.update("file:///test.fan", r)

    result := provider.provideTokens(doc, symbolTable, typeResolver)
    resultMap := result as [Str:Obj?]
    data := resultMap["data"] as Int[]

    verifyNotNull(data)
  }

  Void testStaticModifier()
  {
    src := "class Foo\n{\n  static Void staticMethod() {}\n}"
    doc := makeDoc(src)
    r := parse(src)
    symbolTable.update("file:///test.fan", r)

    result := provider.provideTokens(doc, symbolTable, typeResolver)
    resultMap := result as [Str:Obj?]
    data := resultMap["data"] as Int[]

    verifyNotNull(data)
    verify(data.size >= 5)
  }

  Void testConstModifier()
  {
    src := "class Foo\n{\n  const Int constField := 42\n}"
    doc := makeDoc(src)
    r := parse(src)
    symbolTable.update("file:///test.fan", r)

    result := provider.provideTokens(doc, symbolTable, typeResolver)
    resultMap := result as [Str:Obj?]
    data := resultMap["data"] as Int[]

    verifyNotNull(data)
  }

  Void testEnumTokens()
  {
    src := "enum class Color\n{\n  red, green, blue\n}"
    doc := makeDoc(src)
    r := parse(src)
    symbolTable.update("file:///test.fan", r)

    result := provider.provideTokens(doc, symbolTable, typeResolver)
    resultMap := result as [Str:Obj?]
    data := resultMap["data"] as Int[]

    verifyNotNull(data)
    verify(data.size >= 5)
  }

  Void testMixinTokens()
  {
    src := "mixin MyMixin\n{\n  abstract Void doSomething()\n}"
    doc := makeDoc(src)
    r := parse(src)
    symbolTable.update("file:///test.fan", r)

    result := provider.provideTokens(doc, symbolTable, typeResolver)
    resultMap := result as [Str:Obj?]
    data := resultMap["data"] as Int[]

    verifyNotNull(data)
  }

  Void testMultipleTypes()
  {
    src := "class First {}\nclass Second {}\nmixin Third {}"
    doc := makeDoc(src)
    r := parse(src)
    symbolTable.update("file:///test.fan", r)

    result := provider.provideTokens(doc, symbolTable, typeResolver)
    resultMap := result as [Str:Obj?]
    data := resultMap["data"] as Int[]

    verifyNotNull(data)
    verify(data.size >= 15)
  }

  Void testLspEncodingFormat()
  {
    src := "class Foo {}"
    doc := makeDoc(src)
    r := parse(src)
    symbolTable.update("file:///test.fan", r)

    result := provider.provideTokens(doc, symbolTable, typeResolver)
    resultMap := result as [Str:Obj?]
    data := resultMap["data"] as Int[]

    verifyNotNull(data)
    verifyEq(data.size % 5, 0)
  }

  Void testAbstractModifier()
  {
    src := "abstract class AbstractClass\n{\n  abstract Void abstractMethod()\n}"
    doc := makeDoc(src)
    r := parse(src)
    symbolTable.update("file:///test.fan", r)

    result := provider.provideTokens(doc, symbolTable, typeResolver)
    resultMap := result as [Str:Obj?]
    data := resultMap["data"] as Int[]

    verifyNotNull(data)
  }

  Void testUsingStatement()
  {
    src := "using sys\nclass Foo {}"
    doc := makeDoc(src)
    r := parse(src)
    symbolTable.update("file:///test.fan", r)

    result := provider.provideTokens(doc, symbolTable, typeResolver)
    resultMap := result as [Str:Obj?]
    data := resultMap["data"] as Int[]

    verifyNotNull(data)
  }

  Void testConstructorTokens()
  {
    src := "class Foo\n{\n  new make() {}\n}"
    doc := makeDoc(src)
    r := parse(src)
    symbolTable.update("file:///test.fan", r)

    result := provider.provideTokens(doc, symbolTable, typeResolver)
    resultMap := result as [Str:Obj?]
    data := resultMap["data"] as Int[]

    verifyNotNull(data)
  }

  Void testBodyRefTokens()
  {
    src := "class Foo\n{\n  Void bar() { Str x := \"a\" }\n}"
    doc := makeDoc(src)
    r := parse(src)
    symbolTable.update("file:///test.fan", r)
    result := provider.provideTokens(doc, symbolTable, typeResolver, r)
    resultMap := result as [Str:Obj?]
    data := resultMap["data"] as Int[]
    verifyNotNull(data)
    verifyEq(data.size % 5, 0)
    verify(data.size > 10)
  }

  Void testProvideTokensRangeFiltersLines()
  {
    src := "class First {}\nclass Second {}\nclass Third {}"
    doc := makeDoc(src)
    r := parse(src)
    symbolTable.update("file:///test.fan", r)
    range := LspRange(Position(1, 0), Position(1, 20))
    result := provider.provideTokensRange(doc, symbolTable, r, range)
    resultMap := result as [Str:Obj?]
    data := resultMap["data"] as Int[]
    verifyNotNull(data)
    verifyEq(data.size % 5, 0)
    verify(data.size > 0)
    absLine := 0
    i := 0
    while (i + 4 < data.size)
    {
      absLine += data[i]
      verifyEq(absLine, 1)
      i += 5
    }
  }
}
