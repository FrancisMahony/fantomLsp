using compiler

class SemanticIndexerTest : Test
{
  Void testExactBindingsAndOwners()
  {
    source := "virtual class A\n" +
      "{\n  virtual Void close() {}\n  Void run() {}\n  Str name := \"a\"\n  B foo() { B() }\n}\n" +
      "class B : A { override Void close() {} }\n" +
      "mixin M { abstract Void close() }\n" +
      "class Util { private new create() {} static Int make() { 1 } }\n" +
      "class Foo { new make() {} }\n" +
      "class Caller\n{\n" +
      "  Int count := Util.make()\n" +
      "  static Int fixed := Util.make()\n" +
      "  Str[] names := [\"a\"].map |s| { s.upper }\n" +
      "  Void go(B b, A[] list)\n  {\n" +
      "    x := b\n    b.close()\n    b.run()\n    Util.make()\n    alpha::Util.make()\n" +
      "\tx.foo().close()\n" +
      "    list.each |v| { v.close(); x.run() }\n" +
      "    c := B() { it.run() }\n" +
      "    slot := Str#size\n    n := b.name\n    f := Foo()\n" +
      "    list.each |v| { list.each |w| { x.run(); b.close() } }\n" +
      "  }\n}\n"
    withCompile(source) |c, texts|
    {
      verify(c.errs.isEmpty, c.errs.toStr)
      s := extract(c, texts)
      verify(s.resolved)
      verify(s.isImmutable)
      occs := s.occByFile.vals.flatten as Occurrence[]
      assertAt(s, source, "b.close()", "close", "alpha::B.close")
      assertAt(s, source, "b.run()", "run", "alpha::A.run")
      assertAt(s, source, "Util.make()\n    alpha", "make", "alpha::Util.make")
      assertAt(s, source, "alpha::Util.make()", "make", "alpha::Util.make")
      assertAt(s, source, "x.foo().close()", "close", "alpha::B.close")
      assertAt(s, source, "v.close();", "close", "alpha::A.close", "alpha::Caller.go")
      assertAt(s, source, "it.run()", "run", "alpha::A.run", "alpha::Caller.go")
      assertAt(s, source, "Str#size", "size", "sys::Str.size")
      assertAt(s, source, "b.name", "name", "alpha::A.name")
      assertAt(s, source, "count := Util.make()", "make", "alpha::Util.make", "alpha::Caller.count")
      assertAt(s, source, "fixed := Util.make()", "make", "alpha::Util.make", "alpha::Caller.fixed")
      assertAt(s, source, "s.upper", "upper", "sys::Str.upper", "alpha::Caller.names")
      x := s.decls.vals.find |d| { SymbolKey.isLocal(d.key) && slice(source, d.nameRange) == "x" }
      b := s.decls.vals.find |d| { SymbolKey.isLocal(d.key) && slice(source, d.nameRange) == "b" }
      v := s.decls.vals.findAll |d| { SymbolKey.isLocal(d.key) && slice(source, d.nameRange) == "v" }
        .sort |left, right -> Int| { left.nameRange.start.line <=> right.nameRange.start.line }.first
      verifyNotNull(x); verifyNotNull(b); verifyNotNull(v)
      assertAt(s, source, "x.foo()", "x", x.key)
      assertAt(s, source, "x.run(); b.close()", "x", x.key)
      assertAt(s, source, "b.close()", "b", b.key)
      assertAt(s, source, "v.close();", "v", v.key)
      ctor := assertAt(s, source, "f := Foo()", "Foo", "alpha::Foo.make")
      verifyEq(ctor.kind, OccKind.ctorShorthand)
      verifyEq(ctor.altKey, "alpha::Foo")
      implicit := assertAt(s, source, "c := B()", "B", "alpha::B")
      verifyEq(implicit.kind, OccKind.ctorShorthand)
      verifyEq(implicit.altKey, "alpha::B.make")
      verifyFalse(s.decls.keys.any |k| { k.contains("\$") })
      verifyEq(s.decls["alpha::B"].superTypeKeys, ["alpha::A"])
      assertAt(s, source, "class B : A", "A", "alpha::A")
      assertAt(s, source, "Void go(B b", "B", "alpha::B")
      verifyEq(s.fileHash.vals.first, source.toBuf.toDigest("SHA-1").toHex)
      verify(s.openText.isEmpty)
      occs.each |o|
      {
        verify(!slice(source, o.range).isEmpty)
        verifyEq(o.range.start.line, o.range.end.line)
        verify(s.occByKey[o.key].contains(o))
        verifyEq(occs.findAll |other| { other.key == o.key &&
          other.range.start.line == o.range.start.line &&
          other.range.start.character == o.range.start.character &&
          other.range.end.character == o.range.end.character }.size, 1)
      }
    }
  }

