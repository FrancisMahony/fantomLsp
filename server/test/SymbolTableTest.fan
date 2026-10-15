class SymbolTableTest : Test
{
  Void testPreferredFileLookup()
  {
    parser := RecoveringParser()
    a := parser.parse("file:///a.fan", "class Foo\n{\n  Void bar() {}\n}")
    b := parser.parse("file:///b.fan", "\nclass Foo\n{\n  Void bar() {}\n}")
    table := SymbolTable()
    table.update(a.uri, a)
    table.update(b.uri, b)

    // Check both files: map iteration order must not decide the winner.
    [a, b].each |result|
    {
      foo := result.nodes.find |n| { n.name == "Foo" }
      verifySame(table.findType("Foo", result.uri), foo)
      verifySame(table.findByName("Foo", result.uri)?.node, foo)
      verifyEq(table.findByName("bar", result.uri)?.uri, result.uri)
      verifyEq(table.findByName("Foo.bar", result.uri)?.uri, result.uri)
    }
  }

  Void testPreferredWorkspaceLookup()
  {
    workspace := WorkspaceManager()
    table := SymbolTable(workspace)
    parser := RecoveringParser()
    a := parser.parse("file:///projA/a.fan", "class Foo\n{\n  Void bar() {}\n}")
    b := parser.parse("file:///projB/b.fan", "class Foo\n{\n  Void bar() {}\n}")
    table.update(b.uri, b)
    table.update(a.uri, a)
    // Folders added after construction must be visible to the table.
    workspace.addFolder("file:///projA/")
    workspace.addFolder("file:///projB")

    [a, b].each |result, i|
    {
      root := i == 0 ? "file:///projA/" : "file:///projB/"
      foo := result.nodes.find |n| { n.name == "Foo" }
      [result.uri, root + "other.fan", root + "sub/other.fan"].each |uri|
      {
        verifySame(table.findType("Foo", uri), foo)
        verifySame(table.findByName("Foo", uri)?.node, foo)
        verifyEq(table.findByName("bar", uri)?.uri, result.uri)
        verifyEq(table.findByName("Foo.bar", uri)?.uri, result.uri)
        verifyNull(table.findType("Missing", uri))
        verifyNull(table.findByName("Missing", uri))
      }
    }
  }

  Void testNestedWorkspaceAndExactFilePriority()
  {
    workspace := WorkspaceManager()
    workspace.addFolder("file:///projA/sub/")
    workspace.addFolder("file:///projA/")
    table := SymbolTable(workspace)
    parser := RecoveringParser()
    uris := ["file:///projA/a.fan", "file:///projA/sub/a.fan", "file:///projA/sub/exact.fan"]
    uris.each |uri| { table.update(uri, parser.parse(uri, "class Foo {}")) }

    // Exact-file preference wins even with several matches in the same folder.
    uris.each |uri|
    {
      verifyEq(table.findByName("Foo", uri)?.uri, uri)
      verifySame(table.findType("Foo", uri), table.findByName("Foo", uri)?.node)
    }
    table.remove(uris[2])
    verifyEq(table.findByName("Foo", uris[2])?.uri, uris[1])
    verifySame(table.findType("Foo", uris[2]), table.findByName("Foo", uris[1])?.node)
  }

  Void testWorkspaceFallback()
  {
    workspace := WorkspaceManager()
    workspace.addFolder("file:///projA/")
    workspace.addFolder("file:///projB/")
    table := SymbolTable(workspace)
    result := RecoveringParser().parse("file:///projB/b.fan", "class Foo {}")
    table.update(result.uri, result)
    foo := result.nodes.find |n| { n.name == "Foo" }
    Str?[] preferences := [null, "file:///projA/other.fan", "file:///outside/other.fan"]
    preferences.each |uri|
    {
      verifySame(table.findType("Foo", uri), foo)
      verifyEq(table.findByName("Foo", uri)?.uri, result.uri)
      verifyNull(table.findType("Missing", uri))
      verifyNull(table.findByName("Missing", uri))
    }
  }

  ** The name index returns exactly the full-scan match set
  ** (entry.name OR node.name) through update/replace/remove.
  Void testFindAllByNameIndexMatchesFullScan()
  {
    parser := RecoveringParser()
    table := SymbolTable()
    srcA := "class Foo\n{\n  Void bar() {}\n  Int Foo := 1\n}\nclass Bar\n{\n  Void bar() {}\n}\n"
    srcB := "class Bar\n{\n  Void Foo() {}\n  Void baz() {}\n}\n"
    table.update("file:///b.fan", parser.parse("file:///b.fan", srcB))
    table.update("file:///a.fan", parser.parse("file:///a.fan", srcA))
    names := ["Foo", "Bar", "bar", "baz", "Foo.bar", "Bar.Foo", "Foo.Foo", "missing", ""]
    check := |->|
    {
      names.each |n|
      {
        expected := table.allEntries.findAll |e| { e.name == n || e.node.name == n }
        actual := table.findAllByName(n)
        verifyEq(actual.size, expected.size, n)
        verify(expected.all |e| { actual.any |x| { x === e } }, n)
      }
    }
    check()
    verifyEq(table.findAllByName("bar").map |e->Str| { e.name }, ["Foo.bar", "Bar.bar"])
    verifyEq(table.findAllByName("Foo").map |e->Str| { e.uri }, ["file:///a.fan", "file:///a.fan", "file:///b.fan"])
    // Replacement drops stale names and adds new ones.
    table.update("file:///a.fan", parser.parse("file:///a.fan", "class Qux { Void bar() {} }\n"))
    check()
    verifyEq(table.findAllByName("Foo").map |e->Str| { e.uri }, ["file:///b.fan"])
    verifyEq(table.findAllByName("Qux").size, 1)
    table.remove("file:///b.fan")
    check()
    verify(table.findAllByName("Foo").isEmpty)
    verify(table.findAllByName("baz").isEmpty)
    table.remove("file:///a.fan")
    table.remove("file:///never.fan")
    verify(table.findAllByName("bar").isEmpty)
    verify(table.typeEntries.isEmpty)
  }

  Void testTypeEntriesEqualsTypeSearch()
  {
    parser := RecoveringParser()
    table := SymbolTable()
    table.update("file:///a.fan", parser.parse("file:///a.fan", "class A { Void x() {} }\nmixin M {}\nenum class E { a, b }\n"))
    table.update("file:///b.fan", parser.parse("file:///b.fan", "class B {}\n"))
    expected := table.search("").findAll |e| { e.node.isType }
    actual := table.typeEntries
    verifyEq(actual.size, expected.size)
    actual.each |e, i| { verifySame(e, expected[i]) }
  }

  Void testPreferredFileFallback()
  {
    parser := RecoveringParser()
    table := SymbolTable()
    a := parser.parse("file:///a.fan", "class Foo {}")
    table.update(a.uri, a)
    table.update("file:///b.fan", parser.parse("file:///b.fan", "class Bar {}"))
    foo := a.nodes.find |n| { n.name == "Foo" }

    Str?[] preferences := [null, "file:///b.fan", "file:///missing.fan"]
    preferences.each |uri|
    {
      verifySame(table.findType("Foo", uri), foo)
      verifySame(table.findByName("Foo", uri)?.node, foo)
      verifyNull(table.findType("Missing", uri))
      verifyNull(table.findByName("Missing", uri))
    }
    verifySame(table.findType("Foo"), foo)
    verifySame(table.findByName("Foo")?.node, foo)
  }
}
