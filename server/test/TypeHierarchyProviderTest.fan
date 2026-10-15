class TypeHierarchyProviderTest : Test
{
  private TestWorkspace ws := TestWorkspace()
  private FantomLanguageServer? server
  private TypeHierarchyProvider provider := TypeHierarchyProvider()

  override Void teardown()
  {
    if (server != null) { server.awaitBackground; server.shutdown }
    ws.cleanup
  }
  private static Str uri(File f) { WorkspaceManager.fileToUri(f) }
  private static [Str:Obj?] item(Str key) { ["data": ["key": key]] }
  private static Str itemKey([Str:Obj?] item) { ((Str:Obj?)item["data"])["key"] }
  private FantomLanguageServer session()
  {
    s := FantomLanguageServer()
    server = s
    s.initialize(["rootUri": uri(ws.root), "initializationOptions":
      ["envPath": [ws.root.osPath], "semanticIndex": ["backgroundCompile": false]]])
    s.indexWorkspaceNow
    return s
  }

  Void testSemanticHeritageUsesKeysNotMixinNames()
  {
    alpha := ws.podName("alpha"); beta := ws.podName("beta")
    a := "mixin M {}\nclass A : M {}\n"
    ws.buildPod(alpha, ["A.fan": a])
    b := "mixin M {}\nclass Unrelated : M {}\nclass Related : ${alpha}::A {}\nclass Direct : ${alpha}::M {}\n"
    ws.writePod(beta, ["B.fan": b], ["sys 1.0", "$alpha 1.0"])
    s := session()
    verify(s.ensureFresh(s.podRegistry.allPods.map |p->Str| { p.buildKey }))
    file := ws.root + `${alpha}/fan/A.fan`
    s.didOpen(["textDocument": ["uri": uri(file), "languageId": "fantom", "version": 1, "text": a]])
    prepared := provider.prepare(s.docManager.getDocument(uri(file)), Position(0, 6), s) as List
    verifyEq(prepared.size, 1)
    verifyEq(itemKey(prepared.first), "$alpha::M")
    subtypes := provider.subtypes(prepared.first, s) as List
    keys := subtypes.map |[Str:Obj?] i->Str| { itemKey(i) }
    verify(keys.contains("$alpha::A"))
    verify(keys.contains("$beta::Direct"))
    verifyFalse(keys.contains("$beta::M"))
    verifyFalse(keys.contains("$beta::Unrelated"))
    supers := provider.supertypes(item("$beta::Direct"), s) as List
    verify(supers.any |[Str:Obj?] i->Bool| { itemKey(i) == "$alpha::M" })
    supers = provider.supertypes(item("$beta::Related"), s) as List
    verify(supers.any |[Str:Obj?] i->Bool| { itemKey(i) == "$alpha::A" })
    verifyEq((provider.subtypes(["name": "M"], s) as List).size, 0)
    verifyEq((provider.supertypes(["name": "Direct"], s) as List).size, 0)
  }

  Void testHeuristicHeritageResolvesImportsAndClientUri()
  {
    alpha := ws.podName("alpha"); beta := ws.podName("beta")
    ws.writePod(alpha, ["M.fan": "mixin M {}\n"])
    text := "using ${alpha}::M as Imported\nclass A : Imported {}\nmixin M {}\nclass Unrelated : M {}\n"
    ws.writePod(beta, ["B.fan": text], ["sys 1.0", "$alpha 1.0"])
    s := session()
    verifyEq(s.semanticSnapshots.size, 0)
    file := uri(ws.root + `${beta}/fan/B.fan`)
    original := file.replace("B.fan", "%42.fan")
    s.didOpen(["textDocument": ["uri": original, "languageId": "fantom", "version": 1, "text": text]])
    prepared := provider.prepare(s.docManager.getDocument(file), Position(1, 6), s) as List
    verifyEq(itemKey(prepared.first), "$beta::A")
    verifyEq(((Str:Obj?)prepared.first)["uri"], original)
    supers := provider.supertypes(prepared.first, s) as List
    verifyEq(supers.size, 1)
    verifyEq(itemKey(supers.first), "$alpha::M")
    subtypes := provider.subtypes(item("$alpha::M"), s) as List
    verifyEq(subtypes.size, 1)
    verifyEq(itemKey(subtypes.first), "$beta::A")
    verifyEq(((Str:Obj?)subtypes.first)["uri"], original)
  }
}
