class PodRegistryTest : Test
{
  private File? root

  override Void teardown() { root?.delete }

  private File setupTree()
  {
    root = (Env.cur.tempDir + `fantomLsp-registry-${Uuid()}/`).create
    return root
  }

  private File build(File dir, Str name, Str dirs := "`fan/`")
  {
    dir.create
    file := dir + `build.fan`
    file.out.print("class Build\n{\n  // podName = \"ignored\"\n  podName = \"${name}\"\n  srcDirs = [${dirs}]\n  depends = [\"sys 1.0\", \"util 1.0\"]\n}\n").close
    return file
  }

  private File source(File dir, Str name := "Foo.fan")
  {
    dir.create
    file := dir + name.toUri
    file.out.print("class Foo {}\n").close
    return file
  }

  Void testBuildIdentityRankingAndNestedSources()
  {
    tree := setupTree
    first := tree + `a/`
    second := tree + `b/`
    aBuild := build(first, "duplicate", "`fan/`, `fan/nested/`")
    bBuild := build(second, "duplicate")
    aSource := source(first + `fan/nested/`)
    bSource := source(second + `fan/`)
    workspace := WorkspaceManager()
    workspace.addFolder(WorkspaceManager.fileToUri(second))
    workspace.addFolder(WorkspaceManager.fileToUri(first))
    registry := PodRegistry()
    registry.rebuild(workspace)
    aKey := WorkspaceManager.fileToUri(aBuild)
    bKey := WorkspaceManager.fileToUri(bBuild)
    a := registry.podForFile(WorkspaceManager.fileToUri(aSource))
    verifyEq(a.buildKey, aKey)
    verifyEq(a.podName, "duplicate")
    verifyEq(a.dependNames, ["sys", "util"])
    verifyEq(registry.podForFile(WorkspaceManager.fileToUri(bSource)).buildKey, bKey)
    verifyEq(registry.byName("duplicate").map |p->Str| { p.buildKey }, [aKey, bKey])
    verifyEq(registry.byName("duplicate", WorkspaceManager.fileToUri(second)).first.buildKey, bKey)
    verifyEq(registry.byBuildKey(UriKey.toClientUri(aKey)), a)
    verifyEq(registry.filesOf(a), [WorkspaceManager.fileToUri(aSource)])
    verify(registry.isWorkspacePod("duplicate"))
    verify(!registry.isWorkspacePod("absent"))
    verifyNull(registry.podForFile(WorkspaceManager.fileToUri(tree + `a-other/X.fan`)))
    // Non-src files still map to the nearest build ancestor.
    verifyEq(registry.podForFile(WorkspaceManager.fileToUri(first + `notes/X.fan`)).buildKey, aKey)

    nestedBuild := build(first + `fan/nested/inner/`, "inner")
    nestedSource := source(first + `fan/nested/inner/fan/`)
    registry.rebuild(workspace)
    verifyEq(registry.podForFile(WorkspaceManager.fileToUri(nestedSource)).buildKey,
      WorkspaceManager.fileToUri(nestedBuild))
    verifyEq(registry.filesOf(registry.byBuildKey(aKey)), [WorkspaceManager.fileToUri(aSource)])
    workspace.removeFolder(WorkspaceManager.fileToUri(second))
    registry.rebuild(workspace)
    verifyEq(registry.byName("duplicate").size, 1)
    verifyNull(registry.byBuildKey(bKey))
  }

  ** T13: memoized sort/prefix/owner tables are invalidated by every rebuild,
  ** and filesOf still observes the live filesystem between rebuilds.
  Void testMemoizedOwnershipInvalidatedByRebuildAndLiveFiles()
  {
    tree := setupTree
    outer := tree + `outer/`
    build(outer, "outer")
    src := source(outer + `fan/deep/`)
    key := WorkspaceManager.fileToUri(src)
    workspace := WorkspaceManager()
    workspace.addFolder(WorkspaceManager.fileToUri(tree))
    registry := PodRegistry()
    registry.rebuild(workspace)
    outerPod := registry.podForFile(key)
    verifyEq(outerPod.podName, "outer")
    // Client spellings share the canonical memo entry.
    verifyEq(registry.podForFile(UriKey.toClientUri(key)), outerPod)
    verifyNull(registry.podForFile(WorkspaceManager.fileToUri(tree + `elsewhere/X.fan`)))
    // Returned lists are copies; mutating one cannot corrupt the memo.
    registry.allPods.clear
    verifyEq(registry.allPods.size, 1)

    // Live filesystem: a new source appears without a rebuild.
    added := source(outer + `fan/`, "Added.fan")
    verify(registry.filesOf(outerPod).contains(WorkspaceManager.fileToUri(added)))

    // A nested build (longer source prefix) takes ownership after rebuild, and
    // a previously-null answer is recomputed rather than served from the memo.
    inner := build(outer + `fan/deep/`, "inner", "`./`")
    build(tree + `elsewhere/`, "elsewhere")
    verifyEq(registry.podForFile(key).podName, "outer")
    registry.rebuild(workspace)
    verifyEq(registry.podForFile(key).buildKey, WorkspaceManager.fileToUri(inner))
    verifyEq(registry.podForFile(WorkspaceManager.fileToUri(tree + `elsewhere/X.fan`)).podName, "elsewhere")
    verifyFalse(registry.filesOf(registry.byName("outer").first).contains(key))
    keys := registry.allPods.map |p->Str| { p.buildKey }
    verifyEq(keys.size, 3)
    verifyEq(keys, keys.dup.sort)

    // Folder removal: ownership disappears on the next rebuild.
    workspace.removeFolder(WorkspaceManager.fileToUri(tree))
    registry.rebuild(workspace)
    verifyNull(registry.podForFile(key))
    verify(registry.allPods.isEmpty)
    verify(registry.byName("outer").isEmpty)
  }

