class PositionMapperTest : Test
{
  Void testIdenticalText()
  {
    text := "class Foo\n{\n  Void run() {}\n}\n"
    mapper := PositionMapper(text, text)
    verify(mapper.isImmutable)
    verifyPos(mapper.toNew(Position(2, 7)), 2, 7)
    verifyPos(mapper.toOld(Position(2, 7)), 2, 7)
    verifyRange(mapper.rangeToNew(range(2, 7, 10)), 2, 7, 10)
    verifyRoundTrips(text, text)
  }

  Void testInsertionAbove()
  {
    oldText := "class Foo\n{\n  Void run() {}\n}"
    newText := "// added\n// another line\n" + oldText
    mapper := PositionMapper(oldText, newText)
    verifyPos(mapper.toNew(Position(2, 7)), 4, 7)
    verifyPos(mapper.toOld(Position(4, 7)), 2, 7)
    verifyNull(mapper.toOld(Position(0, 0)))
    verifyNull(mapper.toOld(Position(1, 0)))
    verifyRange(mapper.rangeToNew(range(2, 7, 10)), 4, 7, 10)
    verifyRoundTrips(oldText, newText)
  }

  Void testDeletionAbove()
  {
    oldText := "// removed\nclass Foo\n{\n  Void run() {}\n}"
    newText := "class Foo\n{\n  Void run() {}\n}"
    mapper := PositionMapper(oldText, newText)
    verifyNull(mapper.toNew(Position(0, 0)))
    verifyPos(mapper.toNew(Position(3, 7)), 2, 7)
    verifyPos(mapper.toOld(Position(2, 7)), 3, 7)
    verifyRoundTrips(oldText, newText)
  }

  Void testEditOnTargetLine()
  {
    oldText := "class Foo\n  Void run() {}\nend"
    newText := "class Foo\n  Void run() { echo(1) }\nend"
    mapper := PositionMapper(oldText, newText)
    // Even a token whose spelling survives an edit on its line is untrusted.
    verifyNull(mapper.toNew(Position(1, 7)))
    verifyNull(mapper.toOld(Position(1, 7)))
    verifyNull(mapper.rangeToNew(range(1, 7, 10)))
    verifyPos(mapper.toNew(Position(0, 6)), 0, 6)
    verifyPos(mapper.toNew(Position(2, 0)), 2, 0)
    verifyRoundTrips(oldText, newText)
  }

  Void testEditsBelow()
  {
    oldText := "class Foo\n  Void run() {}\nend"
    newText := "class Foo\n  Void run() {}\nchanged\nmore"
    mapper := PositionMapper(oldText, newText)
    verifyPos(mapper.toNew(Position(1, 7)), 1, 7)
    verifyRange(mapper.rangeToNew(range(1, 7, 10)), 1, 7, 10)
    verifyNull(mapper.toNew(Position(2, 0)))
    verifyNull(mapper.toOld(Position(3, 0)))
    verifyRoundTrips(oldText, newText)
  }

  Void testMixedLineEndings()
  {
    oldText := "class Foo\r\n{\n  Void run() {}\r\n}\r\n"
    newText := "class Foo\n{\r\n  Void run() {}\n}\n"
    mapper := PositionMapper(oldText, newText)
    verifyPos(mapper.toNew(Position(2, 7)), 2, 7)
    verifyRange(mapper.rangeToNew(range(2, 7, 10)), 2, 7, 10)
    verifyPos(mapper.toNew(Position(4, 0)), 4, 0)
    verifyRoundTrips(oldText, newText)
    verifyRoundTrips(oldText, "// inserted\r\n" + newText)
  }

  Void testChangedMiddleIsConservative()
  {
    oldText := "prefix\nold\nunchanged island\nold again\nsuffix"
    newText := "prefix\nnew\nunchanged island\nnew again\nextra\nsuffix"
    mapper := PositionMapper(oldText, newText)
    verifyNull(mapper.toNew(Position(2, 0)))
    verifyNull(mapper.toOld(Position(2, 0)))
    verifyPos(mapper.toNew(Position(4, 0)), 5, 0)
    verifyRoundTrips(oldText, newText)
  }