  Void testRangesAndTypeRefs()
  {
    source := "** type documentation\n@Deprecated { msg = \"R\" }\npublic class R\n{\n" +
      "  ** field documentation\n  @Deprecated { msg = \"value\" }\n\tpublic Str value := \"value\"\n" +
      "  ** method documentation\n  @Deprecated { msg = \"go\" }\n\tpublic Str go(Str arg) { arg }\n}\n"
    withCompile(source) |c, texts|
    {
      verify(c.errs.isEmpty, c.errs.toStr)
      s := extract(c, texts)
      ["alpha::R", "alpha::R.value", "alpha::R.go"].each |key|
      {
        d := s.decls[key]
        verifyNotNull(d)
        verifyEq(slice(source, d.nameRange), SymbolKey.simpleName(key))
        verify(d.fullRange.start.line <= d.nameRange.start.line)
        verify(d.fullRange.end.line >= d.nameRange.end.line)
      }
      verifyEq(s.decls["alpha::R.value"].nameRange.start.character, 12)
      verifyEq(s.decls["alpha::R.go"].nameRange.start.character, 12)
      assertAt(s, source, "public Str value", "Str", "sys::Str")
      assertAt(s, source, "public Str go", "Str", "sys::Str")
      assertAt(s, source, "go(Str arg)", "Str", "sys::Str")
      verifyEq(s.decls["alpha::R"].fullRange.end.line, 10)
    }
  }

  Void testResolutionErrorsAndEarlyFailure()
  {
    withCompile("class X { Void ok(Str s) { s.upper } }\nclass Bad { Void bad(Str s) { s.noSuchMethod() } }") |c, texts|
    {
      verify(!c.errs.isEmpty)
      s := extract(c, texts)
      verify(s.resolved)
      verify(s.occByKey.containsKey("sys::Str.upper"))
      verifyFalse(s.occByKey.keys.any |k| { k.endsWith(".noSuchMethod") })
    }
    ["class X { MissingType go() { null } }", "class X { Void go( { }"].each |source|
    {
      withCompile(source) |c, texts|
      {
        verify(!c.errs.isEmpty)
        s := extract(c, texts)
        verifyFalse(s.resolved)
        verify(s.decls.isEmpty)
        verify(s.occByFile.isEmpty)
      }
    }
  }

  Void testLexicalBounds()
  {
    tokens := SemanticTokens("// name\n\t/* name */ \"name\" name; other\nname\n")
    r := tokens.find(Loc("x", 2, 1), "name", 0)
    verifyEq(r.start.character, 19)
    verifyEq(r.end.character, 23)
    verifyNull(tokens.find(Loc("x", 2, 24), "name", 0))
    verifyNotNull(tokens.find(Loc("x", 2, 24), "name", 20))
    verifyNull(SemanticTokens("/* name */ \"name\" // name").find(Loc("x", 1, 1), "name", 20))
    verifyNull(SemanticTokens("\n".mult(21) + "name").find(Loc("x", 1, 1), "name", 20))
  }

  Void testReviewCtorAndExpressionAnchors()
  {
    source := "class A { Str name := \"a\" }\nclass C { Str name := \"c\" }\n" +
      "class Foo { new make(Int n := 0) {} static const Int defVal := 1 }\n" +
      "class P { new make() {} }\nclass Q : P { new make(P p) {} }\n" +
      "class X\n{\n Void go(A a, C c)\n {\n" +
      "  f := Foo.make(Foo.defVal)\n  echo(\"\${a.name}\" + c.name)\n }\n}\n"
    withCompile(source) |c, texts|
    {
      verify(c.errs.isEmpty, c.errs.toStr)
      s := extract(c, texts)
      call := assertAt(s, source, "Foo.make(Foo.defVal)", "make", "alpha::Foo.make")
      verifyEq(call.kind, OccKind.call)
      verifyNull(call.altKey)
      assertAt(s, source, "Foo.defVal", "Foo", "alpha::Foo")
      assertAt(s, source, "Foo.defVal", "defVal", "alpha::Foo.defVal")
      assertAt(s, source, "new make(P p)", "P", "alpha::P")
      assertAt(s, source, "c.name)", "name", "alpha::C.name")
      assertAt(s, source, "a.name}", "name", "alpha::A.name")
      verifyFalse(s.occByFile.vals.flatten.any |Occurrence o -> Bool| { o.kind == OccKind.ctorShorthand })
    }
  }

