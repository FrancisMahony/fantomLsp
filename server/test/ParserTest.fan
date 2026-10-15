class ParserTest : Test
{
  private RecoveringParser parser := RecoveringParser()

  private ParseResult parse(Str src) { parser.parse("test://file.fan", src) }

  // ── Empty / blank input ───────────────────────────────────────────────────────

  Void testEmptySource()
  {
    r := parse("")
    verifyEq(r.nodes.size, 0)
    verifyEq(r.errors.size, 0)
  }

  Void testBlankLines()
  {
    r := parse("\n\n\n")
    verifyEq(r.nodes.size, 0)
  }

  Void testLineComments()
  {
    r := parse("// this is a comment\n// another comment")
    verifyEq(r.nodes.size, 0)
  }

  // ── using statements ──────────────────────────────────────────────────────────

  Void testSingleUsing()
  {
    r := parse("using sys")
    verifyEq(r.nodes.size, 1)
    n := r.nodes[0]
    verifyEq(n.kind, AstNodeKind.usingDef)
    verifyEq(n.name, "sys")
  }

  Void testMultipleUsings()
  {
    r := parse("using sys\nusing util\nusing concurrent")
    usings := r.nodes.findAll |n| { n.kind == AstNodeKind.usingDef }
    verifyEq(usings.size, 3)
    verifyEq(usings[0].name, "sys")
    verifyEq(usings[1].name, "util")
    verifyEq(usings[2].name, "concurrent")
  }

  Void testUsingWithPodAndType()
  {
    // "using sys::Str" → name is "sys::Str"
    r := parse("using sys::Str")
    verifyEq(r.nodes.size, 1)
    verifyEq(r.nodes[0].name, "sys::Str")
  }

  // ── class definitions ─────────────────────────────────────────────────────────
  Void testStructuredUsingsAndAliases()
  {
    r := parse("using a::B as C\nusing [java] x.y::Z\nusing a")
    verifyEq(r.nodes[0].name, "a::B")
    verifyEq(r.nodes[0].usingPod, "a")
    verifyEq(r.nodes[0].usingType, "B")
    verifyEq(r.nodes[0].usingAlias, "C")
    verifyEq(r.nodes[0].isJava, false)
    verifyEq(r.nodes[1].name, "x.y::Z")
    verifyEq(r.nodes[1].usingPod, "x.y")
    verifyEq(r.nodes[1].usingType, "Z")
    verifyEq(r.nodes[1].isJava, true)
    verifyEq(r.nodes[2].usingPod, "a")
    verifyNull(r.nodes[2].usingType)
    resolver := TypeResolver()
    table := SymbolTable()
    resolver.updateUsings(r.uri, r)
    verifyEq(resolver.resolveType(r.uri, "C", table), "a::B")
    verifyNull(resolver.resolveType(r.uri, "B", table))
    verifyEq(resolver.resolveType(r.uri, "Z", table), "[java]x.y::Z")
    resolver.updateUsings(r.uri, parse("using b::B as C\nusing a::B as C"))
    verifyEq(resolver.resolveTypes(r.uri, "C", table), ["a::B", "b::B"])
    verifyNull(resolver.resolveType(r.uri, "C", table))
    resolver.updateUsings(r.uri, parse("using a::B\tas\tC; // alias"))
    verifyEq(resolver.resolveType(r.uri, "C", table), "a::B")
    resolver.updateUsings(r.uri, ParseResult.empty)
    verifyNull(resolver.resolveType(r.uri, "C", table))
  }

  Void testWholePodVisibility()
  {
    r := parse("using concurrent")
    resolver := TypeResolver()
    resolver.updateUsings(r.uri, r)
    verifyEq(resolver.resolveType(r.uri, "Actor", SymbolTable()), "concurrent::Actor")
    verifyEq(resolver.resolveType(r.uri, "Str", SymbolTable()), "sys::Str")
    // A same-named unrelated workspace type must not override an import.
    table := SymbolTable()
    table.update("test://other.fan", parse("class Actor {}"))
    verifyEq(resolver.resolveType(r.uri, "Actor", table), "concurrent::Actor")
  }


  Void testSimpleClass()
  {
    r := parse("class Foo\n{\n}")
    classes := r.nodes.findAll |n| { n.kind == AstNodeKind.classDef }
    verifyEq(classes.size, 1)
    verifyEq(classes[0].name, "Foo")
  }

  Void testClassWithModifiers()
  {
    r := parse("public class Bar\n{\n}")
    n := r.nodes.find |n| { n.kind == AstNodeKind.classDef }
    verifyNotNull(n)
    verifyEq(n.name, "Bar")
    verify(n.modifiers.contains("public"))
  }

  Void testConstClass()
  {
    r := parse("const class Point\n{\n}")
    n := r.nodes.find |n| { n.kind == AstNodeKind.classDef }
    verifyNotNull(n)
    verify(n.modifiers.contains("const"))
  }

  Void testClassWithOpenBraceOnSameLine()
  {
    r := parse("class Baz {}")
    n := r.nodes.find |n| { n.kind == AstNodeKind.classDef }
    verifyNotNull(n)
    verifyEq(n.name, "Baz")
  }

  // ── mixin definitions ─────────────────────────────────────────────────────────

  Void testSimpleMixin()
  {
    r := parse("mixin Readable\n{\n}")
    n := r.nodes.find |n| { n.kind == AstNodeKind.mixinDef }
    verifyNotNull(n)
    verifyEq(n.name, "Readable")
  }

  // ── enum class definitions ────────────────────────────────────────────────────

  Void testEnumClass()
  {
    src := "enum class Color\n{\n  Red,\n  Green,\n  Blue\n}"
    r := parse(src)
    n := r.nodes.find |n| { n.kind == AstNodeKind.enumDef }
    verifyNotNull(n)
    verifyEq(n.name, "Color")
  }

  Void testEnumValues()
  {
    src := "enum class Status\n{\n  Active,\n  Inactive\n}"
    r := parse(src)
    n := r.nodes.find |n| { n.kind == AstNodeKind.enumDef }
    verifyNotNull(n)
    vals := n.children.findAll |c| { c.kind == AstNodeKind.enumValDef }
    verifyEq(vals.size, 2)
    verifyEq(vals[0].name, "Active")
    verifyEq(vals[1].name, "Inactive")
  }

  // ── facet class definitions ───────────────────────────────────────────────────

  Void testFacetClass()
  {
    r := parse("facet class MyFacet\n{\n}")
    n := r.nodes.find |n| { n.kind == AstNodeKind.facetClassDef }
    verifyNotNull(n)
    verifyEq(n.name, "MyFacet")
  }

  // ── field definitions ──────────────────────────────────────────────────────────

  Void testFieldWithType()
  {
    src := "class Foo\n{\n  Int count\n}"
    r := parse(src)
    cls := r.nodes.find |n| { n.kind == AstNodeKind.classDef }
    verifyNotNull(cls)
    field := cls.children.find |c| { c.kind == AstNodeKind.fieldDef && c.name == "count" }
    verifyNotNull(field)
    verifyEq(field.typeName, "Int")
  }

  Void testFieldWithAssignment()
  {
    src := "class Foo\n{\n  Str name := \"default\"\n}"
    r := parse(src)
    cls := r.nodes.find |n| { n.kind == AstNodeKind.classDef }
    field := cls.children.find |c| { c.kind == AstNodeKind.fieldDef && c.name == "name" }
    verifyNotNull(field)
    verifyEq(field.typeName, "Str")
  }

  Void testMultipleFields()
  {
    src := "class Foo\n{\n  Int x\n  Int y\n  Str label\n}"
    r := parse(src)
    cls := r.nodes.find |n| { n.kind == AstNodeKind.classDef }
    fields := cls.children.findAll |c| { c.kind == AstNodeKind.fieldDef }
    verifyEq(fields.size, 3)
  }

  // ── method definitions ────────────────────────────────────────────────────────

  Void testSimpleMethod()
  {
    src := "class Foo\n{\n  Void run() {}\n}"
    r := parse(src)
    cls := r.nodes.find |n| { n.kind == AstNodeKind.classDef }
    m := cls.children.find |c| { c.kind == AstNodeKind.methodDef && c.name == "run" }
    verifyNotNull(m)
    verifyEq(m.returnType, "Void")
  }

  Void testMethodWithParams()
  {
    src := "class Foo\n{\n  Int add(Int x, Int y) { x + y }\n}"
    r := parse(src)
    cls := r.nodes.find |n| { n.kind == AstNodeKind.classDef }
    m := cls.children.find |c| { c.name == "add" }
    verifyNotNull(m)
    verifyEq(m.params.size, 2)
    verifyEq(m.params[0], "Int x")
    verifyEq(m.params[1], "Int y")
    locals := m.children.findAll |c| { c.kind == AstNodeKind.localDef }
    verifyEq(locals.size, 2)
    verifyEq(locals[0].name, "x")
    verifyEq(locals[0].typeName, "Int")
    verifyEq(locals[1].name, "y")
    verifyEq(locals[1].typeName, "Int")
  }

  Void testMethodParamLocalDefs()
  {
    src := "class Foo\n{\n  Void foo(Int x) {}\n}"
    r := parse(src)
    cls := r.nodes.find |n| { n.kind == AstNodeKind.classDef }
    m := cls.children.find |c| { c.kind == AstNodeKind.methodDef && c.name == "foo" }
    verifyNotNull(m)
    verifyEq(m.params.size, 1)
    locals := m.children.findAll |c| { c.kind == AstNodeKind.localDef }
    verifyEq(locals.size, 1)
    verifyEq(locals[0].name, "x")
    verifyEq(locals[0].symbolKind, DocumentSymbol.variable)
  }

  Void testMethodNoParams()
  {
    src := "class Foo\n{\n  Str name() { \"foo\" }\n}"
    r := parse(src)
    cls := r.nodes.find |n| { n.kind == AstNodeKind.classDef }
    m := cls.children.find |c| { c.name == "name" }
    verifyNotNull(m)
    verifyEq(m.params.size, 0)
  }

  // ── constructor definitions ───────────────────────────────────────────────────

  Void testConstructor()
  {
    src := "class Foo\n{\n  new make() {}\n}"
    r := parse(src)
    cls := r.nodes.find |n| { n.kind == AstNodeKind.classDef }
    ctor := cls.children.find |c| { c.kind == AstNodeKind.ctorDef }
    verifyNotNull(ctor)
    verifyEq(ctor.name, "make")
  }

  Void testConstructorWithParams()
  {
    src := "class Point\n{\n  new make(Int x, Int y) { this.x = x; this.y = y }\n  Int x\n  Int y\n}"
    r := parse(src)
    cls := r.nodes.find |n| { n.kind == AstNodeKind.classDef }
    ctor := cls.children.find |c| { c.kind == AstNodeKind.ctorDef }
    verifyNotNull(ctor)
    verifyEq(ctor.params.size, 2)
  }

  // ── doc comments ──────────────────────────────────────────────────────────────

  Void testDocComment()
  {
    src := "** A simple class\nclass Doc\n{\n}"
    r := parse(src)
    cls := r.nodes.find |n| { n.kind == AstNodeKind.classDef }
    verifyNotNull(cls)
    verifyNotNull(cls.doc)
    verify(cls.doc.contains("A simple class"))
  }

  Void testMultiLineDoc()
  {
    src := "** First line\n** Second line\nclass Documented\n{\n}"
    r := parse(src)
    cls := r.nodes.find |n| { n.kind == AstNodeKind.classDef }
    verifyNotNull(cls.doc)
    verify(cls.doc.contains("First line"))
    verify(cls.doc.contains("Second line"))
  }

  Void testNoDoc()
  {
    src := "class NoDoc\n{\n}"
    r := parse(src)
    cls := r.nodes.find |n| { n.kind == AstNodeKind.classDef }
    verifyNull(cls.doc)
  }

  // ── parent/child relationships ────────────────────────────────────────────────

  Void testChildParentLink()
  {
    src := "class Foo\n{\n  Int x\n}"
    r := parse(src)
    cls := r.nodes.find |n| { n.kind == AstNodeKind.classDef }
    field := cls.children[0]
    verifyNotNull(field.parent)
    verifyEq(field.parent.name, "Foo")
  }

  Void testQname()
  {
    src := "class Foo\n{\n  Void run() {}\n}"
    r := parse(src)
    cls := r.nodes.find |n| { n.kind == AstNodeKind.classDef }
    m := cls.children.find |c| { c.name == "run" }
    verifyEq(m.qname, "Foo.run")
  }

  // ── AstNode helpers ───────────────────────────────────────────────────────────

  Void testIsType()
  {
    src := "class A {}\nmixin B {}\nenum class C {}"
    r := parse(src)
    r.nodes.each |n|
    {
      if (n.kind == AstNodeKind.usingDef) return
      verify(n.isType)
    }
  }

  Void testIsSlot()
  {
    src := "class Foo\n{\n  Int x\n  Void run() {}\n  new make() {}\n}"
    r := parse(src)
    cls := r.nodes.find |n| { n.kind == AstNodeKind.classDef }
    cls.children.each |c| { verify(c.isSlot) }
  }

  // ── symbolKind ────────────────────────────────────────────────────────────────

  Void testSymbolKindClass()
  {
    src := "class Foo {}"
    r := parse(src)
    n := r.nodes.find |n| { n.kind == AstNodeKind.classDef }
    verifyEq(n.symbolKind, DocumentSymbol.classKind)
  }

  Void testSymbolKindMixin()
  {
    src := "mixin Bar {}"
    r := parse(src)
    n := r.nodes.find |n| { n.kind == AstNodeKind.mixinDef }
    verifyEq(n.symbolKind, DocumentSymbol.interfaceKind)
  }

  Void testSymbolKindEnum()
  {
    src := "enum class Status { Active }"
    r := parse(src)
    n := r.nodes.find |n| { n.kind == AstNodeKind.enumDef }
    verifyEq(n.symbolKind, DocumentSymbol.enumKind)
  }

  // ── block comment skipping ────────────────────────────────────────────────────

  Void testBlockCommentSkipped()
  {
    src := "/* this is a block comment */\nclass Foo {}"
    r := parse(src)
    cls := r.nodes.find |n| { n.kind == AstNodeKind.classDef }
    verifyNotNull(cls)
    verifyEq(cls.name, "Foo")
  }

  // ── error recovery ────────────────────────────────────────────────────────────

  Void testErrorRecovery()
  {
    // Garbage line before a valid class - parser should still find the class
    src := "this is garbage\nclass Valid {}"
    r := parse(src)
    cls := r.nodes.find |n| { n.kind == AstNodeKind.classDef }
    verifyNotNull(cls)
    verifyEq(cls.name, "Valid")
  }

  // ── URI stored in result ──────────────────────────────────────────────────────

  Void testResultUri()
  {
    r := parser.parse("file:///my.fan", "")
    verifyEq(r.uri, "file:///my.fan")
  }

  // ── range information ─────────────────────────────────────────────────────────

  Void testClassRange()
  {
    src := "class Foo\n{\n}"
    r := parse(src)
    cls := r.nodes.find |n| { n.kind == AstNodeKind.classDef }
    verifyEq(cls.range.start.line, 0)
    verifyEq(cls.selectionRange.start.line, 0)
  }

  Void testFieldSelectionRange()
  {
    src := "class Foo\n{\n  Int myField\n}"
    r := parse(src)
    cls := r.nodes.find |n| { n.kind == AstNodeKind.classDef }
    field := cls.children.find |c| { c.name == "myField" }
    verifyNotNull(field)
    // Selection range points to the name
    verifyEq(field.selectionRange.start.line, 2)
  }

  Void testFieldInitWithCallIsFieldNotMethod()
  {
    src := "class Foo\n{\n  Str x := foo()\n}"
    r := parse(src)
    cls := r.nodes.find |n| { n.kind == AstNodeKind.classDef }
    field := cls.children.find |c| { c.name == "x" }
    verifyNotNull(field)
    verifyEq(field.kind, AstNodeKind.fieldDef)
    verifyNull(cls.children.find |c| { c.kind == AstNodeKind.methodDef })
  }

  Void testUsingAsAliasStripsAlias()
  {
    r := parse("using concurrent::Actor as A")
    verifyEq(r.nodes[0].name, "concurrent::Actor")
  }

  Void testLiteralBracesDoNotConsumeSlots()
  {
    src := [
      "class Foo // {",
      "/* { */",
      "{",
      "  Str text := \"{\"",
      "  Int ch := '{'",
      "  Str multi := \"\"\"",
      "    } Fake field",
      "    \"\"\"",
      "  Void run() {",
      "    echo(\"} \\\" {\") // }",
      "    ch := '}'",
      "    /* }",
      "       { */",
      "    if (true) { if (true) { echo(\"}\") } }",
      "  }",
      "  Int after",
      "}",
      "class Next {}"
    ].join("\n")
    r := parse(src)
    verifyEq(r.errors.size, 0)
    verifyEq(r.nodes.map |n->Str| { n.name }, ["Foo", "Next"])
    verifyEq(r.nodes[0].children.map |n->Str| { n.name }, ["text", "ch", "multi", "run", "after"])
    verifyEq(r.nodes[0].children[3].range.end.line, 14)
    verifyEq(r.nodes[0].range.end.line, 16)
  }

  Void testMethodOpeningLineAndNextLineBraceDepth()
  {
    src := [
      "class Foo {",
      "  Void first() { echo(\"{\") }",
      "  Void second()",
      "  // {",
      "  { echo(\"}\") }",
      "  Void third()",
      "  {",
      "    echo(\"}\")",
      "  }",
      "  Int after",
      "}",
      "class Next {}"
    ].join("\n")
    r := parse(src)
    verifyEq(r.errors.size, 0)
    verifyEq(r.nodes.size, 2)
    verifyEq(r.nodes[0].children.map |n->Str| { n.name }, ["first", "second", "third", "after"])
    verifyEq(r.nodes[0].children[0].range.end.line, 1)
    verifyEq(r.nodes[0].children[1].range.end.line, 4)
    verifyEq(r.nodes[0].children[2].range.end.line, 8)
  }

  Void testBodyRefsSkipLiteralsAndComments()
  {
    src := [
      "class Foo {",
      "  Void run() {",
      "    a := \"Fake() \\\" Escaped()\"",
      "    b := 'X'",
      "    c := '\\\''",
      "    d := \"\"\" Triple()",
      "      Hidden() }",
      "      \"\"\"; Real()",
      "    // Comment()",
      "    /* Block()",
      "       HiddenBlock() */ Visible()",
      "    actual()",
      "  }",
      "}"
    ].join("\n")
    r := parse(src)
    verifyEq(r.errors.size, 0)
    verifyEq(r.bodyRefs.map |ref->Str| { ref.name }, ["Real", "Visible"])
    calls := r.nodes[0].children[0].bodyCallRefs
    verifyEq(calls.map |ref->Str| { ref.name }, ["Real", "Visible", "actual"])
    verifyEq(r.bodyRefs[0].range.start.line, 7)
    verifyEq(r.bodyRefs[0].range.start.character, 11)
    verifyEq(calls[1].range.start.character, 24)

    // Lexical state must not leak between documents parsed by the same parser.
    parse("/* unfinished")
    r = parse("class Clean {\n  Void run() { Real() }\n}")
    verifyEq(r.bodyRefs.map |ref->Str| { ref.name }, ["Real"])
  }

  Void testTabbedTypeKeywords()
  {
    r := parse("mixin\tM {}\nenum\tclass\tE {}\nfacet\tclass\tF {}\nclass\tC {}")
    verifyEq(r.nodes.size, 4)
    verifyEq(r.nodes[0].kind, AstNodeKind.mixinDef)
    verifyEq(r.nodes[0].name, "M")
    verifyEq(r.nodes[1].kind, AstNodeKind.enumDef)
    verifyEq(r.nodes[2].kind, AstNodeKind.facetClassDef)
    verifyEq(r.nodes[3].kind, AstNodeKind.classDef)
  }

  Void testExplicitHeritage()
  {
    r := parse("class Foo : Bar, M {}\nclass Qualified : pod::Base, pod::Mix {}\nclass Plain {}\nclass Commented {} // : Fake")
    verifyEq(r.nodes.size, 4)
    verifyEq(r.nodes[0].baseType, "Bar")
    verifyEq(r.nodes[0].mixins, ["M"])
    verifyEq(r.nodes[1].baseType, "pod::Base")
    verifyEq(r.nodes[1].mixins, ["pod::Mix"])
    verifyNull(r.nodes[2].baseType)
    verifyEq(r.nodes[2].mixins, Str[,])
    verifyNull(r.nodes[3].baseType)
    verifyEq(r.nodes[3].mixins, Str[,])
  }

  Void testNestedTypesAreChildren()
  {
    r := parse([
      "class Outer {",
      "  private class Inner : Base {",
      "    class Deep {}",
      "    Void run() {}",
      "  }",
      "  mixin\tM {}",
      "  enum class E {",
      "    One",
      "  }",
      "  facet class F // : Fake",
      "  {",
      "  }",
      "  Int after",
      "}",
      "class Next {}"
    ].join("\n"))
    verifyEq(r.errors.size, 0)
    verifyEq(r.nodes.map |n->Str| { n.name }, ["Outer", "Next"])
    outer := r.nodes[0]
    verifyEq(outer.children.map |n->Str| { n.name }, ["Inner", "M", "E", "F", "after"])
    inner := outer.children[0]
    verifyEq(inner.kind, AstNodeKind.classDef)
    verifySame(inner.parent, outer)
    verifyEq(inner.modifiers, ["private"])
    verifyEq(inner.baseType, "Base")
    verifyNull(outer.baseType)
    verifyEq(inner.children.map |n->Str| { n.name }, ["Deep", "run"])
    verifySame(inner.children[0].parent, inner)
    verifyEq(inner.range.end.line, 4)
    verifyEq(outer.range.end.line, 13)
    verifyEq(outer.children[1].kind, AstNodeKind.mixinDef)
    verifyEq(outer.children[2].kind, AstNodeKind.enumDef)
    verifyEq(outer.children[2].children[0].name, "One")
    verifyEq(outer.children[3].kind, AstNodeKind.facetClassDef)
    verifyNull(outer.children[3].baseType)
  }

  Void testStatementsAreNotSlotsDuringRecovery()
  {
    // At type depth (e.g. while editing a missing method header), these
    // statements must not produce bogus methods or fields.
    statements := ["if (x) foo()", "for (i := 0; i < 2; i++) foo()",
      "while (x) foo()", "try { foo() }", "switch (x) { foo() }",
      "catch (Err e) { foo() }", "finally { foo() }", "else foo()",
      "return foo()", "throw Err()", "list.each |x| { foo() }",
      "list.each() |x| { foo() }", "list.each |x| { y := x }"]
    statements.each |statement|
    {
      r := parse("class Foo {\n  $statement\n  Void after() {}\n  Int iffy\n}")
      verifyEq(r.errors.size, 0)
      verifyEq(r.nodes[0].children.map |n->Str| { n.name }, ["after", "iffy"])
    }
  }

  Void testMethodBodyLocalsAndClosures()
  {
    r := parse([
      "class Foo {",
      "  Void run(Int arg) {",
      "    x := 1",
      "    Str label := \"text\"",
      "    list.each |item| {",
      "      nested := item",
      "    }",
      "    if (x) foo()",
      "    // fake := 2",
      "    echo(\"hidden := 3\")",
      "    this.member := 4",
      "    Upper := 5",
      "    return ignored := 6",
      "  }",
      "  Void after() { inline := 7 }",
      "}"
    ].join("\n"))
    verifyEq(r.errors.size, 0)
    cls := r.nodes[0]
    verifyEq(cls.children.map |n->Str| { n.name }, ["run", "after"])
    method := cls.children[0]
    verifyEq(method.children.map |n->Str| { n.name }, ["arg", "x", "label", "nested"])
    method.children.each |local|
    {
      verifyEq(local.kind, AstNodeKind.localDef)
      verifySame(local.parent, method)
    }
    x := method.children[1]
    verifyNull(x.typeName)
    verifyEq(x.range.start.line, 2)
    verifyEq(x.range.end.line, 2)
    verifyEq(x.selectionRange.start.character, 4)
    verifyEq(x.selectionRange.end.character, 5)
    verifyEq(method.children[2].typeName, "Str")
    verifyEq(method.range.end.line, 13)
    verifyEq(cls.children[1].children[0].name, "inline")
  }

  Void testMultilineFacetUsages()
  {
    r := parse([
      "@Foo {",
      "  class Hidden {}",
      "  nested = Obj { echo(\"}\") }",
      "}",
      "class Visible {",
      "  @Serial",
      "  Str name",
      "  @Foo {",
      "    fake := make()",
      "    nested = Obj {",
      "      echo(\"}\") // }",
      "    }",
      "  }",
      "  Void run() {}",
      "  @Foo",
      "  {",
      "    hidden = true",
      "  }",
      "  Int after",
      "}",
      "class Next {}"
    ].join("\n"))
    verifyEq(r.errors.size, 0)
    verifyEq(r.nodes.map |n->Str| { n.name }, ["Visible", "Next"])
    verifyEq(r.nodes[0].children.map |n->Str| { n.name }, ["name", "run", "after"])
    verifyEq(r.nodes[0].range.end.line, 19)
  }

  Void testUnclosedFacetAndParserReuse()
  {
    r := parse("class Foo {\n  @Foo {\n    hidden := make()")
    verifyEq(r.nodes[0].children.size, 0)
    verify(r.errors.size > 0)
    r = parse("class Clean {\n  @Serial\n  Int count\n}")
    verifyEq(r.errors.size, 0)
    verifyEq(r.nodes[0].children[0].name, "count")
  }

  Void testSwitchCasesAreNotSlots()
  {
    r := parse([
      "class Foo {",
      "  case Foo:",
      "  case Bar: call()",
      "  Void run() {",
      "    switch (value) {",
      "      case Foo: call()",
      "      default: break",
      "    }",
      "  }",
      "  Int after",
      "}"
    ].join("\n"))
    verifyEq(r.errors.size, 0)
    verifyEq(r.nodes[0].children.map |n->Str| { n.name }, ["run", "after"])
    verifyEq(r.nodes[0].children[0].children.size, 0)
  }

  Void testTypedClosureParamsAreMethodLocals()
  {
    source := [
      "class Foo {",
      "  Void run() {",
      "    list.each |Str x, Int y| {",
      "      list.each |sys::Str? label->Void| { echo(label) }",
      "    }",
      "    fn := |Str[] names, [Str:Int] counts|",
      "    { echo(names) }",
      "  }",
      "  Void after() { list.each |Int z| {} }",
      "}"
    ]
    r := parse(source.join("\n"))
    verifyEq(r.errors.size, 0)
    method := r.nodes[0].children[0]
    verifyEq(method.children.map |n->Str| { n.name }, ["x", "y", "label", "fn", "names", "counts"])
    verifyEq(method.children[0].typeName, "Str")
    verifyEq(method.children[1].typeName, "Int")
    verifyEq(method.children[2].typeName, "sys::Str?")
    verifyEq(method.children[4].typeName, "Str[]")
    verifyEq(method.children[5].typeName, "[Str:Int]")
    method.children.each |local|
    {
      verifyEq(local.kind, AstNodeKind.localDef)
      verifySame(local.parent, method)
      sel := local.selectionRange
      verifyEq(source[sel.start.line][sel.start.character..<sel.end.character], local.name)
    }
    verifyEq(method.children[0].selectionRange.start.line, 2)
    verifyEq(method.children[1].selectionRange.start.character, 26)
    verifyEq(r.nodes[0].children[1].children.map |n->Str| { n.name }, ["z"])
  }

  Void testClosureParamsIgnoreNonClosures()
  {
    r := parse([
      "class Foo {",
      "  Void run() {",
      "    // list.each |Str comment| {}",
      "    echo(\"|Str literal| {}\")",
      "    /* list.each |Str hidden| {} */",
      "    |Str typed| callback",
      "    if (a || b) {}",
      "    list.each |item| {}",
      "    list.each |Str missing {",
      "    }",
      "  }",
      "}"
    ].join("\n"))
    verifyEq(r.errors.size, 0)
    verifyEq(r.nodes[0].children[0].children.size, 0)
  }

  Void testOnceMethodModifier()
  {
    r := parse("class Foo {\n  private once Str cached() { return \"x\" }\n  Int after\n}")
    verifyEq(r.errors.size, 0)
    verifyEq(r.nodes[0].children.map |n->Str| { n.name }, ["cached", "after"])
    method := r.nodes[0].children[0]
    verifyEq(method.kind, AstNodeKind.methodDef)
    verifyEq(method.returnType, "Str")
    verifyEq(method.modifiers, ["private", "once"])
  }

  Void testTypeLevelBlocksAreNotMethods()
  {
    r := parse([
      "class Foo {",
      "  static { init() }",
      "  static {",
      "    if (true) { init() }",
      "    hidden := 1",
      "  }",
      "  static",
      "  { init() }",
      "  { init() }",
      "  {",
      "    hidden := make()",
      "  }",
      "  static Void real() {}",
      "  Int after",
      "}",
      "class Next {}"
    ].join("\n"))
    verifyEq(r.errors.size, 0)
    verifyEq(r.nodes.map |n->Str| { n.name }, ["Foo", "Next"])
    verifyEq(r.nodes[0].children.map |n->Str| { n.name }, ["real", "after"])
    verifyEq(r.nodes[0].children[0].modifiers, ["static"])
    verifyEq(r.nodes[0].range.end.line, 14)
  }

  Void testFunctionTypesRemainSlots()
  {
    r := parse("class Foo {\n  |Int->Void| callback\n  Void each(|Int->Void| f) {}\n  |->Void| factory() {}\n}")
    verifyEq(r.errors.size, 0)
    verifyEq(r.nodes[0].children.map |n->Str| { n.name }, ["callback", "each", "factory"])
    verifyEq(r.nodes[0].children[0].kind, AstNodeKind.fieldDef)
    verifyEq(r.nodes[0].children[1].kind, AstNodeKind.methodDef)
    verifyEq(r.nodes[0].children[2].kind, AstNodeKind.methodDef)
  }

  Void testExactParameterDeclarationTokens()
  {
    text := "class A\n{\n  Void process(Str s, Str ss := \"s\", |Str s->Void| callback := null) {}\n}\n"
    r := parse(text)
    method := r.nodes.first.children.first
    verifyEq(method.children.map |n->Str| { n.name }, ["s", "ss", "callback"])
    line := text.splitLines[2]
    cols := [line.index("Str s,") + 4, line.index("Str ss") + 4, line.index("callback")]
    method.children.each |n, i|
    {
      verifyEq(n.selectionRange.start.line, 2)
      verifyEq(n.selectionRange.start.character, cols[i])
      verifyEq(line[n.selectionRange.start.character..<n.selectionRange.end.character], n.name)
    }
    verifyEq(method.children.last.typeName, "|Str s->Void|")
  }
}
