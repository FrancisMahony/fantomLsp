class WorkspaceManagerTest : Test
{
  Void testUriToFileDecodesPercentColon()
  {
    f := WorkspaceManager.uriToFile("file:///c%3A/Code")
    verifyNotNull(f)
    p := f.osPath.lower.replace("\\", "/")
    verify(p.startsWith("c:/code") || p.contains("c:/code"))
  }

  Void testFolderForLongestPrefix()
  {
    workspace := WorkspaceManager()
    verifyNull(workspace.folderFor("file:///projA/a.fan"))
    workspace.addFolder("file:///projA/sub/")
    workspace.addFolder("file:///projA/")
    workspace.addFolder("file:///projB")

    verifyEq(workspace.folderFor("file:///projA/a.fan"), "file:///projA/")
    verifyEq(workspace.folderFor("file:///projA/sub/other.fan"), "file:///projA/sub/")
    verifyEq(workspace.folderFor("file:///projB/sub/other.fan"), "file:///projB")
    verifyEq(workspace.folderFor("file:///projB"), "file:///projB")
    verifyNull(workspace.folderFor("file:///projBExtra/a.fan"))
    verifyNull(workspace.folderFor("file:///projAExtra/a.fan"))
    verifyNull(workspace.folderFor("file:///outside/a.fan"))

    workspace.removeFolder("file:///projA/sub/")
    verifyEq(workspace.folderFor("file:///projA/sub/other.fan"), "file:///projA/")
  }

  Void testInitializeReadsMaxFiles()
  {
    server := FantomLanguageServer()
    verifyEq(server.workspaceManager.maxFiles, 0)
    server.initialize([
      "initializationOptions": ["maxFiles": 42],
    ])
    verifyEq(server.workspaceManager.maxFiles, 42)
  }

  Void testFindBuildPodsNested()
  {
    root := tempDir()
    podA := root + `monoRepos/analytics/src/conn/podA/`
    podB := root + `monoRepos/other/podB/`
    (podA + `fan/`).create
    (podB + `fan/`).create
    (podA + `build.fan`).out.print("class Build {}\n").close
    (podB + `build.fan`).out.print("class Build {}\n").close
    (root + `node_modules/fake/build.fan`).create.parent
    skip := root + `node_modules/x/`
    skip.create
    (skip + `build.fan`).out.print("class Build {}\n").close

    wm := WorkspaceManager()
    acc := File[,]
    wm.findBuildPods(root, acc, 0)
    paths := acc.map |f->Str| { f.normalize.osPath.lower }
    verifyEq(acc.size, 2)
    verify(paths.any |Str p->Bool| { p.contains("poda") })
    verify(paths.any |Str p->Bool| { p.contains("podb") })
    verifyFalse(paths.any |Str p->Bool| { p.contains("node_modules") })
  }

  Void testInitializeReadsExcludeDirs()
  {
    server := FantomLanguageServer()
    verify(server.workspaceManager.excludeDirs.contains("lib"))
    server.initialize([
      "initializationOptions": ["excludeDirs": [".git", "vendor"]],
    ])
    verifyEq(server.workspaceManager.excludeDirs, [".git", "vendor"])
    verifyFalse(server.workspaceManager.excludeDirs.contains("lib"))
  }

  Void testMixedEncodingFolderKeysAndPreference()
  {
    workspace := WorkspaceManager()
    workspace.addFolder("file://C:/A%20b/")
    workspace.addFolder("file:///c%3A/A%20b/")
    workspace.addFolder("file:///C:/A b/sub/")
    verifyEq(workspace.getFolders, ["file:///c:/A b/", "file:///c:/A b/sub/"])
    verifyEq(workspace.folderFor("file:///c%3A/A%20b/sub/x.fan"), "file:///c:/A b/sub/")
    verifyNull(workspace.folderFor("file:///C:/A bExtra/x.fan"))

    table := SymbolTable(workspace)
    outside := "file:///c:/A bExtra/Foo.fan"
    inside := "file:///c%3A/A%20b/Foo.fan"
    parser := RecoveringParser()
    table.update(outside, parser.parse(outside, "class Foo\n{\n  Void outside() {}\n}\n"))
    table.update(inside, parser.parse(inside, "class Foo\n{\n  Void inside() {}\n}\n"))
    preferred := "file://C:/A%20b/Caller.fan"
    verifyEq(table.findByName("Foo", preferred).uri, inside)
    verify(table.findType("Foo", preferred).children.any |node| { node.name == "inside" })
    workspace.removeFolder("file://C:/A%20b/sub/")
    verifyEq(workspace.getFolders, ["file:///c:/A b/"])
  }

  Void testFileUriRoundTripWithSpacesAndReservedCharacters()
  {
    root := tempDir()
    file := root + `A b/hash\#percent%20é.fan`
    key := WorkspaceManager.fileToUri(file)
    verifyEq(UriKey.canonical(key), key)
    verifyEq(WorkspaceManager.uriToFile(key).normalize, file.normalize)
    verifyEq(WorkspaceManager.uriToFile(UriKey.toClientUri(key)).normalize, file.normalize)
    if (Env.cur.os != "win32") verify(key.startsWith("file:///"))
  }

  Void testInitializeCanonicalFolders()
  {
    server := FantomLanguageServer()
    server.initialize([
      "rootUri": "file://C:/A%20b/",
      "workspaceFolders": [["uri": "file:///c%3A/A%20b/", "name": "root"]],
    ])
    verifyEq(server.workspaceFolders, ["file:///c:/A b/"])
    verifyEq(server.workspaceManager.getFolders, server.workspaceFolders)
  }
}