  Void testFacetAndFunctionParameterDeclarations()
  {
    source := "class X\n{\n @Deprecated { msg = \"m\" } Str msg := \"z\"\n" +
      " Void go(|Int arg->Void| arg) { arg(1) }\n" +
      " Int x { get { &x } set { &x = it } }\n}\n"
    withCompile(source) |c, texts|
    {
      verify(c.errs.isEmpty, c.errs.toStr)
      s := extract(c, texts)
      assertAt(s, source, "Str msg :=", "msg", "alpha::X.msg")
      arg := s.decls.vals.find |d| { SymbolKey.isLocal(d.key) && slice(source, d.nameRange) == "arg" }
      verifyNotNull(arg)
      verifyEq(arg.nameRange.start.character, source.splitLines[3].index("| arg")+2)
      assertAt(s, source, "{ arg(1)", "arg", arg.key)
      verifyFalse(s.decls.vals.any |d| { SymbolKey.isLocal(d.key) && slice(source, d.nameRange) == "it" })
    }
  }

  Void testEarlyInheritanceFailureDoesNotProveResolution()
  {
    withCompile("class A { Void f() { echo(\"lit\"); x := 3; echo(x) } }\nclass B : A { override Void f() { echo(4) } }") |c, texts|
    {
      verify(!c.errs.isEmpty)
      verifyFalse(((SemanticTestCompiler)c).resolveExprComplete)
      s := extract(c, texts)
      verifyFalse(s.resolved)
      verify(s.decls.isEmpty)
      verify(s.occByFile.isEmpty)
      verifyFalse(SemanticIndexer().extract(c, texts).resolved)
    }
  }

  Void testOnceStaticAndClosureOwners()
  {
    source := "class X\n{\n static Int field := 1\n" +
      " once Str cached() { y := \"q\"; [1].each |i| { echo(i) }; return y.upper }\n" +
      " static { [1].each |j| { echo(j) }; echo(2) }\n}\n"
    withCompile(source) |c, texts|
    {
      verify(c.errs.isEmpty, c.errs.toStr)
      s := extract(c, texts)
      assertAt(s, source, "y.upper", "upper", "sys::Str.upper", "alpha::X.cached")
      assertAt(s, source, "echo(i)", "echo", "sys::Obj.echo", "alpha::X.cached")
      verifyNull(assertAt(s, source, "echo(j)", "echo", "sys::Obj.echo").enclosingSlotKey)
      verifyNull(assertAt(s, source, "echo(2)", "echo", "sys::Obj.echo").enclosingSlotKey)
      s.occByFile.vals.flatten.each |Occurrence o|
      { verify(o.enclosingSlotKey == null || !o.enclosingSlotKey.contains("\$")) }
      y := s.decls.vals.find |d| { SymbolKey.isLocal(d.key) && slice(source, d.nameRange) == "y" }
      verifyNotNull(y)
      assertAt(s, source, "y.upper", "y", y.key)
    }
  }

  Void testLargePodExtractionCost()
  {
    source := StrBuf().add("class Large\n{\n")
    1500.times |i| { source.add(" Void m${i}(Str p) { x := p; x.upper }\n") }
    source.add("}\n")
    withCompile(source.toStr) |c, texts|
    {
      verify(c.errs.isEmpty, c.errs.toStr)
      start := Duration.now
      s := extract(c, texts)
      elapsed := Duration.now-start
      verifyEq(s.occByKey["sys::Str.upper"].size, 1500)
      verifyEq(s.decls.size, 4501)
      echo("SemanticIndexer 1500 methods: ${elapsed.toMillis}ms")
      verify(elapsed < 10sec, "Extraction regression: $elapsed")
    }
  }

