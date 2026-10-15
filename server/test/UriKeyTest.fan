using compiler

class UriKeyTest : Test
{
  Void testCanonicalWindowsVariantsAndIdempotence()
  {
    variants := ["file:///c%3A/A%20b/x.fan", "file:///C:/A b/x.fan",
                 "file://C:/A%20b/x.fan", "file:C:\\A b\\x.fan",
                 "FILE:/C:/A%20b/x.fan"]
    variants.each |uri|
    {
      key := UriKey.canonical(uri)
      verifyEq(key, "file:///c:/A b/x.fan")
      verifyEq(UriKey.canonical(key), key)
      verifyEq(UriKey.toClientUri(key), "file:///c%3A/A%20b/x.fan")
    }
  }

  Void testReservedUnicodeAndLiteralPercentRoundTrip()
  {
    client := "file:///c%3A/A%20b/%23%3F%40%2B%25%2520%C3%A9.fan"
    key := UriKey.canonical(client)
    verifyEq(key, "file:///c:/A b/#?@+%25%2520é.fan")
    verifyEq(UriKey.canonical(key), key)
    verifyEq(UriKey.toClientUri(key), client)
    verify(UriKey.canonical("file:///x%2520.fan") != UriKey.canonical("file:///x%20.fan"))
  }

  Void testPosixNetworkAndNonFileUris()
  {
    verifyEq(UriKey.canonical("file:/tmp/A%20b.fan"), "file:///tmp/A b.fan")
    verifyEq(UriKey.toClientUri("file:///tmp/A b.fan"), "file:///tmp/A%20b.fan")
    verifyEq(UriKey.canonical("file://server/share/A%20b.fan"), "file://server/share/A b.fan")
    verifyEq(UriKey.toClientUri("file://server/share/A b.fan"), "file://server/share/A%20b.fan")
    ["untitled:Untitled-1", "https://host/A%20b", "jar:file:/pod!/src/X.fan"].each |uri|
    {
      verifyEq(UriKey.canonical(uri), uri)
      verifyEq(UriKey.toClientUri(uri), uri)
    }
  }

  Void testDocumentKeysAndOriginalUriLifecycle()
  {
    server := FantomLanguageServer()
    original := "file://C:/A%20b/x.fan"
    key := UriKey.canonical(original)
    server.docManager.open(TextDocumentItem(original, "fantom", 1, "class A {}"))
    verifyEq(server.docManager.openUris, [key])
    verifyEq(server.docManager.getDocument(key).uri, key)
    verifyEq(server.clientUri(key), original)
    server.docManager.change("file:///C:/A b/x.fan", 2, TextDocumentContentChangeEvent(null, "class B {}"))
    verifyEq(server.docManager.getDocument(original).version, 2)
    verifyEq(server.docManager.parseDocument(original).nodes.first.name, "B")
    server.docManager.updateText(original, "class C {}")
    verifyEq(server.docManager.parseDocument(key).nodes.first.name, "C")
    server.docManager.open(TextDocumentItem("file:///c%3A/A%20b/x.fan", "fantom", 3, "class D {}"))
    verifyEq(server.docManager.openUris, [key])
    verifyEq(server.clientUri(key), "file:///c%3A/A%20b/x.fan")
    server.docManager.close(original)
    verifyEq(server.docManager.openUris.size, 0)
    verifyEq(server.clientUri(key), UriKey.toClientUri(key))
  }

  Void testCompilerErrorsMatchFullNormalizedPath()
  {
    root := tempDir()
    target := root + `this/dir/Foo.fan`
    other := root + `other/dir/Foo.fan`
    right := CompilerErr("right", Loc.makeFile(target, 1, 1))
    wrong := CompilerErr("wrong", Loc.makeFile(other, 1, 1))
    normalized := CompilerErr("normalized", Loc((target.parent + `../dir/Foo.fan`).osPath, 2, 1))
    uriLoc := CompilerErr("uri", Loc(UriKey.toClientUri(WorkspaceManager.fileToUri(target)), 3, 1))
    unknown := CompilerErr("unknown", null)
    diag := CompilerDiagnostics()
    errs := [right, wrong, normalized, uriLoc, unknown]
    verifyEq(diag.filterErrorsForFile(errs, WorkspaceManager.fileToUri(target)), [right, normalized, uriLoc])
    verifyEq(diag.filterErrorsForFile(errs, "untitled:Foo.fan").size, 0)
    caseErr := CompilerErr("case", Loc(target.osPath.upper, 1, 1))
    verifyEq(diag.filterErrorsForFile([caseErr], WorkspaceManager.fileToUri(target)).size,
      Env.cur.os == "win32" ? 1 : 0)
  }
}
