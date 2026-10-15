class RenameProviderTest : Test
{
  private T09Fixture f := T09Fixture()
  private RenameProvider provider := RenameProvider()
  override Void teardown() { f.cleanup }

  Void testRenameCollisionAcrossPods()
  {
    alpha := f.ws.podName("alpha"); beta := f.ws.podName("beta")
    f.ws.buildPod(alpha, ["A.fan": "class A { Void close() {} }"])
    text := "using $alpha\nclass Other { Void close() {} }\nclass B\n{\n  Void go(A a, Other o)\n  {\n    a.close()\n    o.close()\n    Int close := 1\n    echo(close)\n  }\n}\n"
    dir := f.ws.writePod(beta, ["B.fan": text], ["sys 1.0", "$alpha 1.0"])
    f.start(dir + `fan/B.fan`, text)
    pos := f.at("close", 6)
    verifyEq(provider.prepareRename(f.doc, pos, f.server)["placeholder"], "close")
    edit := provider.rename(f.doc, pos, "finish", f.server, "rename-collision")
    verifyEq(edit.changes.size, 2)
    verifyEq(edit.changes[f.server.clientUri(T09Fixture.key(f.ws.root + `${alpha}/fan/A.fan`))].size, 1)
    edits := edit.changes[f.server.clientUri(f.doc.uri)]
    verifyEq(edits.size, 1)
    verifyEq(edits.first.range.start.line, 6)
    verifyEq(edits.first.newText, "finish")
  }

  Void testLocalRenameOnlyM1AndClientUri()
  {
    f.source(T09Fixture.locals)
    original := f.doc.originalUri
    edit := provider.rename(f.doc, f.at("x", 5), "value", f.server, 21)
    verifyEq(edit.changes.keys, [original])
    edits := edit.changes[original]
    verifyEq(edits.size, 2)
    verifyEq(edits.map |e->Int| { e.range.start.line }.sort, [4, 5])
    verify(edits.all |e| { e.newText == "value" })
  }

  Void testUniqueUseAndUnavailableDeclarationHierarchyRefused()
  {
    f.source("class A\n{\n  Void close() {}\n  Void go() { close() }\n}\n", false)
    verifyEq(f.server.resolver.resolveAt(f.doc.uri, f.at("close", 3)).certainty, Certainty.unique)
    refuse |->| { provider.prepareRename(f.doc, f.at("close", 3), f.server) }
    refuse |->| { provider.rename(f.doc, f.at("close", 3), "finish", f.server, 22) }
    verifyEq(f.server.resolver.resolveAt(f.doc.uri, f.at("close", 2)).certainty, Certainty.proven)
    // A proven declaration alone cannot establish absence of subtype families.
    refuse(|->| { provider.prepareRename(f.doc, f.at("close", 2), f.server) }, "subtype coverage")
  }

  Void testAmbiguousDynamicRefusedWithMessage()
  {
    f.source("class A\n{\n  Void close() {}\n  Void go(Obj receiver) { receiver->close() }\n}\n")
    verifyEq(f.server.resolver.resolveAt(f.doc.uri, f.at("close", 3)).certainty, Certainty.ambiguous)
    refuse |->| { provider.prepareRename(f.doc, f.at("close", 3), f.server) }
    refuse |->| { provider.rename(f.doc, f.at("close", 3), "finish", f.server, 23) }
  }

  Void testExternalSemanticTargetRefused()
  {
    f.source("class A\n{\n  Str go(Str value) { value.trim() }\n}\n")
    verifyEq(f.server.resolver.resolveAt(f.doc.uri, f.at("trim", 2)).certainty, Certainty.proven)
    refuse |->| { provider.prepareRename(f.doc, f.at("trim", 2), f.server) }
    refuse |->| { provider.rename(f.doc, f.at("trim", 2), "strip", f.server, 24) }
  }

  Void testStaleReferencesRefreshBeforeEditing()
  {
    f.source("class A\n{\n  Void close() {}\n  Void go() { close() }\n}\n")
    shifted := "// inserted\n" + f.doc.text
    f.change(shifted)
    target := "${f.pod}::A.close"
    verifyFalse(f.server.resolver.references(target, true).complete)
    edit := provider.rename(f.doc, f.at("close", 3), "finish", f.server, "refresh-25")
    verify(f.server.resolver.references(target, true).complete)
    verifyEq(edit.changes[f.doc.originalUri].map |e->Int| { e.range.start.line }.sort, [3, 4])
  }

  Void testIncompleteAfterRefreshRefused()
  {
    // Dynamic calls remain uncovered even after a successful fresh compile.
    f.source("class A\n{\n  Void close() {}\n  Void go(Obj receiver) { receiver->close() }\n}\n")
    verifyFalse(f.server.resolver.references("${f.pod}::A.close", true).complete)
    refuse |->| { provider.rename(f.doc, f.at("close", 2), "finish", f.server, 26) }
  }

  Void testCancelledRefreshUsesActualRequestId()
  {
    f.source("class A\n{\n  Void close() {}\n  Void go() { close() }\n}\n")
    f.change("// stale\n" + f.doc.text)
    f.server.cancelRequest("active-rename-27")
    refuse |->| { provider.rename(f.doc, f.at("close", 3), "finish", f.server, "active-rename-27") }
    // ensureFresh consumed this exact token. Production mid-wait delivery is
    // owned by cancellation/server wiring, not simulated by this unit test.
    verifyFalse(f.server.isCancelled("active-rename-27"))
  }

  Void testBufferLocalOpaqueFileAndRefreshRefusal()
  {
    f.source(T09Fixture.locals)
    changed := f.doc.text.replace("Int x := 1", "Int y := 3").replace("return x\n  }\n  Int m2", "return y\n  }\n  Int m2")
    f.change(changed)
    res := f.server.resolver.resolveAt(f.doc.uri, f.at("y", 5))
    verifyEq(res.certainty, Certainty.proven)
    verify(res.targets.first.key.contains("#buffer:"))
    verifyEq(res.targets.first.fileKey, f.doc.uri)
    verifyEq(provider.prepareRename(f.doc, f.at("y", 5), f.server)["placeholder"], "y")
    // Refresh changes the opaque identity. It must refuse rather than editing
    // a different old-snapshot local or a file decoded from the opaque key.
    refuse |->| { provider.rename(f.doc, f.at("y", 5), "value", f.server, 28) }
  }

  Void testConstructorShorthandSlotRefusedTypeRenameSafe()
  {
    f.source("class A\n{\n  new make() {}\n  static A go() { A() }\n}\n")
    refuse |->| { provider.rename(f.doc, f.at("make", 2), "create", f.server, 29) }
    verifyNull(LinkedEditingRangeProvider().ranges(f.doc, f.at("make", 2), f.server))
    edit := provider.rename(f.doc, f.at("A", 0), "B", f.server, 30)
    edits := edit.changes[f.doc.originalUri]
    verifyEq(edits.size, 3)
    verify(edits.all |e| { RenameProvider.textAt(f.doc, e.range) == "A" && e.newText == "B" })
  }

  Void testFromStrShorthandRefused()
  {
    f.source("class A\n{\n  new fromStr(Str value) {}\n  static A go() { A(\"x\") }\n}\n")
    refuse |->| { provider.rename(f.doc, f.at("fromStr", 2), "parse", f.server, 31) }
  }

  Void testInvalidNameAndEmptyTargetRefused()
  {
    f.source(T09Fixture.locals)
    refuse |->| { provider.rename(f.doc, f.at("x", 5), "not-valid", f.server, 32) }
    refuse |->| { provider.prepareRename(f.doc, Position(1, 0), f.server) }
  }

  Void testFieldRenameExactEdits()
  {
    f.source("class A\n{\n  Str name := \"name\"\n  Str go() { name }\n}\nclass Other { Str name := \"other\" }\n")
    edit := provider.rename(f.doc, f.at("name", 2), "fullName", f.server, 33)
    edits := edit.changes[f.doc.originalUri]
    verifyEq(edits.size, 2)
    verifyEq(edits.map |e->Int| { e.range.start.line }.sort, [2, 3])
    verify(edits.all |e| { RenameProvider.textAt(f.doc, e.range) == "name" && e.newText == "fullName" })
  }

  Void testDuplicateBuildRefusalAndRefreshBuildIdentity()
  {
    f.source("class A\n{\n  Void close() {}\n}\n")
    copy := (f.ws.root + `copy/`).create
    dir := copy + `${f.pod}/`
    f.ws.root.plus(`${f.pod}/`).copyTo(dir)
    f.server.workspaceManager.addFolder(T09Fixture.key(copy))
    f.server.podRegistry.rebuild(f.server.workspaceManager)
    builds := f.server.podRegistry.byName(f.pod).map |p->Str| { p.buildKey }.sort
    verifyEq(builds.size, 2)
    verifyEq(RenameProvider.uncoveredBuildKeys(f.server, [f.pod]), builds)
    verifyEq(RenameProvider.uncoveredBuildKeys(f.server, [f.doc.uri]),
      [f.server.podRegistry.podForFile(f.doc.uri).buildKey])
    refuse |->| { provider.prepareRename(f.doc, f.at("close", 2), f.server) }
    refuse |->| { provider.rename(f.doc, f.at("close", 2), "finish", f.server, 34) }
  }

  Void testCompiledVirtualBaseAndOverrideRefused()
  {
    compiledSource("class Base\n{\n  virtual Void close() {}\n}\nclass Sub : Base\n{\n  override Void close() {}\n}\nclass Caller\n{\n  Void go(Base b, Sub s)\n  {\n    b.close()\n    s.close()\n  }\n}\n")
    familyRefused(f.at("close", 2), "Base")
    familyRefused(f.at("close", 6), "Sub")
    familyRefused(f.at("close", 12), "Base")
    familyRefused(f.at("close", 13), "Sub")
  }

  Void testCompiledCompactAbstractBaseAndOverrideRefused()
  {
    compiledSource("abstract class Base { abstract Void close() }\nclass Sub : Base { override Void close() {} }\nclass Caller { Void go(Base b, Sub s) { b.close(); s.close() } }\n")
    familyRefused(f.at("close", 0), "Base")
    familyRefused(f.at("close", 1), "Sub")
    familyRefused(f.at("close", 2), "Base")
    familyRefused(Position(2, f.doc.lines[2].indexr("close")), "Sub")
  }

  Void testCompiledCompactMixinAndImplementationRefused()
  {
    compiledSource("mixin Contract { abstract Void close() }\nclass Impl : Contract { override Void close() {} }\nclass Caller { Void go(Contract c, Impl i) { c.close(); i.close() } }\n")
    familyRefused(f.at("close", 0), "Contract")
    familyRefused(f.at("close", 1), "Impl")
    familyRefused(f.at("close", 2), "Contract")
    familyRefused(Position(2, f.doc.lines[2].indexr("close")), "Impl")
  }

  Void testCompiledConcreteMixinSlotRefused()
  {
    compiledSource("mixin Contract { Void close() {} }\nclass Impl : Contract {}\nclass Caller { Void go(Impl i) { i.close() } }\n")
    // A mixin's concrete slot must not slip through a flags-only check.
    familyRefused(f.at("close", 0), "Contract")
    familyRefused(f.at("close", 2), "Contract")
  }

  Void testCompiledVirtualFieldAndOverrideRefused()
  {
    compiledSource("class Base { virtual Str name := \"base\" }\nclass Sub : Base { override Str name := \"sub\" }\nclass Caller { Str go(Base b) { b.name } }\n")
    familyRefused(f.at("name", 0), "Base", "name")
    familyRefused(f.at("name", 1), "Sub", "name")
    familyRefused(f.at("name", 2), "Base", "name")
  }

  Void testCurrentCompactModifierNotAuthorizedByOldBuild()
  {
    compiledSource("class Base { Void close() {} }\n")
    verifyFalse(f.server.podLookup.findSlot(f.pod, "Base", "close").isVirtual)
    f.change("class Base { virtual Void close() {} }\n")
    // Compile only the frontend overlay, leaving the namespace .pod unchanged.
    verify(f.server.ensureFresh([f.server.podRegistry.podForFile(f.doc.uri).buildKey]))
    verifyFalse(f.server.podLookup.findSlot(f.pod, "Base", "close").isVirtual)
    familyRefused(f.at("close", 0), "Base")
  }

  Void testCompactIndependentSlotStillRenames()
  {
    compiledSource("class A { Void close() {} }\nclass Caller { Void go(A a) { a.close() } }\n")
    verifyEq(provider.prepareRename(f.doc, f.at("close", 0), f.server)["placeholder"], "close")
    edit := provider.rename(f.doc, f.at("close", 1), "finish", f.server, "compact-safe")
    edits := edit.changes[f.doc.originalUri]
    verifyEq(edits.size, 2)
    verifyEq(edits.map |e->Int| { e.range.start.line }.sort, [0, 1])
    verify(edits.all |e| { RenameProvider.textAt(f.doc, e.range) == "close" && e.newText == "finish" })
  }

  Void testMixinWithoutNamespaceBuildStillRefused()
  {
    f.source("mixin Contract { Void close() {} }\nclass Impl : Contract {}\nclass Caller { Void go(Impl i) { i.close() } }\n")
    verifyNull(f.server.podLookup.findSlot(f.pod, "Contract", "close"))
    familyRefused(f.at("close", 0), "Contract")
    familyRefused(f.at("close", 2), "Contract")
  }

  Void testUnknownDeclarationSafetyRefusedClearly()
  {
    // Function-type headers fall outside the small source proof grammar. Do
    // not infer safety just because the parser reports no family modifiers.
    f.source("class A\n{\n  |Int->Int| transform := |Int x->Int| { x }\n}\n")
    pos := f.at("transform", 2)
    verifyEq(f.server.resolver.resolveAt(f.doc.uri, pos).certainty, Certainty.proven)
    refuse(|->| { provider.prepareRename(f.doc, pos, f.server) }, "cannot establish")
    refuse(|->| { provider.rename(f.doc, pos, "convert", f.server, "unknown-safety") }, "cannot establish")
  }

  private Void compiledSource(Str text)
  {
    f.pod = f.ws.podName
    f.ws.buildPod(f.pod, ["A.fan": text])
    f.start(f.ws.root + `${f.pod}/fan/A.fan`, text)
  }

  Void testInheritedConcreteMethodImplicitlyImplementsMixinRefused()
  {
    compiledSource("class Base { Void close() {} }\nmixin M { abstract Void close() }\nclass Sub : Base, M {}\nclass Caller { Void go(M m, Base b) { m.close(); b.close() } }\n")
    verifyFalse(f.server.podLookup.findSlot(f.pod, "Base", "close").isVirtual)
    familyRefused(f.at("close", 0), "Base")
    familyRefused(Position(3, f.doc.lines[3].indexr("close")), "Base")
    familyRefused(f.at("close", 1), "M")
    familyRefused(f.at("close", 3), "M")
  }

  Void testInheritedConcreteFieldImplicitlyImplementsMixinRefused()
  {
    compiledSource("class Base { Str name := \"base\" }\nmixin M { abstract Str name }\nclass Sub : Base, M {}\nclass Caller { Str go(M m, Base b) { m.name + b.name } }\n")
    verifyFalse(f.server.podLookup.findSlot(f.pod, "Base", "name").isVirtual)
    familyRefused(f.at("name", 0), "Base", "name")
    familyRefused(Position(3, f.doc.lines[3].indexr("name")), "Base", "name")
    familyRefused(f.at("name", 1), "M", "name")
    familyRefused(f.at("name", 3), "M", "name")
  }

  Void testDependentPodInheritedMixinParticipationRefused()
  {
    f.pod = f.ws.podName("base")
    base := "class Base { Void close() {} }\nclass Caller { Void go(Base b) { b.close() } }\n"
    f.ws.buildPod(f.pod, ["A.fan": base])
    mid := f.ws.podName("mid")
    f.ws.buildPod(mid, ["Mid.fan": "using ${f.pod}\nclass Mid : Base {}\n"], ["sys 1.0", "${f.pod} 1.0"])
    child := f.ws.podName("child")
    f.ws.buildPod(child, ["Sub.fan": "using $mid\nmixin M { abstract Void close() }\nclass Sub : Mid, M {}\nclass Caller { Void go(M m) { m.close() } }\n"], ["sys 1.0", "$mid 1.0"])
    f.start(f.ws.root + `${f.pod}/fan/A.fan`, base)
    familyRefused(f.at("close", 0), "Base")
    familyRefused(f.at("close", 1), "Base")
  }

  Void testUnrelatedWorkspaceSubclassConservativelyRefused()
  {
    compiledSource("class Base { Void close() {} }\nclass Sub : Base {}\nclass Caller { Void go(Base b) { b.close() } }\n")
    // Intentional limitation: we do not prove absence of mixin participation.
    familyRefused(f.at("close", 0), "Base")
    familyRefused(f.at("close", 2), "Base")
  }

  Void testDependentPodInheritedFieldMixinParticipationRefused()
  {
    f.pod = f.ws.podName("base")
    base := "class Base { Str name := \"base\" }\nclass Caller { Str go(Base b) { b.name } }\n"
    f.ws.buildPod(f.pod, ["A.fan": base])
    child := f.ws.podName("child")
    f.ws.buildPod(child, ["Sub.fan": "using ${f.pod}\nmixin M { abstract Str name }\nclass Sub : Base, M {}\nclass Caller { Str go(M m) { m.name } }\n"], ["sys 1.0", "${f.pod} 1.0"])
    f.start(f.ws.root + `${f.pod}/fan/A.fan`, base)
    familyRefused(f.at("name", 0), "Base", "name")
    familyRefused(f.at("name", 1), "Base", "name")
  }

  Void testDependentOverlayWithoutSlotSpellingStillRequiresCurrentCoverage()
  {
    f.pod = f.ws.podName("base")
    base := "class Base { Void close() {} }\nclass Caller { Void go(Base b) { b.close() } }\n"
    f.ws.buildPod(f.pod, ["A.fan": base])
    child := f.ws.podName("child")
    dir := f.ws.writePod(child, ["Sub.fan": "using ${f.pod}\nclass Sub {}\n"], ["sys 1.0", "${f.pod} 1.0"])
    f.start(f.ws.root + `${f.pod}/fan/A.fan`, base)
    verifyEq(provider.prepareRename(f.doc, f.at("close", 0), f.server)["placeholder"], "close")
    file := T09Fixture.key(dir + `fan/Sub.fan`)
    f.server.didOpen(["textDocument": ["uri": file, "languageId": "fantom", "version": 1,
      "text": "using ${f.pod}\nclass Sub : Base {}\n"]])
    // This file never mentions close: the hierarchy proof must audit it too.
    refuse(|->| { provider.prepareRename(f.doc, f.at("close", 0), f.server) }, "subtype coverage")
    // rename may refresh reference coverage first; either way no edits escape.
    refuse(|->| { provider.rename(f.doc, f.at("close", 1), "finish", f.server, "stale-child") })
    verify(f.server.ensureFresh([f.server.podRegistry.byName(child).first.buildKey]))
    familyRefused(f.at("close", 0), "Base")
  }

  Void testStaleSubtypeOverlayCannotAuthorizeRename()
  {
    compiledSource("class Base { Void close() {} }\nclass Sub {}\nclass Caller { Void go(Base b) { b.close() } }\n")
    verifyEq(provider.prepareRename(f.doc, f.at("close", 0), f.server)["placeholder"], "close")
    f.change(f.doc.text.replace("class Sub {}", "mixin M { abstract Void close() }\nclass Sub : Base, M {}"))
    refuse(|->| { provider.prepareRename(f.doc, f.at("close", 0), f.server) }, "subtype coverage")
    // rename's existing complete-reference refresh compiles the overlay, then
    // the hierarchy gate must detect the newly introduced subtype.
    refuse(|->| { provider.rename(f.doc, f.at("close", 0), "finish", f.server, "new-subtype") })
    verify(f.server.ensureFresh([f.server.podRegistry.podForFile(f.doc.uri).buildKey]))
    familyRefused(f.at("close", 0), "Base")
  }

  Void testMissingDependentSnapshotCannotAuthorizeRename()
  {
    f.pod = f.ws.podName("base")
    text := "class Base { Void close() {} }\nclass Caller { Void go(Base b) { b.close() } }\n"
    f.ws.buildPod(f.pod, ["A.fan": text])
    child := f.ws.podName("child")
    f.ws.writePod(child, ["Sub.fan": "using ${f.pod}\nclass Sub : Base {}\n"], ["sys 1.0", "${f.pod} 1.0"])
    f.start(f.ws.root + `${f.pod}/fan/A.fan`, text)
    build := f.server.podRegistry.byName(child).first.buildKey
    f.server.semanticSnapshots.remove(build)
    refuse(|->| { provider.prepareRename(f.doc, f.at("close", 0), f.server) }, "subtype coverage")
    refuse(|->| { provider.rename(f.doc, f.at("close", 1), "finish", f.server, "missing-child") })
  }

  private Void familyRefused(Position pos, Str owner, Str name := "close")
  {
    res := f.server.resolver.resolveAt(f.doc.uri, pos)
    // Prove that the refusal is about the family, not missing parser coverage
    // or an ambiguous binding. Both request paths must reject before edits.
    verifyEq(res.certainty, Certainty.proven)
    verifyEq(res.targets.first.key, "${f.pod}::${owner}.${name}")
    refuse(|->| { provider.prepareRename(f.doc, pos, f.server) }, "slot families")
    refuse(|->| { provider.rename(f.doc, pos, "finish", f.server, "family-$owner") }, "slot families")
  }

  private Void refuse(|->| action, Str? reason := null)
  {
    RequestFailedErr? failure := null
    try { action() }
    catch (RequestFailedErr e) { failure = e }
    verifyNotNull(failure)
    verify(failure.msg.startsWith("Cannot rename"), failure.msg)
    if (reason != null) verify(failure.msg.contains(reason), failure.msg)
  }
}
