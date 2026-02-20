class RenameProvider
{
  [Str:Obj?]? prepareRename(DocumentState doc, Position pos)
  {
    word := doc.getWordAt(pos)
    if (word.isEmpty) return null

    line := doc.getLine(pos.line)
    if (line == null) return null

    startCol := pos.character
    endCol := pos.character

    while (startCol > 0 && isIdentChar(line[startCol - 1])) startCol--
    while (endCol < line.size && isIdentChar(line[endCol])) endCol++

    range := LspRange(Position(pos.line, startCol), Position(pos.line, endCol))

    return [
      "range": range.toMap,
      "placeholder": word
    ]
  }

  WorkspaceEdit? rename(DocumentState doc, Position pos, Str newName, SymbolTable symbolTable, ReferenceIndex referenceIndex)
  {
    word := doc.getWordAt(pos)
    if (word.isEmpty) return null

    changes := Str:TextEdit[][:]

    entries := symbolTable.findAllByName(word)
    entries.each |e|
    {
      uri := e.uri
      if (changes[uri] == null) changes[uri] = TextEdit[,]
      changes[uri].add(TextEdit(e.node.selectionRange, newName))
    }

    refs := referenceIndex.findReferences(word)
    refs.each |r|
    {
      uri := r.uri
      if (changes[uri] == null) changes[uri] = TextEdit[,]
      changes[uri].add(TextEdit(r.range, newName))
    }

    if (changes.isEmpty) return null
    return WorkspaceEdit(changes)
  }

  private static Bool isIdentChar(Int ch)
  {
    ch.isAlphaNum || ch == '_'
  }
}
