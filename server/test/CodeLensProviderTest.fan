class CodeLensProviderTest : Test
{
  private TestWorkspace ws := TestWorkspace()
  private FantomLanguageServer? server

  override Void teardown()
  {
    if (server != null) { server.awaitBackground; server.shutdown }
    ws.cleanup
  }

  private static Str uri(File file) { WorkspaceManager.fileToUri(file) }

  private FantomLanguageServer session(Bool fresh := true)
  {
    s := FantomLanguageServer()
    server = s
    s.initialize(["rootUri": uri(ws.root), "initializationOptions":
      ["envPath": [ws.root.osPath], "semanticIndex": ["backgroundCompile": false]]])
    s.indexWorkspaceNow
    if (fresh) verify(s.ensureFresh(s.podRegistry.allPods.map |p->Str| { p.buildKey }))
    return s
  }

  private static [Str:Obj?] lensFor([Str:Obj?][] lenses, Str key)
  {
    lenses.find |lens| { (lens["data"] as [Str:Obj?])?.get("key") == key }
      ?: throw Err("Missing code lens for $key")
  }

  Void testPreciseLazyCollisionCountsAndStaleSnapshots()
  {
    alpha := ws.podName("alpha"); beta := ws.podName("beta")
    aText := "class A\n{\n  Void close() {}\n}\n"
    ws.buildPod(alpha, ["A.fan": aText])
    // Both parser and snapshot see these declarations; each must produce just
    // one lens, with counts isolated from the unrelated close key.
    bText := "using $alpha\nclass Other\n{\n  Void close() {}\n}\nclass B\n{\n  Void go(A a, Other o)\n  {\n    a.close()\n    a.close()\n    o.close()\n    o.close()\n    o.close()\n  }\n}\n"
    ws.buildPod(beta, ["B.fan": bText], ["sys 1.0", "$alpha 1.0"])
    aUri := uri(ws.root + `${alpha}/fan/A.fan`)
    bUri := uri(ws.root + `${beta}/fan/B.fan`)
    s := session()
    provider := CodeLensProvider(s.resolver, |Str key->Str| { s.clientUri(key) })
    lenses := provider.lenses(RecoveringParser().parse(aUri, aText))
    verifyEq(lenses.size, 1)
    lens := lensFor(lenses, "$alpha::A.close")
    verifyFalse(lens.containsKey("command"))
    verifyEq((lens["data"] as [Str:Obj?])["uri"], s.clientUri(aUri))
    resolved := provider.resolve(lens)
    verifyFalse(lens.containsKey("command"))
    command := resolved["command"] as [Str:Obj?]
    verifyEq(command["title"], "2 references")
    verifyEq(command["command"], "fantom.showReferences")
    args := command["arguments"] as List
    verifyEq(args[0], s.clientUri(aUri))
    verifyEq(args[1], Position(2, 7).toMap)
    locations := args[2] as List
    verifyEq(locations.size, 2)
    locations.each |loc| { verifyEq((loc as [Str:Obj?])["uri"], s.clientUri(bUri)) }
    verifyEq(((locations[0] as [Str:Obj?])["range"] as [Str:Obj?])["start"], Position(9, 6).toMap)
    bParsed := RecoveringParser().parse(bUri, bText)
    bLenses := provider.lenses(bParsed)
    verifyEq(bLenses.size, 2)
    other := lensFor(bLenses, "$beta::Other.close")
    verifyEq((provider.resolve(other)["command"] as [Str:Obj?])["title"], "3 references")

    // The new calls have no semantic occurrences. Resolve must not bind them
    // heuristically; retain only mapped snapshot calls and mark incomplete.
    edited := bText.replace("    o.close()", "    a.close()")
    s.didOpen(["textDocument": ["uri": bUri, "languageId": "fantom", "version": 1, "text": bText]])
    s.didChange(["textDocument": ["uri": bUri, "version": 2], "contentChanges": [["text": edited]]])
    command = provider.resolve(lens)["command"] as [Str:Obj?]
    verifyEq(command["title"], "2+ references")
    verifyEq(((command["arguments"] as List)[2] as List).size, 2)
  }

  Void testDeclarationsDisabledAndZeroReferences()
  {
    pod := ws.podName
    text := "class A\n{\n  new make() {}\n  Int value := 0\n  Void unused() {}\n}\n"
    dir := ws.writePod(pod, ["A.fan": text])
    file := uri(dir + `fan/A.fan`)
    s := session()
    options := Str:Obj?["codeLens": ["enabled": true]]
    provider := CodeLensProvider(s.resolver, |Str key->Str| { s.clientUri(key) }, options)
    parsed := RecoveringParser().parse(file, text)
    lenses := provider.lenses(parsed)
    verifyEq(lenses.size, 3)
    ["make", "value", "unused"].each |name|
    {
      lens := lensFor(lenses, "$pod::A.$name")
      verifyFalse(lens.containsKey("command"))
      command := provider.resolve(lens)["command"] as [Str:Obj?]
      verifyEq(command["title"], "0 references")
      verifyEq(command["command"], "")
      verifyFalse(command.containsKey("arguments"))
    }
    options["codeLens"] = ["enabled": false]
    verify(provider.lenses(parsed).isEmpty)
  }

  Void testDependentPodCompilationFailureWithZeroKnownReferences()
  {
    alpha := ws.podName("alpha"); beta := ws.podName("beta")
    aText := "class A\n{\n  Void close() {}\n}\n"
    ws.buildPod(alpha, ["A.fan": aText])
    // Unknown field type aborts before ResolveExpr. The dependent pod's call
    // must not be recovered heuristically by lazy code-lens resolve.
    bText := "using $alpha\nclass B\n{\n  Void go(A a) { a.close() }\n  Missing value\n}\n"
    bDir := ws.writePod(beta, ["B.fan": bText], ["sys 1.0", "$alpha 1.0"])
    aUri := uri(ws.root + `${alpha}/fan/A.fan`)
    s := session(false)
    verify(s.ensureFresh([uri(ws.root + `${alpha}/build.fan`)]))
    verifyFalse(s.ensureFresh([uri(bDir + `build.fan`)]))
    refs := s.resolver.references("$alpha::A.close", false, true)
    verifyFalse(refs.complete)
    verify(refs.uncoveredPods.contains(beta))
    verify(refs.occurrences.isEmpty)

    provider := CodeLensProvider(s.resolver, |Str key->Str| { s.clientUri(key) })
    lens := lensFor(provider.lenses(RecoveringParser().parse(aUri, aText)), "$alpha::A.close")
    compiles := s.semanticCompileCount
    verifyFalse(lens.containsKey("command"))
    command := provider.resolve(lens)["command"] as [Str:Obj?]
    verifyEq(command["title"], "0+ references")
    verifyEq(command["command"], "")
    verifyFalse(command.containsKey("arguments"))
    verifyFalse(lens.containsKey("command"))
    verifyEq(s.semanticCompileCount, compiles)
  }

  Void testCompactDeclarationsMappedInsertionAndEditedToken()
  {
    pod := ws.podName
    text := "class A { Void close() {} }\nclass B { new make() {} }\nclass C { Int value := 0 }\n"
    dir := ws.writePod(pod, ["A.fan": text])
    file := uri(dir + `fan/A.fan`)
    s := session()
    provider := CodeLensProvider(s.resolver, |Str key->Str| { s.clientUri(key) })
    lenses := provider.lenses(RecoveringParser().parse(file, text))
    verifyEq(lenses.size, 3)
    keys := ["$pod::A.close", "$pod::B.make", "$pod::C.value"]
    keys.each |key, i|
    {
      lens := lensFor(lenses, key)
      name := SymbolKey.simpleName(key)
      expected := LspRange(Position(i, TextDocumentManager.toLines(text)[i].index(name)),
        Position(i, TextDocumentManager.toLines(text)[i].index(name) + name.size))
      verifyEq(lens["range"], expected.toMap)
      verifyFalse(lens.containsKey("command"))
    }

    s.didOpen(["textDocument": ["uri": file, "languageId": "fantom", "version": 1, "text": text]])
    shifted := "// inserted\n" + text
    s.didChange(["textDocument": ["uri": file, "version": 2], "contentChanges": [["text": shifted]]])
    compiles := s.semanticCompileCount
    lenses = provider.lenses(RecoveringParser().parse(file, shifted))
    verifyEq(lenses.size, 3)
    keys.each |key, i|
    {
      range := lensFor(lenses, key)["range"] as [Str:Obj?]
      verifyEq((range["start"] as [Str:Obj?])["line"], i + 1)
    }
    verifyEq(s.semanticCompileCount, compiles)

    // The old token must not survive even though its surrounding file has a
    // usable snapshot. Compact edited declarations remain a parser limitation.
    changed := shifted.replace("close()", "shut()")
    s.didChange(["textDocument": ["uri": file, "version": 3], "contentChanges": [["text": changed]]])
    verifyFalse(s.resolver.fileDeclarations(file).any |t| { t.key == "$pod::A.close" })
    lenses = provider.lenses(RecoveringParser().parse(file, changed))
    verifyFalse(lenses.any |lens| { (lens["data"] as [Str:Obj?])["key"] == "$pod::A.close" })
    lensFor(lenses, "$pod::B.make")
    lensFor(lenses, "$pod::C.value")
  }

  Void testParserFallbackMergesOnlyMissingDeclarations()
  {
    pod := ws.podName
    text := "class A\n{\n  Void close() {}\n  Void unused() {}\n}\n"
    dir := ws.writePod(pod, ["A.fan": text])
    file := uri(dir + `fan/A.fan`)
    s := session()
    provider := CodeLensProvider(s.resolver, |Str key->Str| { s.clientUri(key) })
    verifyEq(provider.lenses(RecoveringParser().parse(file, text)).size, 2)
    s.didOpen(["textDocument": ["uri": file, "languageId": "fantom", "version": 1, "text": text]])
    changed := text.replace("unused()", "renamed()")
    s.didChange(["textDocument": ["uri": file, "version": 2], "contentChanges": [["text": changed]]])
    verifyFalse(s.resolver.fileDeclarations(file).any |t| { t.key == "$pod::A.renamed" })
    lenses := provider.lenses(RecoveringParser().parse(file, changed))
    verifyEq(lenses.size, 2)
    lensFor(lenses, "$pod::A.close")
    renamed := lensFor(lenses, "$pod::A.renamed")
    verifyEq((renamed["range"] as [Str:Obj?])["start"], Position(3, 7).toMap)
    verifyFalse(lenses.any |lens| { (lens["data"] as [Str:Obj?])["key"] == "$pod::A.unused" })
  }

  Void testClientUrisOnDeclarationAndReferences()
  {
    pod := ws.podName
    text := "class A\n{\n  Void close() {}\n  Void go() { close() }\n}\n"
    dir := ws.writePod(pod, ["A.fan": text])
    file := uri(dir + `fan/A.fan`)
    s := session()
    // Windows URI spelling changes still canonicalize to the declaration.
    clientFile := file.replace("file:///", "file:/")
    provider := CodeLensProvider(s.resolver, |Str key->Str| { clientFile })
    lens := lensFor(provider.lenses(RecoveringParser().parse(file, text)), "$pod::A.close")
    verifyEq((lens["data"] as [Str:Obj?])["uri"], clientFile)
    args := (provider.resolve(lens)["command"] as [Str:Obj?])["arguments"] as List
    verifyEq(args[0], clientFile)
    verifyEq((((args[2] as List)[0]) as [Str:Obj?])["uri"], clientFile)
  }
}
