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
            entries.add(Reference(child.typeName, uri, child.selectionRange))
          if (child.params != null)
          {
            child.params.each |p|
            {
              parts := p.split
              if (parts.size >= 2)
                entries.add(Reference(parts[0], uri, child.selectionRange))
            }
          }
        }
      }
    }
    result.bodyRefs.each |br|
    {
      entries.add(Reference(br.name, uri, br.range))
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
}

class Reference
{
  Str name
  Str uri
  LspRange range

  new make(Str name, Str uri, LspRange range)
  {
    this.name = name
    this.uri = uri
    this.range = range
  }
}
