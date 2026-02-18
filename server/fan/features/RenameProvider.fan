class RenameProvider
{
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
}
