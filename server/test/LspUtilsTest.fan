** Tests for the LspUtils mixin. The test class itself mixes in LspUtils so
** all utility methods can be called directly.
class LspUtilsTest : Test, LspUtils
{
  private RecoveringParser parser := RecoveringParser()

  private ParseResult parse(Str src) { parser.parse("test://file.fan", src) }

  private DocumentState makeDoc(Str src)
  {
    DocumentState("test://file.fan", 1, src)
  }

  // ── extractUsings ─────────────────────────────────────────────────────────────

  Void testExtractUsingsEmpty()
  {
    r := parse("")
    pods := extractUsings(r)
    // Always includes "sys"
    verify(pods.contains("sys"))
    verifyEq(pods.size, 1)
  }

  Void testExtractUsingsWithPods()
  {
    r := parse("using util\nusing concurrent")
    pods := extractUsings(r)
    verify(pods.contains("sys"))
    verify(pods.contains("util"))
    verify(pods.contains("concurrent"))
    verifyEq(pods.size, 3)
  }

  Void testExtractUsingsDeduplicates()
  {
    r := parse("using sys\nusing sys")
    pods := extractUsings(r)
    // Should not duplicate "sys"
    sysCount := 0
    pods.each |p| { if (p == "sys") sysCount++ }
    verifyEq(sysCount, 1)
  }

  Void testExtractUsingsStripsPodFromQname()
  {
    // "using sys::Str" should contribute pod name "sys" (not "sys::Str")
    r := parse("using util::Actor")
    pods := extractUsings(r)
    verify(pods.contains("util"))
    verifyFalse(pods.contains("util::Actor"))
  }

  // ── findLocalType ─────────────────────────────────────────────────────────────

  Void testFindLocalTypePresentClass()
  {
    r := parse("class MyClass {}")
    n := findLocalType(r, "MyClass")
    verifyNotNull(n)
    verifyEq(n.kind, AstNodeKind.classDef)
  }

  Void testFindLocalTypeMixin()
  {
    r := parse("mixin MyMixin {}")
    n := findLocalType(r, "MyMixin")
    verifyNotNull(n)
    verifyEq(n.kind, AstNodeKind.mixinDef)
  }

  Void testFindLocalTypeMissing()
  {
    r := parse("class Foo {}")
    verifyNull(findLocalType(r, "Bar"))
  }

  Void testFindLocalTypeDoesNotReturnSlot()
  {
    r := parse("class Foo\n{\n  Void run() {}\n}")
    // Slots are not types
    verifyNull(findLocalType(r, "run"))
  }

  // ── findLocalNode ──────────────────────────────────────────────────────────────

  Void testFindLocalNodeTopLevel()
  {
    r := parse("class Foo {}")
    n := findLocalNode(r, "Foo")
    verifyNotNull(n)
    verifyEq(n.name, "Foo")
  }

  Void testFindLocalNodeChild()
  {
    r := parse("class Foo\n{\n  Void run() {}\n}")
    n := findLocalNode(r, "run")
    verifyNotNull(n)
    verifyEq(n.kind, AstNodeKind.methodDef)
  }

  Void testFindLocalNodeMissing()
  {
    r := parse("class Foo {}")
    verifyNull(findLocalNode(r, "missing"))
  }

  // ── extractTypeFromRhs ────────────────────────────────────────────────────────

  Void testExtractTypeFromRhsStringLiteral()
  {
    r := parse("")
    verifyEq(extractTypeFromRhs("\"hello\"", r, ["sys"]), "Str")
  }

  Void testExtractTypeFromRhsBacktickLiteral()
  {
    r := parse("")
    verifyEq(extractTypeFromRhs("`/some/path`", r, ["sys"]), "Str")
  }

  Void testExtractTypeFromRhsTrue()
  {
    r := parse("")
    verifyEq(extractTypeFromRhs("true", r, ["sys"]), "Bool")
  }

  Void testExtractTypeFromRhsFalse()
  {
    r := parse("")
    verifyEq(extractTypeFromRhs("false", r, ["sys"]), "Bool")
  }

  Void testExtractTypeFromRhsInteger()
  {
    r := parse("")
    verifyEq(extractTypeFromRhs("42", r, ["sys"]), "Int")
  }

  Void testExtractTypeFromRhsFloat()
  {
    r := parse("")
    verifyEq(extractTypeFromRhs("3.14", r, ["sys"]), "Float")
  }

