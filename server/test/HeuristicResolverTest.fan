class HeuristicResolverTest : Test
{
  private TestWorkspace? ws
  private HeuristicContext? ctx
  private Str:Str texts := [:]
  private Str:ParseResult parses := [:]
  override Void setup() { ws = TestWorkspace() }
  override Void teardown() { ws?.cleanup }

  private Str add(Str pod, Str text, Str filename := "A.fan")
  {
    dir := ws.writePod(pod, [filename:text])
    key := WorkspaceManager.fileToUri(dir + `fan/` + filename.toUri)
    texts[key] = text
    parses[key] = RecoveringParser().parse(key, text)
    return key
  }

  private Void index(Bool reverse := false)
  {
    workspace := WorkspaceManager()
    workspace.addFolder(WorkspaceManager.fileToUri(ws.root))
    pods := PodRegistry()
    pods.rebuild(workspace)
    types := TypeResolver() { podRegistry = pods }
    symbols := SymbolTable()
    keys := texts.keys.sort
    if (reverse) keys = keys.reverse
    keys.each |key| { symbols.update(key, parses[key]); types.updateUsings(key, parses[key]) }
    ctx = HeuristicContext(symbols, types, pods, ws.lookup)
  }

  private Resolution at(Str file, Str needle, Int offset := 0)
  {
    ls := texts[file].splitLines
    line := ls.findIndex |s| { s.contains(needle) }
    verifyNotNull(line, needle)
    col := ls[line].index(needle) + offset
    return HeuristicResolver().resolveAt(ctx, file, parses[file],
      DocumentState(file, 1, texts[file]), Position(line, col))
  }

  private Str[] keys(Resolution r) { r.targets.map |t->Str| { t.key } }

  Void testTypedQualifiedNullableAliasAndInherited()
  {
    a := ws.podName("alpha")
    b := ws.podName("beta")
    add(a, "class Conn\n{\n  Void close() {}\n}\n")
    add(b, "class Other\n{\n  Void close() {}\n}\n")
    file := add(b, "using $a::Conn as Alias\nclass Child : Alias\n{\n  Alias field\n  Void run($a::Conn conn)\n  {\n    conn.close\n    conn?.close\n    $a::Conn.close\n    Alias.close\n    this.close\n    super.close\n    field.close\n    close()\n  }\n}\n", "Child.fan")
    index
    ["conn.close", "conn?.close", "$a::Conn.close", "Alias.close", "this.close",
      "super.close", "field.close"].each |expr|
    {
      r := at(file, expr, expr.indexr("close"))
      verifyEq(keys(r), ["$a::Conn.close"])
      verifyEq(r.certainty, Certainty.unique)
      verifyEq(r.targets.first.fileKey, texts.keys.find |k| { k.contains("/$a/") })
    }
    verifyEq(keys(at(file, "    close()", 4)), ["$a::Conn.close"])
    verifyEq(keys(at(file, "Alias.close")), ["$a::Conn"])
  }

  Void testUnknownDynamicRankingInsertionOrderAndSingleCandidate()
  {
    a := ws.podName("alpha")
    b := ws.podName("beta")
    add(a, "class Conn\n{\n  Void close() {}\n  Void onlyHere() {}\n}\n")
    file := add(b, "using $a::Conn\nclass Other\n{\n  Void close() {}\n  Void run()\n  {\n    missing.close\n    missing->close\n    missing.onlyHere\n  }\n}\n")
    index
    unknown := at(file, "missing.close", 8)
    verifyEq(unknown.certainty, Certainty.ambiguous)
    expected := ["$b::Other.close", "$a::Conn.close"]
    ctx.lookup.namespace.resolvePod("sys", null).types.each |t|
    {
      s := t.slot("close")
      if (s != null) expected.add(s.parent.qname + ".close")
    }
    verifyEq(keys(unknown), expected[0..<2].addAll(expected[2..-1].unique.sort))
    verifyEq(at(file, "missing->close", 9).certainty, Certainty.ambiguous)
    verifyEq(at(file, "missing.onlyHere", 8).certainty, Certainty.ambiguous)
    index(true)
    verifyEq(keys(at(file, "missing.close", 8)), keys(unknown))
  }

  ** `|A a->R|` return arrows are function-signature type references,
  ** never dynamic calls on the last parameter. Real `->` calls stay dynamic,
  ** including inside closure bodies and `||` expressions.
  Void testFunctionTypeReturnArrowIsNotDynamic()
  {
    pod := ws.podName
    file := add(pod, "class A\n{\n  Void run(Obj obj, Str[] list)\n  {\n" +
      "    a := list.map |Str s->Str| { s }\n" +
      "    b := list.map |Str s -> Str?| { s }\n" +
      "    |Int, Str->Str[]| f := null\n" +
      "    c := list.map |Str s->Str| { obj->Str }\n" +
      "    d := obj->Str\n" +
      "    e := obj->size || obj->Str || true\n" +
      "    g := list.map |->Str| { obj->Str }\n" +
      "  }\n}\n")
    index
    ls := texts[file].splitLines
    pos := |Int line, Str needle, Int nth->Position|
    {
      c := -1
      (nth + 1).times { c = ls[line].index(needle, c + 1) }
      return Position(line, c + needle.size - 3)
    }
    sig := |Int line, Str needle, Int nth->Resolution|
    {
      HeuristicResolver().resolveAt(ctx, file, parses[file], DocumentState(file, 1, texts[file]), pos(line, needle, nth))
    }
    // Signature return types resolve as the type itself.
    [sig(4, "->Str", 0), sig(5, "-> Str", 0), sig(6, "->Str", 0), sig(7, "->Str", 0), sig(10, "|->Str", 0)].each |r|
    {
      verifyEq(keys(r), ["sys::Str"])
      verifyEq(r.certainty, Certainty.unique)
    }
    // Dynamic calls (body, plain statement, between `||` operators) stay ambiguous candidates.
    [sig(7, "obj->Str", 0), sig(8, "obj->Str", 0), sig(9, "obj->Str", 0), sig(10, "obj->Str", 0)].each |r|
    {
      verifyNotEq(keys(r), ["sys::Str"])
      verifyNotEq(r.certainty, Certainty.unique)
    }
  }

  ** The heuristic polls the request cancel check inside its type and
  ** slot loops; the poll's error propagates (never swallowed by catch-alls).
  Void testCandidateLoopsPollCancellation()
  {
    pod := ws.podName
    src := StrBuf()
    40.times |i| { src.add("class T$i { Void m$i() {} }\n") }
    src.add("class A\n{\n  Void run(Obj obj)\n  {\n    obj->close\n  }\n}\n")
    file := add(pod, src.toStr)
    index
    polls := 0
    full := HeuristicContext(ctx.symbols, ctx.types, ctx.pods, ctx.lookup, |->| { polls++ })
    doc := DocumentState(file, 1, texts[file])
    p := Position(44, 9)
    base := HeuristicResolver().resolveAt(full, file, parses[file], doc, p)
    verify(polls > 40, "polls=$polls")
    verifyEq(keys(HeuristicResolver().resolveAt(ctx, file, parses[file], doc, p)), keys(base))
    n := 0
    stop := HeuristicContext(ctx.symbols, ctx.types, ctx.pods, ctx.lookup, |->| { if (++n > 5) throw T13PollErr() })
    verifyErr(T13PollErr#) { HeuristicResolver().resolveAt(stop, file, parses[file], doc, p) }
    verifyEq(n, 6)
  }

  Void testLocalShadowClosureAndCrossMethod()
  {
    pod := ws.podName
    file := add(pod, "class A\n{\n  Str x\n  Void first(Int x)\n  {\n    echo(x)\n    [1].each |Str x|\n    {\n      echo(x.size)\n    }\n    echo(x.abs)\n  }\n  Void second()\n  {\n    echo(x.trim)\n    local := \"hello\"\n    local.size\n  }\n  Void third()\n  {\n    local\n  }\n}\n")
    index
    param := at(file, "Int x", 4)
    closure := at(file, "|Str x|", 5)
    verifyEq(param.certainty, Certainty.proven)
    verifyEq(closure.certainty, Certainty.proven)
    verifyEq(keys(at(file, "echo(x)", 5)), keys(param))
    verifyEq(keys(at(file, "echo(x.size)", 5)), keys(closure))
    verifyEq(keys(at(file, "echo(x.abs)", 5)), keys(param))
    verifyEq(keys(at(file, "echo(x.trim)", 5)), ["$pod::A.x"])
    verifyEq(at(file, "echo(x.trim)", 5).certainty, Certainty.unique)
    verifyEq(keys(at(file, "local.size", 6)), ["sys::Str.size"])
    // Directly select the otherwise identical bare local in another method.
    pos := Position(21, 4)
    r := HeuristicResolver().resolveAt(ctx, file, parses[file], DocumentState(file, 1, texts[file]), pos)
    verifyEq(r.certainty, Certainty.none)
  }

  Void testDeclarationsAndInstalledDeclaringType()
  {
    pod := ws.podName
    file := add(pod, "class A\n{\n  Void run(Str s)\n  {\n    s.toStr\n    s.size\n  }\n}\n")
    index
    verifyEq(at(file, "class A", 6).certainty, Certainty.proven)
    verifyEq(keys(at(file, "Void run", 5)), ["$pod::A.run"])
    verifyEq(at(file, "Void run", 5).certainty, Certainty.proven)
    expected := ctx.lookup.findSlot("sys", "Str", "toStr").parent.qname + ".toStr"
    verifyEq(keys(at(file, "s.toStr", 2)), [expected])
    verifyEq(at(file, "s.size", 2).certainty, Certainty.unique)
  }

  Void testCyclesAmbiguousImportsAndDuplicateBuildNames()
  {
    a := ws.podName("alpha")
    b := ws.podName("beta")
    add(a, "class Conn\n{\n  Void close() {}\n}\n")
    add(b, "class Conn\n{\n  Void close() {}\n}\n")
    file := add(ws.podName("caller"), "using $a::Conn as C\nusing $b::Conn as C\nclass A : B\n{\n  Void run()\n  {\n    C.close\n    absent\n  }\n}\nclass B : A {}\n")
    index
    verifyEq(at(file, "C.close", 2).certainty, Certainty.ambiguous)
    verifyEq(keys(at(file, "C.close", 2)), ["$a::Conn.close", "$b::Conn.close"])
    verifyEq(at(file, "absent").certainty, Certainty.none)
    // A second build with the same name must not leak slots into the first.
    dir := ws.writePod(ws.podName("sibling"), ["Dup.fan":"class Conn\n{\n  Void wrong() {}\n}\n"])
    build := dir + `build.fan`
    build.out.print(build.readAllStr.replace(ws.podName("sibling"), a)).close
    key := WorkspaceManager.fileToUri(dir + `fan/Dup.fan`)
    texts[key] = "class Conn\n{\n  Void wrong() {}\n  Void run()\n  {\n    this.close\n  }\n}\n"
    parses[key] = RecoveringParser().parse(key, texts[key])
    index
    verifyEq(at(key, "this.close", 5).certainty, Certainty.none)
  }

  Void testDynamicVisibilityCapLexicalMaskAndInferenceScope()
  {
    a := ws.podName("alpha")
    hidden := ws.podName("hidden")
    classes := StrBuf()
    for (i := 0; i < 25; i++)
      classes.add("class T${i.toStr.padl(2, '0')}\n{\n  Void rareName() {}\n}\n")
    add(a, classes.toStr)
    add(hidden, "class Hidden\n{\n  Void hiddenOnly() {}\n}\n")
    file := add(ws.podName("caller"), "using $a\nclass Caller\n{\n  Void first()\n  {\n    value := 42\n  }\n  Void second()\n  {\n    value := \"text\"\n    value.size\n    mystery->rareName\n    mystery->hiddenOnly\n    mystery.hiddenOnly\n    // value.size\n    echo(\"value.size\")\n    echo(\"\"\"\n      value.size\n    \"\"\")\n  }\n}\n")
    index
    verifyEq(keys(at(file, "value.size", 6)), ["sys::Str.size"])
    r := at(file, "mystery->rareName", 9)
    verifyEq(r.certainty, Certainty.ambiguous)
    verifyEq(r.targets.size, 20)
    verifyEq(r.targets.first.key, "$a::T00.rareName")
    verifyEq(r.targets.last.key, "$a::T19.rareName")
    verifyEq(at(file, "mystery->hiddenOnly", 9).certainty, Certainty.none)
    verifyEq(keys(at(file, "mystery.hiddenOnly", 8)), ["$hidden::Hidden.hiddenOnly"])
    verifyEq(at(file, "// value.size", 9).certainty, Certainty.none)
    verifyEq(at(file, "echo(\"value.size\")", 12).certainty, Certainty.none)
    r = HeuristicResolver().resolveAt(ctx, file, parses[file],
      DocumentState(file, 1, texts[file]), Position(18, 8))
    verifyEq(r.certainty, Certainty.none)
    index(true)
    verifyEq(keys(at(file, "mystery->rareName", 9)),
      (0..<20).map |i->Str| { "$a::T${i.toStr.padl(2, '0')}.rareName" })
  }

  Void testDynamicAliasAndDuplicateDeclarations()
  {
    a := ws.podName("alpha")
    add(a, "class Conn\n{\n  Void aliasOnly() {}\n}\n")
    file := add(ws.podName("caller"), "using $a::Conn as C\nclass Caller\n{\n  Void run()\n  {\n    unknown->aliasOnly\n  }\n}\n")
    index
    verifyEq(keys(at(file, "unknown->aliasOnly", 9)), ["$a::Conn.aliasOnly"])
    verifyEq(at(file, "unknown->aliasOnly", 9).certainty, Certainty.ambiguous)
    dup := add(a, "class Conn\n{\n  Void aliasOnly() {}\n}\n", "Dup.fan")
    index
    before := at(file, "unknown->aliasOnly", 9)
    verifyEq(before.targets.size, 2)
    verifyEq(before.targets.map |t->Str| { t.fileKey },
      texts.keys.findAll |k| { k.contains("/$a/") }.sort)
    index(true)
    verifyEq(at(file, "unknown->aliasOnly", 9).targets.map |t->Str| { t.fileKey },
      before.targets.map |t->Str| { t.fileKey })
  }

  Void testCompiledInheritanceMixinFieldAndUnavailablePod()
  {
    compiled := ws.podName("compiled")
    ws.buildPod(compiled, ["Types.fan":
      "class Base { Str inherited() { \"ok\" } }\nclass Child : Base {}\n"])
    own := ws.podName("own")
    file := add(own, "using $compiled::Child as Alias\nmixin M\n{\n  Void mixed() {}\n}\nclass Base\n{\n  Alias field\n}\nclass A : Base, M\n{\n  Void run(Alias child, unavailable::Gone gone)\n  {\n    child.inherited\n    field.inherited\n    mixed()\n    gone.nope\n  }\n}\n")
    // The compiled fixture is deliberately not indexed as workspace source.
    workspace := WorkspaceManager()
    workspace.addFolder(WorkspaceManager.fileToUri(ws.root + `${own}/`))
    pods := PodRegistry()
    pods.rebuild(workspace)
    symbols := SymbolTable()
    symbols.update(file, parses[file])
    types := TypeResolver() { podRegistry = pods }
    types.updateUsings(file, parses[file])
    ctx = HeuristicContext(symbols, types, pods, ws.lookup)
    verifyEq(keys(at(file, "child.inherited", 6)), ["$compiled::Base.inherited"])
    verifyEq(at(file, "child.inherited", 6).targets.first.source, "reflection")
    verifyEq(keys(at(file, "field.inherited", 6)), ["$compiled::Base.inherited"])
    verifyEq(keys(at(file, "    mixed()", 4)), ["$own::M.mixed"])
    verifyEq(at(file, "    mixed()", 4).certainty, Certainty.unique)
    verifyEq(at(file, "gone.nope", 5).certainty, Certainty.none)
    verifyNull(Pod.find(compiled, false))
  }

  Void testInferredClosureParametersShadowFields()
  {
    pod := ws.podName
    file := add(pod, "class Conn\n{\n  Void close() {}\n}\nclass A\n{\n  Conn v\n  Void run()\n  {\n    [1].each |v|\n    {\n      echo(v)\n      v.close\n    }\n    [1].each |Str s, v| { echo(v); v.close }\n    v.close\n  }\n}\n")
    index
    declaration := at(file, "|v|", 1)
    verifyEq(declaration.certainty, Certainty.proven)
    verifyEq(keys(declaration), [SymbolKey.localKey(file, Position(9, 14))])
    verifyEq(keys(at(file, "echo(v)", 5)), keys(declaration))
    verifyEq(at(file, "      v.close", 8).certainty, Certainty.ambiguous)
    mixed := at(file, "Str s, v", 7)
    verifyEq(mixed.certainty, Certainty.proven)
    verifyEq(at(file, "echo(v);", 5).certainty, Certainty.proven)
    verifyEq(keys(at(file, "echo(v);", 5)), keys(mixed))
    verifyEq(at(file, "v.close }", 2).certainty, Certainty.ambiguous)
    after := HeuristicResolver().resolveAt(ctx, file, parses[file],
      DocumentState(file, 1, texts[file]), Position(15, 6))
    verifyEq(after.certainty, Certainty.unique)
    index(true)
    verifyEq(at(file, "      v.close", 8).certainty, Certainty.ambiguous)
  }

  Void testImplicitBlockAndSuperAndDslScopes()
  {
    pod := ws.podName
    file := add(pod, "class Conn\n{\n  Void close() {}\n}\nclass A\n{\n  Conn value\n  Void close() {}\n  Void run(Str s)\n  {\n    Conn()\n    {\n      close()\n      value.close\n    }\n    super.toStr\n    Conn().with |v|\n    {\n      opaque := Str<| }}} { |fake| {\n        v.close\n      |>\n      echo(v)\n      v.close\n    }\n    value.close\n  }\n}\n")
    index
    verifyEq(at(file, "      close()", 6).certainty, Certainty.ambiguous)
    verifyEq(at(file, "      value.close", 12).certainty, Certainty.ambiguous)
    verifyEq(keys(at(file, "super.toStr", 6)), ["sys::Obj.toStr"])
    verifyEq(at(file, "super.toStr", 6).certainty, Certainty.unique)
    verifyEq(at(file, "echo(v)", 5).certainty, Certainty.proven)
    verifyEq(at(file, "      v.close", 8).certainty, Certainty.none) // DSL payload
    r := HeuristicResolver().resolveAt(ctx, file, parses[file], DocumentState(file, 1, texts[file]), Position(22, 8))
    verifyEq(r.certainty, Certainty.ambiguous)
    r = HeuristicResolver().resolveAt(ctx, file, parses[file],
      DocumentState(file, 1, texts[file]), Position(24, 10))
    verifyEq(r.certainty, Certainty.unique)
  }

  Void testExactRhsInferenceAndTokenEndAndSemanticParamKey()
  {
    pod := ws.podName
    file := add(pod, "class A\n{\n  Void process(Str s)\n  {\n    echo(s)\n    range := 0..<10\n    duration := 5ms\n    prefix := trueX\n    call := 3.abs\n    float := 3.14\n    int := 42\n    bool := true\n    range.start\n    duration.ticks\n    prefix.abs\n    call.abs\n    float.floor\n    int.abs\n    bool.not\n  }\n}\n")
    index
    method := parses[file].nodes.first.children.first
    expected := SymbolKey.localKey(file, Position(2, texts[file].splitLines[2].index("Str s")+4))
    verifyEq(keys(at(file, "echo(s)", 5)), [expected])
    verifyEq(keys(at(file, "Str s", 5)), [expected]) // token end before ')'
    verifyEq(keys(at(file, "range.start", 6)), ["sys::Range.start"])
    verifyEq(keys(at(file, "duration.ticks", 9)), ["sys::Duration.ticks"])
    verifyEq(at(file, "prefix.abs", 7).certainty, Certainty.ambiguous)
    verifyEq(at(file, "call.abs", 5).certainty, Certainty.ambiguous)
    verifyEq(keys(at(file, "float.floor", 6)), ["sys::Float.floor"])
    verifyEq(keys(at(file, "int.abs", 4)), ["sys::Int.abs"])
    verifyEq(keys(at(file, "bool.not", 5)), ["sys::Bool.not"])
    // The compiler semantic local key must use the identical actual token.
    input := compiler::CompilerInput()
    input.podName = pod
    input.summary = "param identity"
    input.version = Version("1.0")
    input.mode = compiler::CompilerInputMode.str
    input.output = compiler::CompilerOutputMode.transientPod
    input.srcStr = "class A\n{\n  Void process(Str s)\n  {\n    echo(s)\n  }\n}\n"
    input.srcStrLoc = compiler::Loc(WorkspaceManager.uriToFile(file).osPath)
    input.depends = [Depend("sys 1.0")]
    input.ns = ws.namespace
    c := SemanticTestCompiler(input)
    try
    {
      c.frontend
      snapshot := SemanticIndexer().extract(c, [file:input.srcStr], true)
      verify(snapshot.decls.containsKey(expected))
    }
    finally { c.ns?.cleanup }
  }

  Void testCatchAndForLexicalScopes()
  {
    pod := ws.podName
    source := [
      "class Conn", "{", "  Void close() {}", "}",
      "class A", "{", "  Conn v", "  Void run()", "  {",
      "    try { echo(1) } catch (IOErr v)", "    {",
      "      echo(v) // catch read", "      v.close // catch receiver", "    }",
      "    v.close // after catch",
      "    for (v := unknown(); v != null; v = next())", "    {",
      "      echo(v) // inferred for read", "      v.close // inferred receiver", "    }",
      "    v.close // after inferred",
      "    for (Str v := init(); v.size > 0; v = next()) {",
      "      echo(v) // typed for read", "      v.size // typed receiver", "    }",
      "    v.close // after typed",
      "    for (v := 0; v < 10; v++)",
      "    {", "      echo(v) // literal for read", "      v.abs // literal receiver", "    }",
      "    v.close // after literal", "  }", "}"
    ].join("\n")
    file := add(pod, source)
    index
    catchKey := SymbolKey.localKey(file, Position(9, source.splitLines[9].index("IOErr v")+6))
    inferredKey := SymbolKey.localKey(file, Position(15, source.splitLines[15].index("v :=")))
    typedKey := SymbolKey.localKey(file, Position(21, source.splitLines[21].index("Str v")+4))
    declarations := [at(file, "IOErr v", 6), at(file, "v := unknown"), at(file, "Str v :=", 4)]
    declarations.each |r, i|
    {
      verifyEq(r.certainty, Certainty.proven)
      verifyEq(keys(r), [[catchKey], [inferredKey], [typedKey]][i])
    }
    ["catch read", "inferred for read", "typed for read"].each |marker, i|
    {
      line := source.splitLines.findIndex |s| { s.contains(marker) }
      col := source.splitLines[line].index("echo(v)")+5
      r := HeuristicResolver().resolveAt(ctx, file, parses[file], DocumentState(file, 1, source), Position(line, col))
      verifyEq(r.certainty, Certainty.proven)
      verifyEq(keys(r), [[catchKey], [inferredKey], [typedKey]][i])
    }
    // Both inferred-loop condition and update bind to the initializer token.
    ["v != null", "v = next()"].each |needle|
    {
      r := at(file, needle)
      verifyEq(r.certainty, Certainty.proven)
      verifyEq(keys(r), [inferredKey])
    }
    r := at(file, "v.close // catch receiver", 2)
    verify(r.certainty != Certainty.unique)
    verifyFalse(keys(r).contains("$pod::Conn.close"))
    verifyEq(at(file, "v.close // inferred receiver", 2).certainty, Certainty.ambiguous)
    verifyEq(keys(at(file, "v.size // typed receiver", 2)), ["sys::Str.size"])
    verifyEq(keys(at(file, "v.size >", 2)), ["sys::Str.size"])
    literalKey := SymbolKey.localKey(file, Position(26, source.splitLines[26].index("v :=")))
    verifyEq(keys(at(file, "v < 10")), [literalKey])
    verifyEq(at(file, "v < 10").certainty, Certainty.proven)
    verifyEq(keys(at(file, "echo(v) // literal", 5)), [literalKey])
    verifyEq(keys(at(file, "v.abs // literal receiver", 2)), ["sys::Int.abs"])
    ["after catch", "after inferred", "after typed", "after literal"].each |marker|
    {
      r = at(file, "v.close // $marker", 2)
      verifyEq(r.certainty, Certainty.unique)
      verifyEq(keys(r), ["$pod::Conn.close"])
    }
    index(true)
    verifyEq(keys(at(file, "IOErr v", 6)), [catchKey])
    verifyEq(at(file, "v.close // inferred receiver", 2).certainty, Certainty.ambiguous)
    verifyEq(keys(at(file, "v.close // after typed", 2)), ["$pod::Conn.close"])
  }

  Void testElseBlockIsNotImplicitReceiver()
  {
    pod := ws.podName
    file := add(pod, "class A\n{\n  Void own() {}\n  Void run()\n  {\n    if (true) {\n      own() // first branch\n    } else {\n      own() // else branch\n    }\n  }\n}\n")
    index
    ["first branch", "else branch"].each |marker|
    {
      r := at(file, "own() // $marker")
      verifyEq(r.certainty, Certainty.unique)
      verifyEq(keys(r), ["$pod::A.own"])
    }
  }

  Void testUnbracedForShadowsOnlyItsStatement()
  {
    pod := ws.podName
    source := ["class Conn", "{", "  Void close() {}", "}",
      "class A", "{", "  Conn v", "  Void run()", "  {",
      "    for (Int v := 0; v < 3; v++)",
      "      v.close // next-line body", "    v.close // after next-line",
      "    for (v := 0; v < 3; v++) v.close; v.close // same-line after",
      "    v.close // after same-line",
      "    for (v := 0; v < 3; v++)",
      "      echo(", "        v.close", "      )", "    v.close // after balanced",
      "  }", "}"].join("\n")
    file := add(pod, source)
    index
    resolve := |Int line, Int col->Resolution|
    {
      HeuristicResolver().resolveAt(ctx, file, parses[file],
        DocumentState(file, 1, source), Position(line, col))
    }
    typed := SymbolKey.localKey(file, Position(9, source.splitLines[9].index("Int v")+4))
    inferred := SymbolKey.localKey(file, Position(12, source.splitLines[12].index("v :=")))
    balanced := SymbolKey.localKey(file, Position(14, source.splitLines[14].index("v :=")))
    [10, 12, 16].each |line, i|
    {
      col := source.splitLines[line].index("v.close")
      r := resolve(line, col)
      verifyEq(r.certainty, Certainty.proven)
      verifyEq(keys(r), [[typed], [inferred], [balanced]][i])
      r = resolve(line, col+2)
      verify(r.certainty != Certainty.unique)
      verifyFalse(keys(r).contains("$pod::Conn.close"))
    }
    [11, 13, 18].each |line|
    {
      r := resolve(line, source.splitLines[line].index("v.close")+2)
      verifyEq(r.certainty, Certainty.unique)
      verifyEq(keys(r), ["$pod::Conn.close"])
    }
    afterCol := source.splitLines[12].indexr("v.close")+2
    verifyEq(keys(resolve(12, afterCol)), ["$pod::Conn.close"])
    verifyEq(resolve(12, afterCol).certainty, Certainty.unique)
    index(true)
    verifyEq(keys(resolve(10, 6)), [typed])
    verifyEq(keys(resolve(13, 6)), ["$pod::Conn.close"])
  }
}

** Test-only stand-in for the resolver's cancellation error.
internal const class T13PollErr : Err
{
  new make() : super("poll cancelled") {}
}
