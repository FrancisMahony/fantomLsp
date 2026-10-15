class ReferenceIndex
{
  private Str:Reference[] refs := [:]

  Void update(Str uri, ParseResult result)
  {
    entries := Reference[,]
    result.nodes.each |node|
    {
      if (node.isType)
      {
        node.children.each |child|
        {
          if (child.typeName != null)
            entries.add(Reference(child.typeName, uri, child.selectionRange, true))
          if (child.params != null)
          {
            child.params.each |p|
            {
              parts := p.split
              if (parts.size >= 2)
                entries.add(Reference(parts[0], uri, child.selectionRange, true))
            }
          }
        }
      }
    }
    result.bodyRefs.each |br|
    {
      entries.add(Reference(br.name, uri, br.range, false))
    }
    result.nodes.each |node|
    {
      if (!node.isType) return
      node.children.each |child|
      {
        child.bodyCallRefs.each |cr|
        {
          entries.add(Reference(cr.name, uri, cr.range, false))
        }
      }
    }
    refs[uri] = entries
  }

  Void remove(Str uri) { refs.remove(uri) }

  Reference[] findReferences(Str name)
  {
    result := Reference[,]
    refs.each |entries|
    {
      entries.each |e|
      {
        if (e.name == name) result.add(e)
      }
    }
    return result
  }

  Reference[] findReferencesInFile(Str uri, Str name)
  {
    entries := refs[uri] ?: Reference[,]
    return entries.findAll |e| { e.name == name }
  }

  Bool isTypeReferenceAt(Str uri, Str name, Position pos)
  {
    entries := refs[uri] ?: Reference[,]
    return entries.find |e| { e.isType && e.name == name && contains(e.range, pos) } != null
  }

  private static Bool contains(LspRange range, Position pos)
  {
    if (pos.line < range.start.line || pos.line > range.end.line) return false
    if (pos.line == range.start.line && pos.character < range.start.character) return false
    if (pos.line == range.end.line && pos.character > range.end.character) return false
    return true
  }
}

class Reference
{
  Str name
  Str uri
  LspRange range
  Bool isType

  new make(Str name, Str uri, LspRange range, Bool isType := false)
  {
    this.name = name
    this.uri = uri
    this.range = range
    this.isType = isType
  }
}
