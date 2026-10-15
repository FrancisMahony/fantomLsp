class CodeActionProviderTest : Test
{
  private CodeActionProvider provider := CodeActionProvider()
  private RecoveringParser parser := RecoveringParser()

  private ParseResult parse(Str src) { parser.parse("file:///test.fan", src) }

  private DocumentState makeDoc(Str src)
  {
    DocumentState("file:///test.fan", 1, src)
  }

  private [Str:Obj?][] actions(Str src, LspRange range, [Str:Obj?] context := [Str:Obj?][:])
  {
    doc := makeDoc(src)
    r := parse(src)
    result := provider.codeActions(doc, r, range, context)
    return result as [Str:Obj?][] ?: [,]
  }

  private LspRange zeroRange() { LspRange(Position(0, 0), Position(0, 0)) }

  Void testNoActionsOnPlainCode()
  {
    src := "class Foo {}"
    result := actions(src, zeroRange)
    verifyEq(result.size, 0)
  }

  Void testRemoveUnusedUsing()
  {
    src := "using util\nclass Foo {}"
    result := actions(src, zeroRange)
    titles := result.map |a| { a["title"] }
    verify(titles.any |t| { (t as Str)?.contains("Remove unused") == true })
  }

  Void testKeepUsedUsing()
  {
    src := "using util::Regex\nclass Foo { Regex r }"
    result := actions(src, zeroRange)
    titles := result.map |a| { a["title"] }
    verify(titles.all |t| { (t as Str)?.contains("Remove unused") != true })
  }

  Void testSysUsingNeverRemoved()
  {
    src := "using sys\nclass Foo {}"
    result := actions(src, zeroRange)
    titles := result.map |a| { a["title"] }
    verify(titles.all |t| { (t as Str)?.contains("Remove unused") != true })
  }

  Void testUncommentLine()
  {
    src := "// class Foo {}"
    range := LspRange(Position(0, 0), Position(0, src.size))
    result := actions(src, range)
    titles := result.map |a| { a["title"] }
    verify(titles.any |t| { (t as Str)?.contains("Uncomment") == true })
  }

  Void testUncommentReplacesFullLineNotSelection()
  {
    src := "  // class Foo {}"
    range := LspRange(Position(0, 4), Position(0, 6))
    result := actions(src, range)
    action := result.find |a| { (a["title"] as Str)?.contains("Uncomment") == true }
    verifyNotNull(action)
    edit := action["edit"] as [Str:Obj?]
    changes := edit["changes"] as [Str:Obj?]
    edits := changes["file:///test.fan"] as [Str:Obj?][]
    r := edits[0]["range"] as [Str:Obj?]
    start := r["start"] as [Str:Obj?]
    end := r["end"] as [Str:Obj?]
    verifyEq(start["character"], 0)
    verifyEq(end["character"], src.size)
  }

  Void testNoUncommentOnNonComment()
  {
    src := "class Foo {}"
    range := LspRange(Position(0, 0), Position(0, src.size))
    result := actions(src, range)
    titles := result.map |a| { a["title"] }
    verify(titles.all |t| { (t as Str)?.contains("Uncomment") != true })
  }

  Void testRemoveUnusedUsingEditStructure()
  {
    src := "using util\nclass Foo {}"
    result := actions(src, zeroRange)
    removeAction := result.find |a| { (a["title"] as Str)?.contains("Remove unused") == true }
    verifyNotNull(removeAction)
    verifyEq(removeAction["kind"], "quickfix")
    edit := removeAction["edit"] as [Str:Obj?]
    verifyNotNull(edit)
    changes := edit["changes"] as [Str:Obj?]
    verifyNotNull(changes)
    verify(changes.containsKey("file:///test.fan"))
  }

  Void testExtractUnknownTypeNameSimple()
  {
    verifyEq(provider.extractUnknownTypeName("Unknown type 'Regex'"), "Regex")
  }

  Void testExtractUnknownTypeNameQualified()
  {
    verifyEq(provider.extractUnknownTypeName("Unknown type 'util::Regex'"), "Regex")
  }

  Void testExtractUnknownTypeNameNoMatch()
  {
    verifyNull(provider.extractUnknownTypeName("Some other error"))
  }

  Void testAddMissingUsingAction()
  {
    context := [Str:Obj?]["diagnostics": [[Str:Obj?]["message": "Unknown type 'Regex'"]]]
    src := "class Foo {}"
    result := actions(src, zeroRange, context)
    titles := result.map |a| { a["title"] }
    verify(titles.any |t| { (t as Str)?.startsWith("Add 'using ") == true })
  }

  Void testOrganizeUsings()
  {
    src := "using util\nusing sys::Regex\nusing concurrent\nclass Foo { Regex r }"
    result := actions(src, zeroRange)
    action := result.find |a| { a["title"] == "Organize usings" }
    verifyNotNull(action)
    verifyEq(action["kind"], "source.organizeImports")
    edit := action["edit"] as [Str:Obj?]
    changes := edit["changes"] as [Str:Obj?]
    edits := changes["file:///test.fan"] as [Str:Obj?][]
    verifyEq(edits[0]["newText"], "using sys::Regex\n")
  }
}