  ** Cross-pod shorthand identity comes from the file-backed workspace pod
  ** (never caller-pod decls, never JVM reflection); aliases and qualified
  ** spellings own their own token. Synthetic and installed ctors keep type keys.
  Void testCrossPodConstructorShorthandIdentity()
  {
    ws := TestWorkspace()
    c := null as Compiler
    try
    {
      alpha := ws.podName("alpha"); beta := ws.podName("beta")
      ws.buildPod(alpha, ["A.fan": "class Explicit\n{\n  new make() {}\n}\nclass Implicit {}\n" +
        "class Named\n{\n  new fromStr(Str s) {}\n}\n"])
      source := "using ${alpha}::Explicit as AE\nusing ${alpha}::Implicit\nusing ${alpha}::Named\n" +
        "class Explicit\n{\n  new make() {}\n}\n" +
        "class Holder\n{\n  new make(Obj o) {}\n}\n" +
        "class Main\n{\n  Void go()\n  {\n" +
        "    a := AE()\n    q := ${alpha}::Explicit()\n    l := Explicit()\n" +
        "    i := Implicit()\n    n := Named(\"x\")\n    v := Version(\"1.0\")\n" +
        "    h := Holder(AE())\n    f := [1].map |x| { AE() }\n  }\n}\n"
      dir := ws.writePod(beta, ["Main.fan": source], ["sys 1.0", "$alpha 1.0"])
      file := dir + `fan/Main.fan`
      input := CompilerInput()
      input.podName = beta
      input.summary = "cross-pod shorthand"
      input.version = Version("1.0")
      input.baseDir = dir
      input.srcFiles = [`fan/`]
      input.mode = CompilerInputMode.file
      input.output = CompilerOutputMode.transientPod
      input.depends = [Depend("sys 1.0"), Depend("$alpha 1.0")]
      input.ns = ws.namespace
      input.log = CompilerLog(Buf().out)
      c = SemanticTestCompiler(input)
      try { c.frontend } catch (CompilerErr e) {}
      verify(c.errs.isEmpty, c.errs.toStr)
      s := extract(c, [UriKey.canonical(file.normalize.uri.toStr): source])
      verify(s.resolved)
      // Caller pod has no decl for the target ctor; identity must still be exact.
      verifyNull(s.decls["$alpha::Explicit.make"])
      alias := assertAt(s, source, "a := AE()", "AE", "$alpha::Explicit.make")
      verifyEq(alias.kind, OccKind.ctorShorthand)
      verifyEq(alias.altKey, "$alpha::Explicit")
      qualified := assertAt(s, source, "q := ${alpha}::Explicit()", "Explicit", "$alpha::Explicit.make")
      verifyEq(qualified.kind, OccKind.ctorShorthand)
      verifyEq(qualified.altKey, "$alpha::Explicit")
      local := assertAt(s, source, "l := Explicit()", "Explicit", "$beta::Explicit.make")
      verifyEq(local.altKey, "$beta::Explicit")
      implicit := assertAt(s, source, "i := Implicit()", "Implicit", "$alpha::Implicit")
      verifyEq(implicit.kind, OccKind.ctorShorthand)
      verifyEq(implicit.altKey, "$alpha::Implicit.make")
      named := assertAt(s, source, "n := Named(", "Named", "$alpha::Named.fromStr")
      verifyEq(named.altKey, "$alpha::Named")
      installed := assertAt(s, source, "v := Version(", "Version", "sys::Version")
      verifyEq(installed.altKey, "sys::Version.fromStr")
      // Argument shorthand never moves the outer ctor's token, and vice versa.
      verifyEq(assertAt(s, source, "h := Holder(", "Holder", "$beta::Holder.make").altKey, "$beta::Holder")
      assertAt(s, source, "Holder(AE())", "AE", "$alpha::Explicit.make")
      closure := assertAt(s, source, "{ AE() }", "AE", "$alpha::Explicit.make", "$beta::Main.go")
      verifyEq(closure.kind, OccKind.ctorShorthand)
      // The using directive itself is not a shorthand occurrence.
      verifyEq((s.occByKey["$alpha::Explicit.make"] ?: Occurrence[,]).size, 4)
      verifyNull(Pod.find(alpha, false))
    }
    finally { c?.ns?.cleanup; ws.cleanup }
  }

  private SemanticSnapshot extract(Compiler c, Str:Str texts)
  { SemanticIndexer().extract(c, texts, ((SemanticTestCompiler)c).resolveExprComplete) }

