class SymbolTable
{
  private Str:SymbolEntry[] symbols := [:]
  private WorkspaceManager? workspaceManager

  ** Exact name index for findAllByName: lookup name -> uri -> that file's
  ** entries (file order) with e.name == name or e.node.name == name. Derived
  ** only from `symbols`, maintained by update/remove (entries are never
  ** renamed after construction), so its size is bounded by the table's.
  private Str:[Str:SymbolEntry[]] byName := [:]

  new make(WorkspaceManager? workspaceManager := null)
  {
    this.workspaceManager = workspaceManager
  }

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
          if (child.isSlotOrEnumVal)
            entries.add(SymbolEntry(child.qname, uri, child))
        }
      }
    }
    unindex(uri)
    symbols[uri] = entries
    entries.each |e|
    {
      indexName(e.name, uri, e)
      if (e.node.name != e.name) indexName(e.node.name, uri, e)
    }
  }

  Void remove(Str uri) { unindex(uri); symbols.remove(uri) }

  private Void indexName(Str name, Str uri, SymbolEntry e)
  {
    files := byName[name]
    if (files == null) byName[name] = files = Str:SymbolEntry[][:]
    list := files[uri]
    if (list == null) files[uri] = list = SymbolEntry[,]
    list.add(e)
  }

  private Void unindex(Str uri)
  {
    old := symbols[uri]
    if (old == null) return
    old.each |e|
    {
      [e.name, e.node.name].each |name|
      {
        files := byName[name]
        if (files == null) return
        files.remove(uri)
        if (files.isEmpty) byName.remove(name)
      }
    }
  }

  AstNode? findType(Str name, Str? preferredUri := null)
  {
    if (preferredUri != null)
    {
      entries := symbols[preferredUri]
      entry := entries?.find |e| { e.node.isType && e.name == name }
      if (entry != null) return entry.node
    }

    vals := symbols.vals
    folder := preferredFolder(preferredUri)
    if (folder != null)
    {
      for (i := 0; i < vals.size; i++)
      {
        entry := vals[i].find |e| { UriKey.canonical(e.uri).startsWith(folder) && e.node.isType && e.name == name }
        if (entry != null) return entry.node
      }
    }
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

  SymbolEntry? findByName(Str name, Str? preferredUri := null)
  {
    if (preferredUri != null)
    {
      entries := symbols[preferredUri]
      entry := entries?.find |e| { e.name == name || e.node.name == name }
      if (entry != null) return entry
    }

    vals := symbols.vals
    folder := preferredFolder(preferredUri)
    if (folder != null)
    {
      for (i := 0; i < vals.size; i++)
      {
        entry := vals[i].find |e| { UriKey.canonical(e.uri).startsWith(folder) && (e.name == name || e.node.name == name) }
        if (entry != null) return entry
      }
    }
    for (i := 0; i < vals.size; i++)
    {
      entries := vals[i]
      entry := entries.find |e| { e.name == name || e.node.name == name }
      if (entry != null) return entry
    }
    return null
  }

  private Str? preferredFolder(Str? uri)
  {
    if (uri == null) return null
    folder := workspaceManager?.folderFor(uri)
    if (folder == null) return null
    return folder.endsWith("/") ? folder : folder + "/"
  }

  ** Every entry with e.name == name or e.node.name == name. Same match set
  ** as a full scan; within a file entries keep file order, and files are
  ** ordered by uri (previously unspecified hash order, so deterministic now).
  SymbolEntry[] findAllByName(Str name)
  {
    result := SymbolEntry[,]
    files := byName[name]
    if (files == null) return result
    files.keys.sort.each |uri| { result.addAll(files[uri]) }
    return result
  }

  ** Type declaration entries, in table order (same set and order as
  ** search("").findAll { it.node.isType }, without lower-casing every name).
  SymbolEntry[] typeEntries()
  {
    result := SymbolEntry[,]
    symbols.each |entries| { entries.each |e| { if (e.node.isType) result.add(e) } }
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
      children := e.node.children.findAll |c| { c.isSlotOrEnumVal }.map |c -> DocumentSymbol|
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