  Void testRepeatedLinesDoNotOverlap()
  {
    oldText := "same\nsame"
    newText := "same\nsame\nsame"
    mapper := PositionMapper(oldText, newText)
    verifyPos(mapper.toNew(Position(0, 2)), 0, 2)
    verifyPos(mapper.toNew(Position(1, 2)), 1, 2)
    verifyNull(mapper.toOld(Position(2, 2)))
    verifyRoundTrips(oldText, newText)
    verifyRoundTrips(newText, oldText)
  }

  Void testEmptyAndTrailingLines()
  {
    verifyRoundTrips("", "")
    verifyPos(PositionMapper("", "").toNew(Position(0, 0)), 0, 0)
    verifyRoundTrips("", "added")
    verifyNull(PositionMapper("", "added").toNew(Position(0, 0)))
    verifyNull(PositionMapper("added", "").toOld(Position(0, 0)))
    verifyRoundTrips("", "added\n")
    verifyPos(PositionMapper("", "added\n").toNew(Position(0, 0)), 1, 0)
    verifyRoundTrips("line", "line\n")
    verifyNull(PositionMapper("line", "line\n").toOld(Position(1, 0)))
    verifyRoundTrips("line\n\n", "line\n")
    verifyRoundTrips("old", "new\nother")
  }

  Void testRangesRequireOneUnchangedLine()
  {
    mapper := PositionMapper("prefix\nold\nsuffix", "prefix\nnew\nextra\nsuffix")
    verifyNull(mapper.rangeToNew(LspRange(Position(0, 0), Position(2, 3))))
    verifyNull(mapper.rangeToNew(LspRange(Position(0, 0), Position(1, 3))))
    verifyNull(mapper.rangeToNew(LspRange(Position(1, 0), Position(2, 3))))
    verifyRange(mapper.rangeToNew(range(2, 0, 6)), 3, 0, 6)
    verifyRange(mapper.rangeToNew(range(2, 6, 6)), 3, 6, 6)
  }

  Void testOutOfBoundsPositions()
  {
    mapper := PositionMapper("one", "one\ntwo")
    verifyNull(mapper.toNew(Position(-1, 0)))
    verifyNull(mapper.toOld(Position(-1, 0)))
    verifyNull(mapper.toNew(Position(1, 0)))
    verifyNull(mapper.toOld(Position(2, 0)))
    verifyNull(mapper.toNew(Position(0, -1)))
    verifyNull(mapper.toOld(Position(0, -1)))
  }

  ** Check every valid character boundary in both directions, not just line starts.
  private Void verifyRoundTrips(Str oldText, Str newText)
  {
    mapper := PositionMapper(oldText, newText)
    oldText.replace("\r\n", "\n").split('\n', false).each |line, i|
    {
      for (col := 0; col <= line.size; col++)
      {
        mapped := mapper.toNew(Position(i, col))
        if (mapped != null) verifyPos(mapper.toOld(mapped), i, col)
      }
    }
    newText.replace("\r\n", "\n").split('\n', false).each |line, i|
    {
      for (col := 0; col <= line.size; col++)
      {
        mapped := mapper.toOld(Position(i, col))
        if (mapped != null) verifyPos(mapper.toNew(mapped), i, col)
      }
    }
  }

  private Void verifyPos(Position? pos, Int line, Int col)
  {
    verifyNotNull(pos)
    verifyEq(pos?.line, line)
    verifyEq(pos?.character, col)
  }

  private Void verifyRange(LspRange? mapped, Int line, Int startCol, Int endCol)
  {
    verifyNotNull(mapped)
    verifyPos(mapped?.start, line, startCol)
    verifyPos(mapped?.end, line, endCol)
  }

  private LspRange range(Int line, Int startCol, Int endCol)
  {
    LspRange(Position(line, startCol), Position(line, endCol))
  }
}