  Void testAccessorBindingIdentity()
  {
    source := "class X\n{\n Int x := 0 { get { y := 5; w := 6; return y+w+&x } set { z := it; &x=z } }\n}\n"
    withCompile(source) |c, texts|
    {
      verify(c.errs.isEmpty, c.errs.toStr)
      s := extract(c, texts)
      ["y", "w", "z"].each |name|
      {
        d := s.decls.vals.find |d| { SymbolKey.isLocal(d.key) && slice(source, d.nameRange) == name }
        verifyNotNull(d)
        verifyEq(s.occByKey[d.key].size, 2)
        s.occByKey[d.key].each |o| { verifyEq(slice(source, o.range), name) }
      }
      w := s.decls.vals.find |d| { SymbolKey.isLocal(d.key) && slice(source, d.nameRange) == "w" }
      z := s.decls.vals.find |d| { SymbolKey.isLocal(d.key) && slice(source, d.nameRange) == "z" }
      assertAt(s, source, "y+w+&x", "w", w.key)
      assertAt(s, source, "&x=z", "z", z.key)
      verifyFalse(s.decls.vals.any |d| { SymbolKey.isLocal(d.key) && slice(source, d.nameRange) == "it" })
    }
  }

  Void testMultilineInitializerOwners()
  {
    source := "class X\n{\n Int count :=\n  Str.defVal.size\n Str[] names := [\n  \"a\".upper,\n  Str.defVal.lower\n ]\n" +
      " Str[] mapped :=\n  [\"a\"].map |s| { s.upper }\n static { echo(3) }\n}\n"
    withCompile(source) |c, texts|
    {
      verify(c.errs.isEmpty, c.errs.toStr)
      s := extract(c, texts)
      assertAt(s, source, "Str.defVal.size", "size", "sys::Str.size", "alpha::X.count")
      assertAt(s, source, "\"a\".upper", "upper", "sys::Str.upper", "alpha::X.names")
      assertAt(s, source, "Str.defVal.lower", "lower", "sys::Str.lower", "alpha::X.names")
      assertAt(s, source, "s.upper", "upper", "sys::Str.upper", "alpha::X.mapped")
      verifyNull(assertAt(s, source, "echo(3)", "echo", "sys::Obj.echo").enclosingSlotKey)
    }
  }

  Void testEnumNamesAreNotFoldedStrCalls()
  {
    source := "enum class E { upper, lower }"
    withCompile(source) |c, texts|
    {
      verify(c.errs.isEmpty, c.errs.toStr)
      s := extract(c, texts)
      verifyFalse(s.occByKey.containsKey("sys::Str.upper"))
      verifyFalse(s.occByKey.containsKey("sys::Str.lower"))
      ["upper", "lower"].each |name|
      {
        o := assertAt(s, source, name, name, "alpha::E.$name")
        verifyEq(o.kind, OccKind.decl)
        verifyNotNull(s.decls[o.key])
        verifyEq(s.occByKey[o.key].size, 1)
      }
    }
  }

  Void testOpaqueDslDoesNotSwallowFollowingCode()
  {
    source := "class X\n{\n Str q := Str<|\"|>\n Void go() { r := Regex<|[^']+|>; s := r.toStr; echo(s) }\n Void close() {}\n}\n"
    withCompile(source) |c, texts|
    {
      verify(c.errs.isEmpty, c.errs.toStr)
      s := extract(c, texts)
      verifyNotNull(s.decls["alpha::X.go"])
      verifyNotNull(s.decls["alpha::X.close"])
      assertAt(s, source, "r.toStr", "toStr", "sys::Regex.toStr")
      assertAt(s, source, "echo(s)", "echo", "sys::Obj.echo")
      local := s.decls.vals.find |d| { SymbolKey.isLocal(d.key) && slice(source, d.nameRange) == "s" }
      verifyNotNull(local)
      assertAt(s, source, "echo(s)", "s", local.key)
    }
  }

