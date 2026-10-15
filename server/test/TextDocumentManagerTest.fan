class TextDocumentManagerTest : Test
{
  private TextDocumentManager mgr := TextDocumentManager()

  private TextDocumentItem makeItem(Str uri, Str text, Int version := 1)
  {
    TextDocumentItem(uri, "fantom", version, text)
  }

  override Void setup() { mgr = TextDocumentManager() }

  // ── open / close / getDocument ────────────────────────────────────────────────

  Void testOpenAndGetDocument()
  {
    mgr.open(makeItem("file:///a.fan", "class Foo {}"))
    doc := mgr.getDocument("file:///a.fan")
    verifyNotNull(doc)
    verifyEq(doc.uri, "file:///a.fan")
    verifyEq(doc.version, 1)
  }

  Void testGetDocumentMissing()
  {
    verifyNull(mgr.getDocument("file:///not-there.fan"))
  }

  Void testCloseRemovesDocument()
  {
    mgr.open(makeItem("file:///b.fan", "class B {}"))
    mgr.close("file:///b.fan")
    verifyNull(mgr.getDocument("file:///b.fan"))
  }

  Void testCloseMissingIsNoop()
  {
    // Should not throw
    mgr.close("file:///nonexistent.fan")
  }

  Void testMultipleDocuments()
  {
    mgr.open(makeItem("file:///x.fan", "class X {}"))
    mgr.open(makeItem("file:///y.fan", "class Y {}"))
    verifyNotNull(mgr.getDocument("file:///x.fan"))
    verifyNotNull(mgr.getDocument("file:///y.fan"))
  }

  // ── change (full document replace) ───────────────────────────────────────────

  Void testChangeFullReplace()
  {
    mgr.open(makeItem("file:///c.fan", "class Old {}"))
    evt := TextDocumentContentChangeEvent(null, "class New {}")
    mgr.change("file:///c.fan", 2, evt)
    doc := mgr.getDocument("file:///c.fan")
    verifyEq(doc.text, "class New {}")
    verifyEq(doc.version, 2)
    verify(doc.dirty)
  }

  Void testChangeMissingDocIsNoop()
  {
    evt := TextDocumentContentChangeEvent(null, "anything")
    mgr.change("file:///missing.fan", 1, evt)
    // Should not throw
  }

  // ── change (range-based edit) ──────────────────────────────────────────────────

  Void testChangeRangeReplace()
  {
    mgr.open(makeItem("file:///d.fan", "hello world"))
    range := LspRange(Position(0, 6), Position(0, 11))  // "world"
    evt := TextDocumentContentChangeEvent(range, "Fantom")
    mgr.change("file:///d.fan", 2, evt)
    doc := mgr.getDocument("file:///d.fan")
    verifyEq(doc.text, "hello Fantom")
  }

  Void testChangeRangeInsert()
  {
    mgr.open(makeItem("file:///e.fan", "line one\nline two"))
    range := LspRange(Position(0, 8), Position(0, 8))  // insert at end of line 0
    evt := TextDocumentContentChangeEvent(range, " extra")
    mgr.change("file:///e.fan", 2, evt)
    doc := mgr.getDocument("file:///e.fan")
    verify(doc.text.startsWith("line one extra"))
  }

  Void testChangeRangeMultiLine()
  {
    mgr.open(makeItem("file:///f.fan", "aaa\nbbb\nccc"))
    // Replace "bbb" entirely
    range := LspRange(Position(1, 0), Position(1, 3))
    evt := TextDocumentContentChangeEvent(range, "zzz")
    mgr.change("file:///f.fan", 2, evt)
    doc := mgr.getDocument("file:///f.fan")
    verifyEq(doc.text, "aaa\nzzz\nccc")
  }

  // ── updateText ────────────────────────────────────────────────────────────────

  Void testUpdateText()
  {
    mgr.open(makeItem("file:///g.fan", "original"))
    mgr.updateText("file:///g.fan", "updated")
    doc := mgr.getDocument("file:///g.fan")
    verifyEq(doc.text, "updated")
    verify(doc.dirty)
  }

  // ── parseDocument ─────────────────────────────────────────────────────────────

  Void testParseDocumentBasic()
  {
    mgr.open(makeItem("file:///h.fan", "class Foo {}"))
    r := mgr.parseDocument("file:///h.fan")
    verifyNotNull(r)
    cls := r.nodes.find |n| { n.kind == AstNodeKind.classDef }
    verifyNotNull(cls)
    verifyEq(cls.name, "Foo")
  }

  Void testParseDocumentCaching()
  {
    mgr.open(makeItem("file:///i.fan", "class Cached {}"))
    r1 := mgr.parseDocument("file:///i.fan")
    r2 := mgr.parseDocument("file:///i.fan")
    // Same object returned when not dirty
    verify(r1 === r2)
  }

  Void testParseDocumentDirtyInvalidatesCache()
  {
    mgr.open(makeItem("file:///j.fan", "class Original {}"))
    r1 := mgr.parseDocument("file:///j.fan")

    evt := TextDocumentContentChangeEvent(null, "class Changed {}")
    mgr.change("file:///j.fan", 2, evt)
    r2 := mgr.parseDocument("file:///j.fan")

    // After a change the parse result is fresh
    verify(r1 !== r2)
    cls := r2.nodes.find |n| { n.kind == AstNodeKind.classDef }
    verifyEq(cls.name, "Changed")
  }

  Void testParseDocumentMissingReturnsEmpty()
  {
    r := mgr.parseDocument("file:///noexist.fan")
    verifyNotNull(r)
    verifyEq(r.nodes.size, 0)
  }

  // ── DocumentState.lines() ─────────────────────────────────────────────────────

  Void testDocumentStateLines()
  {
    mgr.open(makeItem("file:///k.fan", "line0\nline1\nline2"))
    doc := mgr.getDocument("file:///k.fan")
    ls := doc.lines
    verifyEq(ls.size, 3)
    verifyEq(ls[0], "line0")
    verifyEq(ls[2], "line2")
  }

  // ── DocumentState.getLine() ───────────────────────────────────────────────────

  Void testGetLineValid()
  {
    mgr.open(makeItem("file:///l.fan", "alpha\nbeta\ngamma"))
    doc := mgr.getDocument("file:///l.fan")
    verifyEq(doc.getLine(0), "alpha")
    verifyEq(doc.getLine(1), "beta")
    verifyEq(doc.getLine(2), "gamma")
  }

  Void testGetLineOutOfBounds()
  {
    mgr.open(makeItem("file:///m.fan", "only one line"))
    doc := mgr.getDocument("file:///m.fan")
    verifyNull(doc.getLine(5))
    verifyNull(doc.getLine(-1))
  }

  // ── DocumentState.getWordAt() ─────────────────────────────────────────────────

  Void testGetWordAtMiddle()
  {
    mgr.open(makeItem("file:///n.fan", "myVar := 42"))
    doc := mgr.getDocument("file:///n.fan")
    word := doc.getWordAt(Position(0, 2))  // inside "myVar"
    verifyEq(word, "myVar")
  }

  Void testGetWordAtStart()
  {
    mgr.open(makeItem("file:///o.fan", "hello world"))
    doc := mgr.getDocument("file:///o.fan")
    verifyEq(doc.getWordAt(Position(0, 0)), "hello")
  }

  Void testGetWordAtEnd()
  {
    mgr.open(makeItem("file:///p.fan", "foo bar"))
    doc := mgr.getDocument("file:///p.fan")
    verifyEq(doc.getWordAt(Position(0, 6)), "bar")
  }

  Void testGetWordAtNonIdent()
  {
    mgr.open(makeItem("file:///q.fan", "x := y"))
    doc := mgr.getDocument("file:///q.fan")
    // Cursor on ":=" returns empty
    verifyEq(doc.getWordAt(Position(0, 3)), "")
  }

  Void testGetWordAtEmptyLine()
  {
    mgr.open(makeItem("file:///r.fan", "\n\n"))
    doc := mgr.getDocument("file:///r.fan")
    verifyEq(doc.getWordAt(Position(0, 0)), "")
  }

  Void testGetWordAtWithUnderscore()
  {
    mgr.open(makeItem("file:///s.fan", "my_var := 1"))
    doc := mgr.getDocument("file:///s.fan")
    verifyEq(doc.getWordAt(Position(0, 3)), "my_var")
  }

  Void testGetWordAtQualifiedName()
  {
    doc := DocumentState("test://qname", 1, "sys::Str value")
    [0, 1, 2, 3, 5, 6, 7, 8].each |col|
    {
      verifyEq(doc.getWordAt(Position(0, col)), "sys::Str")
    }
    verifyEq(doc.getWordAt(Position(0, 10)), "value")
    verifyEq(doc.getWordAt(Position(0, 100)), "")
    verifyEq(doc.getWordAt(Position(0, -1)), "")

    doc.text = "sys:: Str"
    verifyEq(doc.getWordAt(Position(0, 1)), "sys")
    verifyEq(doc.getWordAt(Position(0, 7)), "Str")
    doc.text = "sys ::Str"
    verifyEq(doc.getWordAt(Position(0, 7)), "Str")
    doc.text = "sys:Str"
    verifyEq(doc.getWordAt(Position(0, 1)), "sys")
    verifyEq(doc.getWordAt(Position(0, 5)), "Str")
    doc.text = "sys::"
    verifyEq(doc.getWordAt(Position(0, 1)), "sys")
  }

  // ── DocumentState.offsetAt() ──────────────────────────────────────────────────

  Void testOffsetAtLineZero()
  {
    mgr.open(makeItem("file:///t.fan", "abcde\nfghij"))
    doc := mgr.getDocument("file:///t.fan")
    verifyEq(doc.offsetAt(Position(0, 0)), 0)
    verifyEq(doc.offsetAt(Position(0, 3)), 3)
  }

  Void testOffsetAtSecondLine()
  {
    // "abcde\n" is 6 chars (5 + newline), so line 1 char 0 = offset 6
    mgr.open(makeItem("file:///u.fan", "abcde\nfghij"))
    doc := mgr.getDocument("file:///u.fan")
    verifyEq(doc.offsetAt(Position(1, 0)), 6)
    verifyEq(doc.offsetAt(Position(1, 2)), 8)
  }

  Void testOffsetAtCrlf()
  {
    mgr.open(makeItem("file:///crlf-off.fan", "abcde\r\nfghij"))
    doc := mgr.getDocument("file:///crlf-off.fan")
    verifyEq(doc.offsetAt(Position(0, 3)), 3)
    verifyEq(doc.offsetAt(Position(1, 0)), 7)
    verifyEq(doc.offsetAt(Position(1, 2)), 9)
  }

  Void testChangeRangeInsertCrlf()
  {
    mgr.open(makeItem("file:///crlf-ins.fan", "line one\r\nline two"))
    range := LspRange(Position(0, 8), Position(0, 8))
    evt := TextDocumentContentChangeEvent(range, " extra")
    mgr.change("file:///crlf-ins.fan", 2, evt)
    doc := mgr.getDocument("file:///crlf-ins.fan")
    verifyEq(doc.text, "line one extra\r\nline two")
  }

  Void testChangeRangeDeleteCrlf()
  {
    mgr.open(makeItem("file:///crlf-del.fan", "aaa\r\nbbb\r\nccc"))
    range := LspRange(Position(1, 0), Position(1, 3))
    evt := TextDocumentContentChangeEvent(range, "")
    mgr.change("file:///crlf-del.fan", 2, evt)
    doc := mgr.getDocument("file:///crlf-del.fan")
    verifyEq(doc.text, "aaa\r\n\r\nccc")
  }
}
