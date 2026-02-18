class ReferencesProvider
{
  Obj? references(DocumentState doc, Position pos, SymbolTable symbolTable, ReferenceIndex referenceIndex)
  {
    word := doc.getWordAt(pos)
    if (word.isEmpty) return null

    locations := [Str:Obj?][,]

    entries := symbolTable.findAllByName(word)
    entries.each |e|
    {
      locations.add(Location(e.uri, e.node.selectionRange).toMap)
    }

    refs := referenceIndex.findReferences(word)
    refs.each |r|
    {
      locations.add(Location(r.uri, r.range).toMap)
    }

    return locations.isEmpty ? null : locations
  }
}
