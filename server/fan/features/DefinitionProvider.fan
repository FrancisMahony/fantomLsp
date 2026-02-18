class DefinitionProvider
{
  Obj? definition(DocumentState doc, Position pos, SymbolTable symbolTable, TypeResolver typeResolver)
  {
    word := doc.getWordAt(pos)
    if (word.isEmpty) return null

    entry := symbolTable.findByName(word)
    if (entry != null)
    {
      return Location(entry.uri, entry.node.selectionRange).toMap
    }

    allEntries := symbolTable.allEntries
    allEntries.each |e|
    {
      e.node.children.each |child|
      {
        if (child.name == word)
          return Location(e.uri, child.selectionRange).toMap
      }
    }

    return null
  }
}
