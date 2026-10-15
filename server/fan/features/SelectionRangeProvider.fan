class SelectionRangeProvider
{
  [Str:Obj?]?[] selectionRanges(DocumentState doc, ParseResult parseResult, Position[] positions)
  {
    positions.map |pos| { rangeFor(doc, parseResult, pos) }
  }

  private [Str:Obj?]? rangeFor(DocumentState doc, ParseResult parseResult, Position pos)
  {
    word := wordRangeAt(doc, pos)
    method := enclosingSlot(parseResult, pos)
    type := enclosingType(parseResult, pos)

    [Str:Obj?]? cur := null
    if (type != null)
      cur = ["range": type.range.toMap]
    if (method != null)
    {
      m := Str:Obj?["range": method.range.toMap]
      if (cur != null) m["parent"] = cur
      cur = m
    }
    if (word != null)
    {
      w := Str:Obj?["range": word.toMap]
      if (cur != null) w["parent"] = cur
      cur = w
    }
    return cur
  }

  private LspRange? wordRangeAt(DocumentState doc, Position pos)
  {
    if (pos.line < 0 || pos.line >= doc.lines.size) return null
    line := doc.lines[pos.line]
    i := pos.character.min(line.size)
    if (i > 0 && i <= line.size && !isIdentChar(line[i - 1]) && (i >= line.size || !isIdentChar(line[i])))
      return null
    start := i
    while (start > 0 && isIdentChar(line[start - 1])) start--
    end := i
    while (end < line.size && isIdentChar(line[end])) end++
    if (start >= end) return null
    return LspRange(Position(pos.line, start), Position(pos.line, end))
  }

  private AstNode? enclosingSlot(ParseResult parseResult, Position pos)
  {
    parseResult.nodes.eachWhile |node|
    {
      if (!node.isType) return null
      return node.children.find |child|
      {
        child.isSlot && contains(child.range, pos)
      }
    }
  }

  private AstNode? enclosingType(ParseResult parseResult, Position pos)
  {
    parseResult.nodes.find |node| { node.isType && contains(node.range, pos) }
  }

  private Bool contains(LspRange range, Position pos)
  {
    if (pos.line < range.start.line || pos.line > range.end.line) return false
    if (pos.line == range.start.line && pos.character < range.start.character) return false
    if (pos.line == range.end.line && pos.character > range.end.character) return false
    return true
  }

  private static Bool isIdentChar(Int ch) { ch.isAlphaNum || ch == '_' }
}
