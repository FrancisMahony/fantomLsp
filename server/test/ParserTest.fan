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
}