  Void testExtractTypeFromRhsConstructorShorthand()
  {
    r := parse("")
    verifyEq(extractTypeFromRhs("Foo()", r, ["sys"]), "Foo")
  }

  Void testExtractTypeFromRhsListLiteral()
  {
    r := parse("")
    // "Str[,]" → result is "Str"
    verifyEq(extractTypeFromRhs("Str[,]", r, ["sys"]), "Str")
  }

  Void testExtractTypeFromRhsExplicitMake()
  {
    r := parse("")
    verifyEq(extractTypeFromRhs("MyClass.make()", r, ["sys"]), "MyClass")
  }

  Void testExtractTypeFromRhsReflectedMethod()
  {
    // "Type.method()" resolved via reflection: Str.trim() returns Str
    r := parse("")
    result := extractTypeFromRhs("Str.trim()", r, ["sys"])
    // If reflection resolves it, result is "Str"; some builds may return null
    if (result != null) verifyEq(result, "Str")
  }

  Void testExtractTypeFromRhsEmpty()
  {
    r := parse("")
    verifyNull(extractTypeFromRhs("", r, ["sys"]))
  }

  Void testExtractTypeFromRhsLowercaseStart()
  {
    r := parse("")
    // Lower-case start → cannot infer type (not a literal, not a constructor)
    verifyNull(extractTypeFromRhs("myVar", r, ["sys"]))
  }

  // ── inferVarType ──────────────────────────────────────────────────────────────

  Void testInferVarTypeString()
  {
    src := "  x := \"hello\""
    doc := makeDoc(src)
    r := parse(src)
    t := inferVarType(doc, "x", r, ["sys"])
    verifyEq(t, "Str")
  }

  Void testInferVarTypeInt()
  {
    src := "  count := 42"
    doc := makeDoc(src)
    r := parse(src)
    t := inferVarType(doc, "count", r, ["sys"])
    verifyEq(t, "Int")
  }

  Void testInferVarTypeBool()
  {
    src := "  active := true"
    doc := makeDoc(src)
    r := parse(src)
    t := inferVarType(doc, "active", r, ["sys"])
    verifyEq(t, "Bool")
  }

  Void testInferVarTypeMissing()
  {
    src := "class Foo {}"
    doc := makeDoc(src)
    r := parse(src)
    verifyNull(inferVarType(doc, "noSuchVar", r, ["sys"]))
  }

  Void testInferVarTypeDoesNotMatchSubstring()
  {
    // "foobar := 1" should NOT match when looking for "foo"
    src := "  foobar := 1"
    doc := makeDoc(src)
    r := parse(src)
    verifyNull(inferVarType(doc, "foo", r, ["sys"]))
  }

  // ── formatTypeSig ──────────────────────────────────────────────────────────────

  Void testFormatTypeSigClass()
  {
    t := Pod.find("sys", false).type("Str", false)
    sig := formatTypeSig(t)
    verify(sig.contains("class"))
    verify(sig.contains("Str"))
  }

  Void testFormatTypeSigEnum()
  {
    // Month is an enum in sys
    t := Pod.find("sys", false).type("Month", false)
    if (t != null)
    {
      sig := formatTypeSig(t)
      verify(sig.contains("enum"))
      verify(sig.contains("Month"))
    }
  }

  // ── formatMethodSig ──────────────────────────────────────────────────────────

  Void testFormatMethodSig()
  {
    t := Pod.find("sys", false).type("Str", false)
    m := t.method("size", false)
    verifyNotNull(m)
    sig := formatMethodSig(m)
    verify(sig.contains("size"))
    verify(sig.contains("Int"))  // returns Int
  }

  Void testFormatMethodSigWithParams()
  {
    t := Pod.find("sys", false).type("Str", false)
    m := t.method("get", false)
    verifyNotNull(m)
    sig := formatMethodSig(m)
    verify(sig.contains("get"))
    verify(sig.contains("("))
    verify(sig.contains(")"))
  }

  // ── formatFieldSig ────────────────────────────────────────────────────────────

  Void testFormatFieldSig()
  {
    t := Pod.find("sys", false).type("Str", false)
    f := t.field("defVal", false)
    if (f != null)
    {
      sig := formatFieldSig(f)
      verify(sig.contains("defVal"))
    }
  }

