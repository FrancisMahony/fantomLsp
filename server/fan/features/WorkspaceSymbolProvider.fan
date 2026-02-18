class WorkspaceSymbolProvider
{
  Obj? search(Str query, SymbolTable symbolTable)
  {
    if (query.isEmpty) return [,]

    entries := symbolTable.search(query)
    return entries.map |e -> [Str:Obj?]|
    {
      kind := e.node.symbolKind
      return [
        "name": e.node.name,
        "kind": kind,
        "location": Location(e.uri, e.node.selectionRange).toMap,
        "containerName": e.node.parent?.name,
      ]
    }
  }
}
