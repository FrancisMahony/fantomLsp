class ReferencesProviderTest : Test
{
  private T09Fixture f := T09Fixture()
  private ReferencesProvider provider := ReferencesProvider()
  override Void teardown() { f.cleanup }

  Void testCollisionAcrossPodsAndIncludeDeclaration()
  {
    alpha := f.ws.podName("alpha"); beta := f.ws.podName("beta")
    f.ws.buildPod(alpha, ["A.fan": "class A { Void close() {} }"])
    text := "using $alpha\nclass Other { Void close() {} }\nclass B\n{\n  Void go(A a, Other o)\n  {\n    a.close()\n    o.close()\n    Int close := 1\n    echo(close)\n  }\n}\n"
    dir := f.ws.writePod(beta, ["B.fan": text], ["sys 1.0", "$alpha 1.0"])
    f.start(dir + `fan/B.fan`, text)
    refs := provider.references(f.doc, f.at("close", 6), f.server) as [Str:Obj?][]
    verifyEq(refs.size, 1)
    verifyEq(refs.first["uri"], f.doc.originalUri)
    verifyEq(line(refs.first), 6)
    refs = provider.references(f.doc, f.at("close", 6), f.server, true) as [Str:Obj?][]
    verifyEq(refs.size, 2)
    verify(refs.any |r| { r["uri"] == f.server.clientUri(T09Fixture.key(f.ws.root + `${alpha}/fan/A.fan`)) })
  }

  Void testLocalReferencesOnlyM1()
  {
    f.source(T09Fixture.locals)
    refs := provider.references(f.doc, f.at("x", 5), f.server) as [Str:Obj?][]
    verifyEq(refs.size, 1)
    verifyEq(line(refs.first), 5)
    refs = provider.references(f.doc, f.at("x", 5), f.server, true) as [Str:Obj?][]
    verifyEq(refs.map |r->Int| { line(r) }.sort, [4, 5])
  }

  Void testIncompleteMappedReferencesStillReturned()
  {
    f.source("class A\n{\n  Void close() {}\n  Void go() { close() }\n}\n")
    f.change("// inserted\n" + f.doc.text)
    verifyFalse(f.server.resolver.references("${f.pod}::A.close").complete)
    refs := provider.references(f.doc, f.at("close", 3), f.server) as [Str:Obj?][]
    verifyEq(refs.size, 1)
    verifyEq(line(refs.first), 4)
  }

  Void testAmbiguousAndEmptyDoNotMergeCandidates()
  {
    f.source("class A\n{\n  Void close() {}\n  Void go(Obj obj) { obj->close() }\n}\n")
    verifyNull(provider.references(f.doc, f.at("close", 3), f.server))
    verifyNull(provider.references(f.doc, Position(1, 0), f.server))
  }

  Void testBufferLocalReferencesWithoutSnapshot()
  {
    f.source(T09Fixture.locals, false)
    refs := provider.references(f.doc, f.at("x", 5), f.server, true) as [Str:Obj?][]
    verifyEq(refs.map |r->Int| { line(r) }.sort, [4, 5])
    verify(refs.all |r| { r["uri"] == f.doc.originalUri })
  }

  private static Int line([Str:Obj?] location)
  {
    range := location["range"] as [Str:Obj?]
    return (Int)((Str:Obj?)range["start"])["line"]
  }
}

** Local rename/reference fixture; no shared infrastructure or server wiring changes.
internal class T09Fixture
{
  TestWorkspace ws := TestWorkspace()
  FantomLanguageServer? server
  Str pod := ""
  DocumentState? doc

  static const Str locals := "class A\n{\n  Int m1()\n  {\n    Int x := 1\n    return x\n  }\n  Int m2()\n  {\n    Int x := 2\n    return x\n  }\n}\n"
  static Str key(File file) { WorkspaceManager.fileToUri(file) }

  Void source(Str text, Bool fresh := true)
  {
    pod = ws.podName
    dir := ws.writePod(pod, ["A.fan": text])
    start(dir + `fan/A.fan`, text, fresh)
  }

  Void start(File file, Str text, Bool fresh := true)
  {
    s := FantomLanguageServer()
    server = s
    s.initialize(["rootUri": key(ws.root), "initializationOptions":
      ["envPath": [ws.root.osPath], "semanticIndex": ["backgroundCompile": false]]])
    s.indexWorkspaceNow
    // Deliberately noncanonical client spelling exercises outbound URI mapping.
    client := key(file).replace("file:///", "file:/")
    s.didOpen(["textDocument": ["uri": client, "languageId": "fantom", "version": 1, "text": text]])
    doc = s.docManager.getDocument(key(file))
    if (fresh && !s.ensureFresh(s.podRegistry.allPods.map |p->Str| { p.buildKey }))
      throw Err("Reference fixture semantic refresh failed")
  }

  Position at(Str word, Int line)
  {
    Position(line, doc.lines[line].index(word))
  }

  Void change(Str text)
  {
    server.didChange(["textDocument": ["uri": doc.originalUri, "version": doc.version + 1],
      "contentChanges": [["text": text]]])
  }

  Void cleanup()
  {
    if (server != null) { server.awaitBackground; server.shutdown }
    ws.cleanup
  }
}
