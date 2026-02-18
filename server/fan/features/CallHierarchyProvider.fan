class CallHierarchyProvider
{
  Obj? prepare(DocumentState doc, Position pos, SymbolTable symbolTable)
  {
    word := doc.getWordAt(pos)
    if (word.isEmpty) return null

    entry := symbolTable.findByName(word)
    if (entry == null) return null
    node := entry.node
    if (node.kind != AstNodeKind.methodDef && node.kind != AstNodeKind.ctorDef) return null

    return [[
      "name": node.name,
      "kind": node.symbolKind,
      "uri": entry.uri,
      "range": node.range.toMap,
      "selectionRange": node.selectionRange.toMap,
    ]]
  }

  Obj? incomingCalls([Str:Obj?] item, SymbolTable symbolTable, ReferenceIndex referenceIndex)
  {
    name := item["name"] as Str ?: ""
    if (name.isEmpty) return [,]

    refs := referenceIndex.findReferences(name)
    return refs.map |r -> [Str:Obj?]|
    {
      return [
        "from": [
          "name": name,
          "kind": DocumentSymbol.methodKind,
          "uri": r.uri,
          "range": r.range.toMap,
          "selectionRange": r.range.toMap,
        ],
        "fromRanges": [r.range.toMap],
      ]
    }
  }

  Obj? outgoingCalls([Str:Obj?] item, SymbolTable symbolTable, ReferenceIndex referenceIndex)
  {
    return [,]
  }
}
