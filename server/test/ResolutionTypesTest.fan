class ResolutionTypesTest : Test
{
  Void testQualifiedKeys()
  {
    type := SymbolKey.typeKey("sys", "Str")
    key := SymbolKey.slotKey(type, "size")
    verifyEq(type, "sys::Str")
    verifyEq(key, "sys::Str.size")
    verifyEq(SymbolKey.podOf(key), "sys")
    verifyEq(SymbolKey.typeKeyOf(key), type)
    verifyEq(SymbolKey.simpleName(key), "size")
    verifyEq(SymbolKey.podOf(type), "sys")
    verifyEq(SymbolKey.typeKeyOf(type), type)
    verifyEq(SymbolKey.simpleName(type), "Str")
    verifyFalse(SymbolKey.isLocal(key))
    verifyFalse(SymbolKey.isDyn(key))
    verifyNull(SymbolKey.podOf("Str"))
    verifyNull(SymbolKey.typeKeyOf("Str"))
    verifyEq(SymbolKey.simpleName("Str"), "Str")
  }

  Void testLocalKeys()
  {
    // URI colons, periods, and fragments must not be interpreted as symbols.
    file := "file:///c:/A b/Foo.fan#part"
    key := SymbolKey.localKey(file, Position(0, 17))
    verifyEq(key, "local:${file}#0:17")
    verify(SymbolKey.isLocal(key))
    verifyFalse(SymbolKey.isDyn(key))
    verifyEq(SymbolKey.localFile(key), file)
    verifyEq(SymbolKey.localPosition(key)?.line, 0)
    verifyEq(SymbolKey.localPosition(key)?.character, 17)
    verifyEq(SymbolKey.simpleName(key), key)
    verifyNull(SymbolKey.podOf(key))
    verifyNull(SymbolKey.typeKeyOf(key))
    other := SymbolKey.localKey(file, Position(123, 0))
    verifyEq(SymbolKey.localPosition(other)?.line, 123)
    verifyEq(SymbolKey.localPosition(other)?.character, 0)
  }

  Void testMalformedLocalKeys()
  {
    ["sys::Str.size", "dyn:close", "local:", "local:f", "local:#1:2",
     "local:f#", "local:f#1", "local:f#1:2:3", "local:f#-1:2",
     "local:f#1:-2", "local:f#x:2", "local:f#1:", "local:f# 1:2"].each |key|
    {
      verifyNull(SymbolKey.localFile(key), key)
      verifyNull(SymbolKey.localPosition(key), key)
    }
  }

  Void testDynamicKeys()
  {
    key := SymbolKey.dynKey("close")
    verifyEq(key, "dyn:close")
    verify(SymbolKey.isDyn(key))
    verifyFalse(SymbolKey.isLocal(key))
    verifyEq(SymbolKey.simpleName(key), "close")
    verifyNull(SymbolKey.podOf(key))
    verifyNull(SymbolKey.typeKeyOf(key))
  }

  Void testSnapshotImmutability()
  {
    file := "file:///test.fan"
    key := "test::Foo.run"
    first := Occurrence(file, range(1, 2), key, OccKind.call, null, key)
    last := Occurrence(file, range(2, 1), key, OccKind.call)
    middle := Occurrence(file, range(1, 9), key, OccKind.call)
    supers := ["sys::Obj"]
    decl := SymbolDecl(key, file, range(0, 5), range(0, 0), DocumentSymbol.methodKind,
                       "Void run()", "Runs", "test::Foo", supers)
    hashes := Str:Str[file: "hash"]
    texts := Str:Str[file: "compiled overlay"]
    occs := [last, middle, first]
    byFile := Str:Occurrence[][file: occs]
    byKey := Str:Occurrence[][key: occs]
    decls := Str:SymbolDecl[key: decl]
    failed := ["file:///broken.fan"]
    snapshot := SemanticSnapshot("test", 7, hashes, texts, byFile, decls, byKey, failed, true)

    verify(snapshot.isImmutable)
    verify(first.isImmutable)
    verify(decl.isImmutable)
    verify(snapshot.fileHash.isImmutable)
    verify(snapshot.openText.isImmutable)
    verify(snapshot.occByFile.isImmutable)
    verify(snapshot.occByFile[file].isImmutable)
    verify(snapshot.occByKey.isImmutable)
    verify(snapshot.occByKey[key].isImmutable)
    verify(snapshot.decls.isImmutable)
    verify(snapshot.parseFailedFiles.isImmutable)
    verify(decl.superTypeKeys.isImmutable)
    verifyEq(snapshot.occByFile[file], [first, middle, last])
    verifyEq(occs, [last, middle, first])

    // Producer mutations cannot change a published snapshot, even nested lists.
    hashes[file] = "changed"; texts.clear; occs.clear
    byFile.clear; byKey.clear; decls.clear; failed.clear; supers.clear
    verifyEq(snapshot.fileHash[file], "hash")
    verifyEq(snapshot.openText[file], "compiled overlay")
    verifyEq(snapshot.occByFile[file].size, 3)
    verifyEq(snapshot.occByKey[key].size, 3)
    verifySame(snapshot.decls[key], decl)
    verifyEq(snapshot.parseFailedFiles, ["file:///broken.fan"])
    verifyEq(decl.superTypeKeys, ["sys::Obj"])
    verifyEq(snapshot.podName, "test")
    verifyEq(snapshot.generation, 7)
    verify(snapshot.resolved)
    verifyErr(ReadonlyErr#) { snapshot.fileHash[file] = "oops" }
    verifyErr(ReadonlyErr#) { snapshot.occByFile[file].clear }
    verifyErr(ReadonlyErr#) { snapshot.occByKey[key].clear }
    verifyErr(ReadonlyErr#) { decl.superTypeKeys.clear }
  }

  Void testResolutionAndReferenceContracts()
  {
    r := range(3, 4)
    occ := Occurrence("file:///test.fan", r, "test::Foo.make", OccKind.ctorShorthand,
                      "test::Foo", "test::Foo.run")
    verifyEq(occ.altKey, "test::Foo")
    verifyEq(occ.enclosingSlotKey, "test::Foo.run")
    verifyEq(occ.kind, OccKind.ctorShorthand)
    target := SymbolTarget(occ.key, "make", DocumentSymbol.constructor, "semantic",
                           occ.fileKey, r, "new make()", "Creates Foo")
    targets := [target]
    resolution := Resolution(targets, Certainty.proven, r)
    occurrences := [occ]
    uncovered := ["other"]
    refs := RefResult(occurrences, false, uncovered)
    verify(target.isImmutable)
    verify(resolution.isImmutable)
    verify(resolution.targets.isImmutable)
    verify(refs.isImmutable)
    verify(refs.occurrences.isImmutable)
    verify(refs.uncoveredPods.isImmutable)
    targets.clear; occurrences.clear; uncovered.clear
    verifyEq(resolution.targets, [target])
    verifySame(resolution.occurrenceRange, r)
    verifyEq(resolution.certainty, Certainty.proven)
    verifyEq(refs.occurrences, [occ])
    verifyEq(refs.uncoveredPods, ["other"])
    verifyFalse(refs.complete)
    verifyEq(target.source, "semantic")
    verifyEq(target.kind, DocumentSymbol.constructor)
    verifyEq(target.signature, "new make()")
    verifyEq(target.doc, "Creates Foo")
    verifySame(target.range, r)
    verifyEq(target.fileKey, occ.fileKey)
    verifyErr(ReadonlyErr#) { resolution.targets.clear }
    verifyErr(ReadonlyErr#) { refs.occurrences.clear }
    verifyErr(ReadonlyErr#) { refs.uncoveredPods.clear }
  }

  Void testDefaultsAndCertainty()
  {
    verifyEq(Certainty.vals, [Certainty.proven, Certainty.unique, Certainty.ambiguous, Certainty.none])
    verify(Certainty.unique != Certainty.proven)
    verifyEq(Resolution([,], Certainty.unique).certainty, Certainty.unique)
    verifyEq(Resolution().certainty, Certainty.none)
    verify(Resolution().targets.isEmpty)
    verifyNull(Resolution().occurrenceRange)
    snapshot := SemanticSnapshot("test", 0)
    verify(snapshot.isImmutable)
    verify(snapshot.occByFile.isEmpty)
    verify(snapshot.decls.isEmpty)
    verifyFalse(snapshot.resolved)
    verify(RefResult().isImmutable)
    verifyFalse(RefResult().complete)
    target := SymbolTarget("sys::Str", "Str", DocumentSymbol.classKind, "reflection")
    verifyNull(target.fileKey)
    verifyNull(target.range)
    verifyNull(target.signature)
    verifyNull(target.doc)
    verifyEq(OccKind.vals.size, 7)
  }

  private LspRange range(Int line, Int col)
  {
    LspRange(Position(line, col), Position(line, col+3))
  }
}