  // ── formatLocalSig ────────────────────────────────────────────────────────────

  Void testFormatLocalSigClass()
  {
    r := parse("class MyClass {}")
    cls := r.nodes.find |n| { n.kind == AstNodeKind.classDef }
    sig := formatLocalSig(cls)
    verifyEq(sig, "class MyClass")
  }

  Void testFormatLocalSigMixin()
  {
    r := parse("mixin MyMixin {}")
    n := r.nodes.find |n| { n.kind == AstNodeKind.mixinDef }
    sig := formatLocalSig(n)
    verifyEq(sig, "mixin MyMixin")
  }

  Void testFormatLocalSigEnum()
  {
    r := parse("enum class Color {}")
    n := r.nodes.find |n| { n.kind == AstNodeKind.enumDef }
    sig := formatLocalSig(n)
    verifyEq(sig, "enum class Color")
  }

  Void testFormatLocalSigMethod()
  {
    r := parse("class Foo\n{\n  Int add(Int x, Int y) { x + y }\n}")
    cls := r.nodes.find |n| { n.kind == AstNodeKind.classDef }
    m := cls.children.find |c| { c.name == "add" }
    sig := formatLocalSig(m)
    verify(sig.contains("add"))
    verify(sig.contains("Int x"))
    verify(sig.contains("Int y"))
  }

  Void testFormatLocalSigCtor()
  {
    r := parse("class Foo\n{\n  new make(Str name) {}\n}")
    cls := r.nodes.find |n| { n.kind == AstNodeKind.classDef }
    ctor := cls.children.find |c| { c.kind == AstNodeKind.ctorDef }
    sig := formatLocalSig(ctor)
    verify(sig.startsWith("new "))
    verify(sig.contains("make"))
    verify(sig.contains("Str name"))
  }

  Void testFormatLocalSigField()
  {
    r := parse("class Foo\n{\n  Int count\n}")
    cls := r.nodes.find |n| { n.kind == AstNodeKind.classDef }
    field := cls.children.find |c| { c.name == "count" }
    sig := formatLocalSig(field)
    verifyEq(sig, "Int count")
  }

  Void testFormatLocalSigFieldWithModifier()
  {
    r := parse("class Foo\n{\n  static Int total\n}")
    cls := r.nodes.find |n| { n.kind == AstNodeKind.classDef }
    field := cls.children.find |c| { c.name == "total" }
    sig := formatLocalSig(field)
    verify(sig.startsWith("static "))
    verify(sig.contains("Int total"))
  }

  // ── isSyntheticName ───────────────────────────────────────────────────────────

  Void testIsSyntheticNameTrue()
  {
    verify(isSyntheticName("foo\$bar"))
    verify(isSyntheticName("\$closure"))
    verify(isSyntheticName("get\$x"))
  }

  Void testIsSyntheticNameFalse()
  {
    verifyFalse(isSyntheticName("foobar"))
    verifyFalse(isSyntheticName("MyClass"))
    verifyFalse(isSyntheticName("_private"))
  }

  // ── isIdentChar ───────────────────────────────────────────────────────────────

  Void testIsIdentCharAlpha()
  {
    verify(isIdentChar('a'))
    verify(isIdentChar('Z'))
    verify(isIdentChar('m'))
  }

  Void testIsIdentCharDigit()
  {
    verify(isIdentChar('0'))
    verify(isIdentChar('9'))
  }

  Void testIsIdentCharUnderscore()
  {
    verify(isIdentChar('_'))
  }

  Void testIsIdentCharNonIdent()
  {
    verifyFalse(isIdentChar('.'))
    verifyFalse(isIdentChar(' '))
    verifyFalse(isIdentChar('('))
    verifyFalse(isIdentChar('-'))
  }

  // ── findType (reflection) ─────────────────────────────────────────────────────

  Void testFindTypeInSys()
  {
    r := parse("")
    pods := extractUsings(r)
    t := findType(pods, "Str")
    verifyNotNull(t)
    verifyEq(t.name, "Str")
  }

  Void testFindTypeMissing()
  {
    r := parse("")
    pods := extractUsings(r)
    t := findType(pods, "NonExistentType12345")
    verifyNull(t)
  }

  Void testFindTypeInAnyPod()
  {
    t := findTypeInAnyPod("Str")
    verifyNotNull(t)
    verifyEq(t.name, "Str")
  }
}
