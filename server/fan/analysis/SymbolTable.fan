class SymbolTable
{
  private Str:SymbolEntry[] symbols := [:]

  Void update(Str uri, ParseResult result)
  {
    entries := SymbolEntry[,]
    result.nodes.each |node|
    {
      if (node.isType)
      {
        entries.add(SymbolEntry(node.name, uri, node))
        node.children.each |child|
        {
          if (child.isSlot || child.kind == AstNodeKind.enumValDef)
            entries.add(SymbolEntry(child.qname, uri, child))
        }
      }
    }
    symbols[uri] = entries
  }

  Void remove(Str uri) { symbols.remove(uri) }

  AstNode? findType(Str name)
  {
    vals := symbols.vals
    for (i := 0; i < vals.size; i++)
    {
      entries := vals[i]
      entry := entries.find |e| { e.node.isType && e.name == name }
      if (entry != null) return entry.node
    }
    return null
  }

  AstNode? findSlot(Str typeName, Str slotName)
  {
    typeNode := findType(typeName)
    if (typeNode == null) return null
    return typeNode.children.find |c| { c.name == slotName }
  }

  SymbolEntry? findByName(Str name)
  {
    vals := symbols.vals
    for (i := 0; i < vals.size; i++)
    {
      entries := vals[i]
      entry := entries.find |e| { e.name == name || e.node.name == name }
      if (entry != null) return entry
    }
    return null
  }

  SymbolEntry[] findAllByName(Str name)
  {
    result := SymbolEntry[,]
    symbols.each |entries|
    {
      entries.each |e|
      {
        if (e.name == name || e.node.name == name)
          result.add(e)
      }
    }
    return result
  }

  SymbolEntry[] search(Str query)
  {
    result := SymbolEntry[,]
    q := query.lower
    symbols.each |entries|
    {
      entries.each |e|
      {
        if (e.name.lower.contains(q))
          result.add(e)
      }
    }
    return result
  }

  DocumentSymbol[] getDocumentSymbols(Str uri)
  {
    entries := symbols[uri]
    if (entries == null) return DocumentSymbol[,]

    return entries.findAll |e| { e.node.isType }.map |e -> DocumentSymbol|
    {
      children := e.node.children.map |c -> DocumentSymbol|
      {
        DocumentSymbol(c.name, c.symbolKind, c.range, c.selectionRange,
          c.typeName ?: c.returnType)
      }
      return DocumentSymbol(e.name, e.node.symbolKind, e.node.range, e.node.selectionRange,
        null, children)
    }
  }

  SymbolEntry[] allEntries()
  {
    result := SymbolEntry[,]
    symbols.each |entries| { result.addAll(entries) }
    return result
  }
}

class SymbolEntry
{
  Str name
  Str uri
  AstNode node

  new make(Str name, Str uri, AstNode node)
  {
    this.name = name
    this.uri = uri
    this.node = node
  }
}