  Void testExactStringInterpolationReferences()
  {
    source := "class X\n{\n Void go(Int x, Str s) { echo(\"value \$x and \${x + 1} \$s.size\"); y := x }\n}\n"
    withCompile(source) |c, texts|
    {
      verify(c.errs.isEmpty, c.errs.toStr)
      snap := extract(c, texts)
      x := snap.decls.vals.find |d| { SymbolKey.isLocal(d.key) && slice(source, d.nameRange) == "x" }
      s := snap.decls.vals.find |d| { SymbolKey.isLocal(d.key) && slice(source, d.nameRange) == "s" }
      assertAt(snap, source, "\$x and", "x", x.key)
      assertAt(snap, source, "\${x + 1}", "x", x.key)
      assertAt(snap, source, "\$s.size", "s", s.key)
      assertAt(snap, source, "s.size", "size", "sys::Str.size")
      verifyEq(snap.occByKey[x.key].size, 4)
      tokens := SemanticTokens("\"\${fake}\"\nInt fake")
      verifyEq(tokens.declaration(Loc("x", 1, 1), "fake").start.line, 1)
      verifyNull(tokens.find(Loc("x", 1, 1), "fake", 0))
      verifyEq(tokens.exact(Loc("x", 1, 4), "fake").start.character, 3)
    }
  }

  Void testInternalExceptionDoesNotMarkResolutionComplete()
  {
    c := SemanticFailCompiler(CompilerInput())
    verifyErr(Err#) { c.trackedStep("ResolveExpr") }
    verifyFalse(c.resolveExprComplete)
  }

  private Occurrence assertAt(SemanticSnapshot s, Str source, Str context, Str token,
    Str key, Str? owner := null)
  {
    offset := source.index(context)
    verifyNotNull(offset, context)
    offset += context.index(token)
    prefix := source[0..<offset].splitLines
    line := prefix.size-1
    col := prefix.last.size
    occ := s.occByKey[key]?.find |o| { o.range.start.line == line && o.range.start.character == col }
    verifyNotNull(occ, "$context / $key at $line:$col; got ${s.occByKey[key]}")
    verifyEq(slice(source, occ.range), token)
    // A token must not silently carry another declaring key. Constructor
    // alternatives live in altKey, not competing type occurrences.
    sameToken := s.occByFile[occ.fileKey].findAll |o| { o.range.start.line == line &&
      o.range.start.character == col && o.range.end.character == occ.range.end.character }
    verifyEq(sameToken.map |o->Str| { o.key }.unique, [key])
    if (owner != null) verifyEq(occ.enclosingSlotKey, owner)
    return occ
  }

  private Str slice(Str source, LspRange r)
  { source.splitLines[r.start.line][r.start.character..<r.end.character] }

  private Void withCompile(Str source, |Compiler, Str:Str| f)
  {
    dir := Env.cur.tempDir + `semanticIndexer-${Uuid()}/`
    file := dir + `fan/Test.fan`
    c := null as Compiler
    try
    {
      file.out.print(source).close
      input := CompilerInput()
      input.podName = "alpha"
      input.summary = "semantic index regression"
      input.version = Version("1.0")
      input.baseDir = dir
      input.srcFiles = [`fan/`]
      input.mode = CompilerInputMode.file
      input.output = CompilerOutputMode.transientPod
      input.includeDoc = true
      input.depends = [Depend("sys 1.0")]
      input.log = CompilerLog(Buf().out)
      c = SemanticTestCompiler(input)
      try { c.frontend } catch (CompilerErr e) {}
      f(c, [UriKey.canonical(file.normalize.uri.toStr): source])
    }
    finally { c?.ns?.cleanup; dir.delete }
  }
}

** Test-local frontend boundary; no backend and no installed/transient pod.
internal class SemanticTestCompiler : Compiler
{
  new make(CompilerInput input) : super(input) {}
  Bool resolveExprComplete := false
  override Void frontend()
  {
    ["InitInput", "Tokenize", "ResolveDepends", "ScanForUsingsAndTypes",
     "ResolveImports", "Parse", "OrderByInheritance", "CheckInheritance",
     "Inherit", "DefaultCtor", "InitEnum", "InitFacet", "InitClosures",
     "Normalize", "ResolveExpr"].each |name|
    {
      step := Type.find("compiler::$name", false)
      if (step != null) trackedStep(name)
    }
  }

  Void trackedStep(Str name)
  {
    try
    {
      runCompilerStep(name)
      if (name == "ResolveExpr") resolveExprComplete = true
    }
    catch (CompilerErr e)
    {
      if (name == "ResolveExpr") resolveExprComplete = true
      throw e
    }
  }

  protected virtual Void runCompilerStep(Str name)
  { ((CompilerStep)Type.find("compiler::$name").make([this])).run }
}

internal class SemanticFailCompiler : SemanticTestCompiler
{
  new make(CompilerInput input) : super(input) {}
  protected override Void runCompilerStep(Str name) { throw Err("injected internal failure") }
}