  Void testBuildPodNameIgnoresCommentsAndStringAssignments()
  {
    tree := setupTree
    file := build(tree, "actualPod")
    file.out.print([
      "/* historical build settings",
      "podName = \"oldPod\"",
      "/* nested comment */",
      "*/",
      "// podName = \"lineDecoy\"",
      "class Build {",
      "  Str example := \"\"\"",
      "podName = \"stringDecoy\"",
      "// comment marker inside the string",
      "/* another literal marker */",
      "\"\"\"",
      "  Str escaped := \"\\\" /* not a comment */\"",
      "  Uri uri := `http://example/`",
      "  podName /* inline comment */ = \"actualPod\" // current name",
      "  srcDirs = [`fan/`]",
      "  depends = [\"sys 1.0\"]",
      "}"
    ].join("\n")).close
    workspace := WorkspaceManager()
    workspace.addFolder(WorkspaceManager.fileToUri(tree))
    registry := PodRegistry()
    registry.rebuild(workspace)
    verifyEq(registry.allPods.size, 1)
    verifyEq(registry.byBuildKey(WorkspaceManager.fileToUri(file)).podName, "actualPod")
    ["oldPod", "lineDecoy", "stringDecoy"].each |name|
    {
      verify(!registry.isWorkspacePod(name))
    }
    // With only decoys, no registry entry may be manufactured.
    file.out.print("/*\npodName = \"oldPod\"\n*/\nStr s := \"\"\"\npodName = \"stringDecoy\"\n\"\"\"\n").close
    registry.rebuild(workspace)
    verifyEq(registry.allPods.size, 0)
  }

  Void testOwnPodTypesPrecedeImports()
  {
    tree := setupTree
    build(tree, "own")
    file := source(tree + `fan/`)
    key := WorkspaceManager.fileToUri(file)
    workspace := WorkspaceManager()
    workspace.addFolder(WorkspaceManager.fileToUri(tree))
    registry := PodRegistry()
    registry.rebuild(workspace)
    resolver := TypeResolver() { podRegistry = registry }
    table := SymbolTable()
    parsed := RecoveringParser().parse(key, "using other::Foo\nclass Foo {}")
    table.update(key, parsed)
    resolver.updateUsings(key, parsed)
    verifyEq(resolver.resolveType(key, "Foo", table), "own::Foo")
  }

  Void testLongestSrcPrefixAndWholeWorkspaceImports()
  {
    tree := setupTree
    build(tree + `a/`, "alpha", "`../shared/`")
    build(tree + `b/`, "beta", "`../shared/nested/`")
    outer := source(tree + `shared/`)
    inner := source(tree + `shared/nested/`)
    workspace := WorkspaceManager()
    workspace.addFolder(WorkspaceManager.fileToUri(tree))
    registry := PodRegistry()
    registry.rebuild(workspace)
    verifyEq(registry.podForFile(WorkspaceManager.fileToUri(inner)).podName, "beta")
    verifyEq(registry.podForFile(WorkspaceManager.fileToUri(outer)).podName, "alpha")
    table := SymbolTable()
    table.update(WorkspaceManager.fileToUri(inner), RecoveringParser().parse("", "class Foo {}"))
    table.update(WorkspaceManager.fileToUri(outer), RecoveringParser().parse("", "class Foo {}"))
    resolver := TypeResolver() { podRegistry = registry }
    uri := "test://imports.fan"
    resolver.updateUsings(uri, RecoveringParser().parse(uri, "using beta\nusing alpha"))
    verifyEq(resolver.resolveTypes(uri, "Foo", table), ["alpha::Foo", "beta::Foo"])
    verifyNull(resolver.resolveType(uri, "Foo", table))
    // Duplicate names inside one workspace folder retain path tie-breaking.
    build(tree + `b/`, "alpha", "`../shared/nested/`")
    registry.rebuild(workspace)
    verifyEq(registry.byName("alpha", WorkspaceManager.fileToUri(tree)).map |p->Str| { p.buildKey },
      [WorkspaceManager.fileToUri(tree + `a/build.fan`), WorkspaceManager.fileToUri(tree + `b/build.fan`)])
  }

  Void testMainThreadCompletionAndWatchedBuildRefresh()
  {
    tree := setupTree
    buildFile := build(tree, "before")
    source(tree + `fan/`)
    server := RegistryTestServer()
    server.workspaceManager.addFolder(WorkspaceManager.fileToUri(tree))
    server.startIndex
    verify(server.awaitBackground)
    verify(server.podRegistry.isWorkspacePod("before"))
    key := WorkspaceManager.fileToUri(buildFile)
    // Watch a build that is open too: disk build metadata is authoritative.
    server.docManager.open(TextDocumentItem(key, "fantom", 1, buildFile.readAllStr))
    build(tree, "after")
    server.didChangeWatchedFiles(["changes": [["uri": UriKey.toClientUri(key), "type": 2]]])
    verify(!server.podRegistry.isWorkspacePod("before"))
    verify(server.podRegistry.isWorkspacePod("after"))
    verifyEq(server.scheduled, 1)
    buildFile.delete
    server.didChangeWatchedFiles(["changes": [["uri": key, "type": 3]]])
    verify(!server.podRegistry.isWorkspacePod("after"))
    verifyEq(server.scheduled, 2)
    build(tree, "sync")
    server.indexWorkspaceNow
    verify(server.podRegistry.isWorkspacePod("sync"))
  }
}

internal class RegistryTestServer : FantomLanguageServer
{
  Int scheduled := 0
  override Void scheduleCompilerDiagnostics(Str uri) { scheduled++ }
}
