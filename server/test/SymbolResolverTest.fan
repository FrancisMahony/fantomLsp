class SymbolResolverTest : Test
{
  private TestWorkspace ws := TestWorkspace()
  private FantomLanguageServer? server
  override Void teardown()
  {
    if (server != null) { server.awaitBackground; server.shutdown }
    ws.cleanup
  }
  private static Str key(File f) { WorkspaceManager.fileToUri(f) }
  private FantomLanguageServer session()
  {
    s := FantomLanguageServer()
    server = s
    s.initialize(["rootUri": key(ws.root), "initializationOptions":
      ["envPath": [ws.root.osPath], "semanticIndex": ["backgroundCompile": false]]])
    s.indexWorkspaceNow
    return s
  }
  private static Position at(Str text, Str word, Int line)
  { Position(line, TextDocumentManager.toLines(text)[line].index(word)) }
  private static Void open(FantomLanguageServer s, File file, Str text)
  { s.didOpen(["textDocument": ["uri": key(file), "languageId": "fantom", "version": 1, "text": text]]) }
  private static Void edit(FantomLanguageServer s, File file, Str text)
  { s.didChange(["textDocument": ["uri": key(file), "version": 2], "contentChanges": [["text": text]]]) }

  Void testFileDeclarationsRespectBuildIdentityAndSnapshotValidity()
  {
    pod := ws.podName
    text := "class A { Void close() {} }\n"
    first := ws.writePod(pod, ["A.fan": text])
    // Duplicate names are legal workspace inputs, but declarations must come
    // from the requesting file's build, not the ranked targetLocation list.
    second := (ws.root + `copy/`).create
    (first + `build.fan`).copyTo(second + `build.fan`)
    (second + `fan/`).create
    (second + `fan/A.fan`).out.print(text).close
    s := session()
    builds := [key(first + `build.fan`), key(second + `build.fan`)]
    verify(s.ensureFresh(builds))
    files := [key(first + `fan/A.fan`), key(second + `fan/A.fan`)]
    files.each |file|
    {
      declarations := s.resolver.fileDeclarations(file)
      verifyEq(declarations.size, 2)
      verify(declarations.all |t| { t.fileKey == UriKey.canonical(file) && t.source == "semantic" })
      verify(declarations.any |t|
      { t.key == "$pod::A.close" && t.range.start.line == 0 && t.range.start.character == 15 })
    }
    build := UriKey.canonical(builds.first)
    snap := s.semanticSnapshots[build]
    s.semanticSnapshots[build] = SemanticSnapshot(pod, snap.generation,
      snap.fileHash, snap.openText, snap.occByFile, snap.decls, snap.occByKey, [,], false)
    verify(s.resolver.fileDeclarations(files.first).isEmpty)
    verifyEq(s.resolver.fileDeclarations(files.last).size, 2)
    s.semanticSnapshots[build] = SemanticSnapshot(pod, snap.generation,
      snap.fileHash, snap.openText, snap.occByFile, snap.decls, snap.occByKey, [files.first], true)
    verify(s.resolver.fileDeclarations(files.first).isEmpty)
    s.semanticSnapshots[build] = snap
    // Closed-file changes have no mapping source: even a surviving identifier
    // must not validate stale disk coordinates solely by its spelling.
    (first + `fan/A.fan`).out.print("// insertion\n" + text).close
    verify(s.resolver.fileDeclarations(files.first).isEmpty)
    verifyEq(s.resolver.fileDeclarations(files.last).size, 2)
    verify(s.resolver.fileDeclarations(key(ws.root + `missing.fan`)).isEmpty)
  }

  Void testTwoCompiledPodsMappingCollisionAndStaleCoverage()
  {
    alpha := ws.podName("alpha"); beta := ws.podName("beta")
    ws.buildPod(alpha, ["Util.fan": "class Util { new make() {} }\nclass A { Void close() {} }\n"])
    text := "using $alpha\nclass Other { Void close() {} }\nclass B\n{\n  Void go()\n  {\n    util := ${alpha}::Util.make()\n    A a := A()\n    a.close()\n    Other o := Other()\n    o.close()\n  }\n}\n"
    ws.buildPod(beta, ["B.fan": text], ["sys 1.0", "$alpha 1.0"])
    aFile := ws.root + `${alpha}/fan/Util.fan`
    bFile := ws.root + `${beta}/fan/B.fan`
    s := session()
    open(s, bFile, text)
    verify(s.ensureFresh(s.podRegistry.allPods.map |p->Str| { p.buildKey }))
    r := s.resolver
    result := r.resolveAt(key(bFile), at(text, "make", 6))
    verifyEq(result.certainty, Certainty.proven)
    verifyEq(result.targets.first.key, "$alpha::Util.make")
    verifyEq(result.targets.first.fileKey, key(aFile))
    verifyEq(r.targetLocation("$alpha::Util.make").first.uri, key(aFile))
    verifyNotNull(r.signatureOf("$alpha::Util.make"))
    refs := r.references("$alpha::A.close")
    verify(refs.complete, refs.uncoveredPods.toStr)
    verifyEq(refs.occurrences.size, 1)
    verifyEq(refs.occurrences.first.range.start.line, 8)
    shifted := "// inserted\n\n" + text
    edit(s, bFile, shifted)
    result = r.resolveAt(key(bFile), at(shifted, "make", 8))
    verifyEq(result.certainty, Certainty.proven)
    verifyEq(result.targets.first.source, "semantic")
    verifyEq(result.occurrenceRange.start.line, 8)
    refs = r.references("$alpha::A.close", false, true)
    verifyFalse(refs.complete)
    verify(refs.uncoveredPods.contains(beta))
    verifyEq(refs.occurrences.first.range.start.line, 10)
    changed := shifted.replace("Util.make()", "Util.make() // changed")
    edit(s, bFile, changed)
    result = r.resolveAt(key(bFile), at(changed, "make", 8))
    verifyEq(result.targets.first.key, "$alpha::Util.make")
    verifyEq(result.targets.first.source, "heuristic")
    verifyEq(result.certainty, Certainty.unique)
    // Edit the call itself: no stale semantic reference survives the mapping.
    edit(s, bFile, changed.replace("a.close()", "a.close() // edit"))
    refs = r.references("$alpha::A.close", false, true)
    verifyFalse(refs.complete)
    verifyEq(refs.occurrences.size, 0)
    verify(r.references("$alpha::A.close").uncoveredPods.contains(beta))
  }

  Void testLocalNameValidationAndScope()
  {
    pod := ws.podName
    text := "class A\n{\n  Int one()\n  {\n    Int value := 1\n    return value\n  }\n  Int two() { Int value := 2; return value }\n}\n"
    dir := ws.writePod(pod, ["A.fan": text])
    file := dir + `fan/A.fan`
    s := session(); open(s, file, text)
    verify(s.ensureFresh([key(dir + `build.fan`)]))
    r := s.resolver
    res := r.resolveAt(key(file), at(text, "value", 5))
    verifyEq(res.certainty, Certainty.proven)
    verifyEq(res.targets.first.name, "value")
    local := res.targets.first.key
    verify(SymbolKey.isLocal(local))
    refs := r.references(local)
    verify(refs.complete, refs.uncoveredPods.toStr)
    verifyEq(refs.occurrences.size, 1)
    verifyEq(refs.occurrences.first.range.start.line, 5)
    edit(s, file, "// insertion\n" + text)
    res = r.resolveAt(key(file), at("// insertion\n" + text, "value", 6))
    verifyEq(res.targets.first.key, local)
    verifyEq(res.targets.first.name, "value")
    verifyEq(r.targetLocation(local).first.range.start.line, 5)
  }

  Void testMissingOccurrenceIsNotCompleteAndDiskStaleness()
  {
    pod := ws.podName
    text := "class A { Void close() {} Void go() { close() } }"
    dir := ws.writePod(pod, ["A.fan": text]); file := dir + `fan/A.fan`
    s := session()
    verify(s.ensureFresh([key(dir + `build.fan`)]))
    snap := s.semanticSnapshots[key(dir + `build.fan`)]
    // Model an indexer dropping an occurrence class despite resolved=true.
    s.semanticSnapshots[key(dir + `build.fan`)] = SemanticSnapshot(pod, snap.generation,
      snap.fileHash, snap.openText, [:], snap.decls, [:], [,], true)
    refs := s.resolver.references("$pod::A.close", false, true)
    verifyFalse(refs.complete)
    verify(refs.uncoveredPods.contains(pod))
    file.out.print(text.replace("close() }", "close() /* disk edit */ }")).close
    verifyFalse(s.resolver.references("$pod::A.close").complete)
  }

  Void testHeuristicLocalCoordinateCollisions()
  {
    pod := ws.podName
    text := "class A\n{\n  Int one()\n  {\n    Int value := 1\n    return value\n  }\n\n\n\n\n\n  Str two()\n  {\n    Str other := \"other\"\n    return other\n  }\n}\n"
    dir := ws.writePod(pod, ["A.fan": text]); file := dir + `fan/A.fan`
    s := session(); open(s, file, text)
    verify(s.ensureFresh([key(dir + `build.fan`)]))
    r := s.resolver
    original := r.resolveAt(key(file), at(text, "value", 5)).targets.first.key
    edit(s, file, text.replace("return value", "return value // edited"))
    verifyEq(r.resolveAt(key(file), at(text, "value", 5)).targets.first.key, original)
    shifted := "\n\n\n\n\n\n\n\n\n\n" + text.replace("return value", "return value // edited")
    edit(s, file, shifted)
    res := r.resolveAt(key(file), at(shifted, "value", 15))
    // Insertion plus usage edit puts the declaration in mapper's changed
    // middle: an isolated identity is required, not a guessed old key.
    verify(res.targets.first.key != SymbolKey.localKey(key(file), at(text, "other", 14)))
    verifyEq(r.targetLocation(res.targets.first.key).first.range.start.line, 14)
    verify(r.signatureOf(res.targets.first.key).contains("Int"))
    refs := r.references(res.targets.first.key, true)
    verify(refs.occurrences.all |o| { o.range.start.line == 14 || o.range.start.line == 15 })
    verify(refs.occurrences.any |o| { o.range.start.line == 15 })
    // Declaration itself changed: there is no valid inverse mapping. Isolate
    // the current identity even though its coordinates equal old other.
    shifted = shifted.replace("Int value := 1", "Int value := 3")
    edit(s, file, shifted)
    res = r.resolveAt(key(file), at(shifted, "value", 15))
    verify(res.targets.first.key != SymbolKey.localKey(key(file), at(text, "other", 14)))
    verifyEq(r.targetLocation(res.targets.first.key).first.range.start.line, 14)
    verify(r.signatureOf(res.targets.first.key).contains("Int"))
    refs = r.references(res.targets.first.key, true)
    verifyFalse(refs.complete)
    verify(refs.occurrences.all |o| { o.range.start.line == 14 || o.range.start.line == 15 })
    verifyEq(r.references(res.targets.first.key, true, true).occurrences.size, 0)
    expired := res.targets.first.key
    // One-line insertion collision with another local at the same column.
    oneLine := "class A\n{\n  Int one()\n  {\n    Int value := 1\n    Str other := \"x\"\n    return value\n  }\n}\n"
    edit(s, file, oneLine)
    verify(r.targetLocation(expired).isEmpty)
    verifyNull(r.signatureOf(expired))
    verify(s.ensureFresh([key(dir + `build.fan`)]))
    changed := oneLine.replace("    Int value := 1", "\n    Int value := 2").replace("return value", "return value // edit")
    edit(s, file, changed)
    res = r.resolveAt(key(file), at(changed, "value", 7))
    verifyEq(r.targetLocation(res.targets.first.key).first.range.start.line, 5)
    verify(r.signatureOf(res.targets.first.key).contains("Int"))
    verify(r.references(res.targets.first.key, true).occurrences.all |o| { o.range.start.line != 6 })
  }

  Void testTransitiveReferenceCandidatesAndCycles()
  {
    alpha := ws.podName("alpha"); beta := ws.podName("beta"); gamma := ws.podName("gamma")
    unrelated := ws.podName("unrelated")
    ws.buildPod(alpha, ["A.fan": "class A { Void close() {} }"])
    ws.buildPod(beta, ["B.fan": "using $alpha\nclass B : A {}"], ["sys 1.0", "$alpha 1.0"])
    ws.buildPod(gamma, ["G.fan": "using $beta\nclass G { Void go(B b) { b.close() } }"], ["sys 1.0", "$beta 1.0"])
    ws.writePod(unrelated, ["U.fan": "class U { Void close() {} }"])
    s := session()
    builds := s.podRegistry.allPods.findAll |p| { p.podName != unrelated }.map |p->Str| { p.buildKey }
    verify(s.ensureFresh(builds))
    refs := s.resolver.references("$alpha::A.close")
    verify(refs.complete, refs.uncoveredPods.toStr)
    verifyEq(refs.occurrences.size, 1)
    verifyEq(refs.occurrences.first.fileKey, key(ws.root + `${gamma}/fan/G.fan`))
    // Registry-only cycle after compilation: candidate closure must terminate.
    build := ws.root + `${beta}/build.fan`
    buildText := build.readAllStr.replace("\"sys 1.0\"", "\"sys 1.0\", \"$gamma 1.0\"")
    build.out.print(buildText).close
    s.podRegistry.rebuild(s.workspaceManager)
    refs = s.resolver.references("$alpha::A.close", false, true)
    verify(refs.complete, refs.uncoveredPods.toStr)
    verifyEq(refs.occurrences.size, 1)
    verifyFalse(refs.uncoveredPods.contains(unrelated))
  }

  Void testConstructorShorthandReferenceCoverage()
  {
    alpha := ws.podName("alpha"); beta := ws.podName("beta")
    ws.buildPod(alpha, ["A.fan": "class A { new make() {} }"])
    ws.buildPod(beta, ["B.fan": "using $alpha\nclass B { A go() { A() } }"], ["sys 1.0", "$alpha 1.0"])
    s := session()
    verify(s.ensureFresh(s.podRegistry.allPods.map |p->Str| { p.buildKey }))
    [false, true].each |mode|
    {
      refs := s.resolver.references("$alpha::A.make", false, mode)
      verify(refs.occurrences.any |o| { o.fileKey == key(ws.root + `${beta}/fan/B.fan`) && o.kind == OccKind.ctorShorthand }, refs.toStr)
      snap := s.semanticSnapshots[key(ws.root + `${beta}/build.fan`)]
      verify(snap.occByFile.vals.any |occs| { occs.any |o| { o.key == "$alpha::A.make" && o.altKey == "$alpha::A" } })
      // Dropped shorthand must be detected by the type-name coverage audit.
      byFile := Str:Occurrence[][:]
      snap.occByFile.each |occs, f| { byFile[f] = occs.findAll |o| { o.kind != OccKind.ctorShorthand } }
      s.semanticSnapshots[key(ws.root + `${beta}/build.fan`)] = SemanticSnapshot(beta, snap.generation,
        snap.fileHash, snap.openText, byFile, snap.decls, [:], [,], true)
      verifyFalse(s.resolver.references("$alpha::A.make", false, mode).complete)
      s.semanticSnapshots[key(ws.root + `${beta}/build.fan`)] = snap
    }
  }

  Void testFromStrShorthandReferenceCoverage()
  {
    alpha := ws.podName("alpha"); beta := ws.podName("beta")
    ws.buildPod(alpha, ["A.fan": "class A { new fromStr(Str value) {} }"])
    ws.buildPod(beta, ["B.fan": "using $alpha\nclass B { A go() { A(\"x\") } }"], ["sys 1.0", "$alpha 1.0"])
    s := session()
    verify(s.ensureFresh(s.podRegistry.allPods.map |p->Str| { p.buildKey }))
    build := key(ws.root + `${beta}/build.fan`)
    file := key(ws.root + `${beta}/fan/B.fan`)
    snap := s.semanticSnapshots[build]
    verify(snap.occByFile[file].any |o| { o.key == "$alpha::A.fromStr" && o.altKey == "$alpha::A" })
    [false, true].each |mode|
    {
      refs := s.resolver.references("$alpha::A.fromStr", false, mode)
      verify(refs.complete, refs.uncoveredPods.toStr)
      verifyEq(refs.occurrences.size, 1)
      verifyEq(refs.occurrences.first.fileKey, file)
      verifyEq(refs.occurrences.first.kind, OccKind.ctorShorthand)
      byFile := Str:Occurrence[][:]
      snap.occByFile.each |occs, f| { byFile[f] = occs.findAll |o| { o.kind != OccKind.ctorShorthand } }
      s.semanticSnapshots[build] = SemanticSnapshot(beta, snap.generation,
        snap.fileHash, snap.openText, byFile, snap.decls, [:], [,], true)
      refs = s.resolver.references("$alpha::A.fromStr", false, mode)
      verifyFalse(refs.complete)
      verify(refs.uncoveredPods.contains(beta))
      s.semanticSnapshots[build] = snap
    }
  }

  ** A using alias is the snapshot-proven spelling of a cross-pod shorthand:
  ** navigation binds the exact declared ctor (synthetic ctor -> type), the
  ** alias token stays reachable through key/altKey, and rename never edits
  ** an alias spelling as if it were the slot or type name.
  Void testCrossPodAliasedConstructorShorthand()
  {
    alpha := ws.podName("alpha"); beta := ws.podName("beta")
    aText := "class A\n{\n  new make() {}\n}\nclass Implicit {}\n"
    ws.buildPod(alpha, ["A.fan": aText])
    text := "using ${alpha}::A as AA\nusing ${alpha}::Implicit as AI\nclass A { new make() {} }\n" +
      "class B\n{\n  Obj go() { AA() }\n  Obj other() { AI() }\n  Obj local() { A() }\n}\n"
    ws.buildPod(beta, ["B.fan": text], ["sys 1.0", "$alpha 1.0"])
    aFile := ws.root + `${alpha}/fan/A.fan`
    bFile := ws.root + `${beta}/fan/B.fan`
    s := session()
    open(s, bFile, text)
    verify(s.ensureFresh(s.podRegistry.allPods.map |p->Str| { p.buildKey }))
    r := s.resolver
    alias := at(text, "AA()", 5)
    res := r.resolveAt(key(bFile), alias)
    verifyEq(res.certainty, Certainty.proven)
    verifyEq(res.targets.first.key, "$alpha::A.make")
    verifyEq(res.targets.first.fileKey, key(aFile))
    verifyEq(res.targets.first.range.toMap, LspRange(Position(2, 6), Position(2, 10)).toMap)
    verifyEq(res.occurrenceRange.toMap, LspRange(alias, Position(5, alias.character + 2)).toMap)
    implicit := r.resolveAt(key(bFile), at(text, "AI()", 6))
    verifyEq(implicit.certainty, Certainty.proven)
    verifyEq(implicit.targets.first.key, "$alpha::Implicit")
    local := r.resolveAt(key(bFile), at(text, "A()", 7))
    verifyEq(local.targets.first.key, "$beta::A.make")
    [false, true].each |mode|
    {
      ctorRefs := r.references("$alpha::A.make", false, mode)
      verify(ctorRefs.occurrences.any |o| { o.fileKey == key(bFile) && o.range.start.toMap == alias.toMap &&
        o.kind == OccKind.ctorShorthand }, ctorRefs.toStr)
      typeRefs := r.references("$alpha::A", false, mode)
      verify(typeRefs.occurrences.any |o| { o.fileKey == key(bFile) && o.range.start.toMap == alias.toMap }, typeRefs.toStr)
    }
    // Snapshot spelling is authoritative: replacing the alias token in the
    // buffer (same length, same position) must not validate the old occurrence.
    edit(s, bFile, text.replace("{ AA() }", "{ AB() }"))
    verifyNotEq(r.resolveAt(key(bFile), alias).targets.first?.source, "semantic")
    edit(s, bFile, text)
    doc := s.docManager.getDocument(key(bFile))
    verifyErr(RequestFailedErr#) { RenameProvider().prepareRename(doc, alias, s) }
    verifyErr(RequestFailedErr#) { RenameProvider().rename(doc, alias, "create", s, "alias-ctor") }
  }

  Void testRequestPlumbing()
  {
    s := session()
    d := LspDispatcher(s)
    lens := Str:Obj?["range": LspRange(Position(0, 0), Position(0, 1)).toMap, "data": ["key": "alpha::A.close"]]
    response := d.dispatch(["id": 1, "method": "codeLens/resolve", "params": lens])
    verifyEq(response["result"], lens)
    failure := ResolverFailDispatcher(s).dispatch(["id": 2, "method": "textDocument/rename"])
    verifyEq(((Str:Obj?)failure["error"])["code"], -32803)
    verifyEq(((Str:Obj?)failure["error"])["message"], "Incomplete references")
  }

  Void testDuplicateBuildLocationsAndCurrentDiskFallback()
  {
    pod := ws.podName
    ws.writePod(pod, ["A.fan": "class A\n{\n  Void close() {}\n}\n"])
    copy := (ws.root + `copy/`).create
    dir := copy + `${pod}/`
    ws.root.plus(`${pod}/`).copyTo(dir)
    s := session()
    s.workspaceManager.addFolder(key(copy))
    s.podRegistry.rebuild(s.workspaceManager)
    verify(s.ensureFresh(s.podRegistry.allPods.map |p->Str| { p.buildKey }))
    file := dir + `fan/A.fan`
    res := s.resolver.resolveAt(key(file), Position(2, 7))
    verifyEq(res.certainty, Certainty.ambiguous)
    verifyEq(res.targets.first.fileKey, key(file))
    // Reversing hash insertion order must not select another folder's copy.
    build := key(dir + `build.fan`)
    snap := s.semanticSnapshots[build]
    hashes := Str:Str[:] { ordered = true }
    snap.fileHash.keys.dup.reverse.each |f| { hashes[f] = snap.fileHash[f] }
    s.semanticSnapshots[build] = SemanticSnapshot(pod, snap.generation, hashes,
      snap.openText, snap.occByFile, snap.decls, snap.occByKey, snap.parseFailedFiles, snap.resolved)
    verifyEq(s.resolver.resolveAt(key(file), Position(2, 7)).targets.first.fileKey, key(file))
    [false, true].each |mode|
    {
      refs := s.resolver.references("$pod::A.close", true, mode)
      verifyFalse(refs.complete)
      verify(refs.uncoveredPods.contains(pod))
    }
    locations := s.resolver.targetLocation("$pod::A.close", key(copy))
    verifyEq(locations.size, 2)
    verifyEq(locations.first.uri, key(dir + `fan/A.fan`))
    verifyEq(locations.last.uri, key(ws.root + `${pod}/fan/A.fan`))
    file.out.print("// disk insertion\nclass A\n{\n  Void close() {}\n}\n").close
    locations = s.resolver.targetLocation("$pod::A.close", key(copy))
    verifyEq(locations.first.range.start.line, 3)
    // Content-hash cache must not retain the previous parsed declaration.
    file.out.print("class A { Void other() {} }").close
    locations = s.resolver.targetLocation("$pod::A.close", key(copy))
    verifyEq(locations.size, 1)
    verifyEq(locations.first.uri, key(ws.root + `${pod}/fan/A.fan`))
  }

  Void testInstalledSourceAndCompilerMetadata()
  {
    pod := ws.podName("installed")
    ws.buildPod(pod, ["A.fan": "** Type documentation\nclass A\n{\n  ** Slot documentation\n  Int answer() { 42 }\n}\n"])
    s := session()
    // Remove source workspace registration: this pod is now an installed key
    // provided solely by the configured namespace, never JVM reflection.
    s.workspaceManager.removeFolder(key(ws.root))
    s.podRegistry.rebuild(s.workspaceManager)
    loc := s.resolver.targetLocation("$pod::A.answer").first
    verifyNotNull(loc)
    verifyEq(loc.range.start.line, 4)
    source := WorkspaceManager.uriToFile(loc.uri).readAllStr
    verifyEq(source.splitLines[4][loc.range.start.character..<loc.range.end.character], "answer")
    verify(s.resolver.signatureOf("$pod::A.answer").contains("answer"))
    verify(s.resolver.docOf("$pod::A.answer").contains("Slot documentation"))
    verify(s.resolver.docOf("$pod::A").contains("Type documentation"))
  }

  Void testDynamicBindingRemainsAmbiguousAndUncovered()
  {
    pod := ws.podName
    text := "class A\n{\n  Void close() {}\n  Void go(Obj receiver) { receiver->close() }\n}\n"
    dir := ws.writePod(pod, ["A.fan": text]); file := dir + `fan/A.fan`
    s := session(); open(s, file, text)
    verify(s.ensureFresh([key(dir + `build.fan`)]))
    res := s.resolver.resolveAt(key(file), at(text, "close", 3))
    verifyEq(res.certainty, Certainty.ambiguous)
    verify(res.targets.all |t| { t.source != "semantic" })
    refs := s.resolver.references("$pod::A.close", false, true)
    verifyFalse(refs.complete)
    verify(refs.uncoveredPods.contains(pod))
    verifyEq(refs.occurrences.size, 0)
  }
}

internal class ResolverFailDispatcher : LspDispatcher
{
  new make(FantomLanguageServer s) : super(s) {}
  override protected Obj? handleRequest(Obj id, Str method, [Str:Obj?] params)
  { throw RequestFailedErr("Incomplete references") }
}
