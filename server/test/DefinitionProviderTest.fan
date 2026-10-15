class DefinitionProviderTest : Test
{
  private TestWorkspace ws := TestWorkspace()
  private FantomLanguageServer? server
  private DefinitionProvider provider := DefinitionProvider()
  override Void teardown()
  {
    if (server != null) { server.awaitBackground; server.shutdown }
    ws.cleanup
  }
  private FantomLanguageServer session()
  {
    s := FantomLanguageServer()
    server = s
    s.workspaceManager.addFolder(key(ws.root))
    s.podLookup.configure([ws.root])
    s.indexWorkspaceNow
    return s
  }
  private static Str key(File f) { WorkspaceManager.fileToUri(f) }
  private DocumentState open(File f, Str text)
  {
    server.docManager.open(TextDocumentItem(key(f), "fantom", 1, text))
    return server.docManager.getDocument(key(f))
  }
  private static Position at(Str text, Int line, Str word)
  { Position(line, text.splitLines[line].index(word)) }
  private Void verifyLocation(Obj? value, File file, Int line)
  {
    loc := value as [Str:Obj?]
    verifyNotNull(loc)
    verifyEq(loc["uri"], server.clientUri(key(file)))
    range := loc["range"] as [Str:Obj?]
    start := range["start"] as [Str:Obj?]
    verifyEq(start["line"], line)
  }

  Void testDefinitionFindsTypeAndSlotAndUnknownReturnsNull()
  {
    text := "class Foo\n{\n  Void bar() {}\n}\n"
    dir := ws.writePod(ws.podName, ["A.fan":text]); f := dir + `fan/A.fan`
    s := session(); doc := open(f, text)
    verifyLocation(provider.definition(doc, Position(0, 6), s), f, 0)
    verifyLocation(provider.declaration(doc, Position(2, 7), s), f, 2)
    verifyNull(provider.definition(doc, Position(0, 0), s))
  }

  Void testTypedReceiverSelectsImportedFooNotSameNamedFoo()
  {
    a := ws.podName("alpha"); b := ws.podName("beta")
    aText := "class Foo\n{\n  Void close(Int code) {}\n}\n"
    aDir := ws.writePod(a, ["Foo.fan":aText])
    text := "using $a::Foo as Remote\nclass Foo\n{\n  Void close(Str reason) {}\n}\nclass Caller\n{\n  Void run(Remote conn)\n  {\n    conn.close(1)\n  }\n}\n"
    dir := ws.writePod(b, ["Caller.fan":text], ["sys 1.0", "$a 1.0"])
    s := session(); doc := open(dir + `fan/Caller.fan`, text)
    verifyLocation(provider.definition(doc, at(text, 9, "close"), s), aDir + `fan/Foo.fan`, 2)
    verifyLocation(provider.declaration(doc, at(text, 9, "close"), s), aDir + `fan/Foo.fan`, 2)
  }

  Void testLocalNeverFindsOtherMethodParameterAndUsesClientUri()
  {
    text := "class A\n{\n  Void run()\n  {\n    Int x := 1\n    echo(x)\n  }\n}\n"
    dir := ws.writePod(ws.podName, ["A.fan":text, "B.fan":"class B\n{\n  Void other(Str x) {}\n}\n"])
    f := dir + `fan/A.fan`; s := session()
    original := UriKey.toClientUri(key(f))
    s.docManager.open(TextDocumentItem(original, "fantom", 1, text))
    doc := s.docManager.getDocument(key(f))
    verifyLocation(provider.definition(doc, at(text, 5, "x"), s), f, 4)
    loc := provider.definition(doc, at(text, 5, "x"), s) as [Str:Obj?]
    verifyEq(loc["uri"], original)
    verify(s.resolver.resolveAt(doc.uri, at(text, 5, "x")).targets.first.key.contains("#buffer:"))
  }

  Void testUnknownReceiverReturnsRankedListNotFirstMatch()
  {
    a := ws.podName("alpha"); b := ws.podName("beta")
    aDir := ws.writePod(a, ["Foo.fan":"class Foo\n{\n  Void close() {}\n}\n"])
    text := "using $a::Foo\nclass Other\n{\n  Void close() {}\n  Void run()\n  {\n    missing.close()\n  }\n}\n"
    dir := ws.writePod(b, ["Other.fan":text], ["sys 1.0", "$a 1.0"])
    s := session(); doc := open(dir + `fan/Other.fan`, text)
    list := provider.definition(doc, at(text, 6, "close"), s) as Obj[]
    verifyNotNull(list)
    verify(list.size >= 2)
    verifyLocation(list[0], dir + `fan/Other.fan`, 3)
    verifyLocation(list[1], aDir + `fan/Foo.fan`, 2)
    verifyEq(provider.definition(doc, at(text, 6, "close"), s), list)
  }

  Void testImplementationResolvesHeritageAndTransitiveOverrides()
  {
    a := ws.podName("alpha"); b := ws.podName("beta")
    aText := "mixin M\n{\n  abstract Void run()\n}\n"
    aDir := ws.writePod(a, ["M.fan":aText])
    text := "using $a::M as Contract\nclass C : Contract\n{\n  override Void run() {}\n}\nclass D : C\n{\n  override Void run() {}\n}\n"
    // Same-spelled, unrelated M must not be an implementation.
    dir := ws.writePod(b, ["C.fan":text, "Wrong.fan":"mixin M {}\nclass Wrong : M {}\n"], ["sys 1.0", "$a 1.0"])
    s := session(); doc := open(aDir + `fan/M.fan`, aText)
    types := provider.implementation(doc, Position(0, 6), s) as Obj[]
    verifyEq(types.size, 2)
    verifyLocation(types[0], dir + `fan/C.fan`, 1)
    verifyLocation(types[1], dir + `fan/C.fan`, 5)
    slots := provider.implementation(doc, at(aText, 2, "run"), s) as Obj[]
    verifyEq(slots.size, 2)
    verifyLocation(slots[0], dir + `fan/C.fan`, 3)
    verifyLocation(slots[1], dir + `fan/C.fan`, 7)
  }

  ** A7 regression: 300 unrelated generated types must not make implementation
  ** quadratic in index size, while transitive inheritance stays exact.
  Void testImplementationScalesWithManyUnrelatedTypes()
  {
    a := ws.podName("alpha"); b := ws.podName("beta"); g := ws.podName("gen")
    aText := "mixin M\n{\n  abstract Void run()\n}\nclass Base : M\n{\n  override Void run() {}\n}\n"
    aDir := ws.writePod(a, ["M.fan":aText])
    text := "using $a::Base\nclass C : Base\n{\n  override Void run() {}\n}\nclass D : C {}\nclass E : D\n{\n  override Void run() {}\n}\n"
    dir := ws.writePod(b, ["C.fan":text, "Wrong.fan":"mixin M { abstract Void run() }\nclass Wrong : M { override Void run() {} }\n"], ["sys 1.0", "$a 1.0"])
    generated := Str:Str[:]
    300.times |i| { generated["Gen${i}.fan"] = "class Gen$i\n{\n  Int value := $i\n  Void run() {}\n}\n" }
    ws.writePod(g, generated)
    s := session(); doc := open(aDir + `fan/M.fan`, aText)
    verify(s.symbolTable.allEntries.size > 900)

    began := Duration.now
    slots := provider.implementation(doc, at(aText, 2, "run"), s) as Obj[]
    elapsed := Duration.now - began
    Env.cur.err.printLine("[DefinitionProviderTest] implementation over 300 generated types: $elapsed.toLocale")
    verify(elapsed < 5sec, "implementation took $elapsed.toLocale")
    // Base (direct), C and E (transitive through D); D has no run override.
    verifyEq(slots.size, 3)
    verifyLocation(slots[0], aDir + `fan/M.fan`, 6)
    verifyLocation(slots[1], dir + `fan/C.fan`, 3)
    verifyLocation(slots[2], dir + `fan/C.fan`, 8)

    types := provider.implementation(doc, Position(0, 6), s) as Obj[]
    verifyEq(types.size, 4)
    verifyLocation(types[0], aDir + `fan/M.fan`, 4)
    verifyLocation(types[1], dir + `fan/C.fan`, 1)
    verifyLocation(types[2], dir + `fan/C.fan`, 5)
    verifyLocation(types[3], dir + `fan/C.fan`, 6)
  }

  Void testTypeDefinitionUsesLocalFieldAndReturnType()
  {
    text := "class Foo {}\nclass A\n{\n  Foo field\n  Foo value() { field }\n  Void run(Foo local)\n  {\n    echo(local)\n    echo(field)\n    value()\n  }\n}\n"
    dir := ws.writePod(ws.podName, ["A.fan":text]); f := dir + `fan/A.fan`
    s := session(); doc := open(f, text)
    [7, 8, 9].each |line|
    {
      word := line == 7 ? "local" : (line == 8 ? "field" : "value")
      verifyLocation(provider.typeDefinition(doc, at(text, line, word), s), f, 0)
    }
  }

  Void testInstalledSourceAvailableOrNullWithoutGuessing()
  {
    text := "class A\n{\n  Void run(Str s)\n  {\n    s.size\n  }\n}\n"
    dir := ws.writePod(ws.podName, ["A.fan":text]); s := session(); doc := open(dir + `fan/A.fan`, text)
    ["sys::Str", "sys::Str.size"].each |symbol|
    {
      pos := symbol.endsWith("size") ? at(text, 4, "size") : at(text, 2, "Str")
      expected := s.resolver.targetLocation(symbol)
      actual := provider.definition(doc, pos, s)
      if (expected.isEmpty) verifyNull(actual)
      else
      {
        loc := actual as [Str:Obj?]
        verifyNotNull(loc)
        verifyEq(loc["uri"], s.clientUri(expected.first.uri))
        verifyEq(loc["range"], expected.first.range.toMap)
      }
      verifyNotNull(HoverProvider().hover(doc, s.docManager.parseDocument(doc.uri), pos, s))
    }
  }
}
