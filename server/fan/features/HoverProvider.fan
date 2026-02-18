class HoverProvider
{
  [Str:Obj?]? hover(DocumentState doc, Position pos, SymbolTable symbolTable, TypeResolver typeResolver)
  {
    word := doc.getWordAt(pos)
    if (word.isEmpty) return null

    entry := symbolTable.findByName(word)
    if (entry != null)
    {
      sig := typeResolver.formatSignature(entry.node)
      md := StrBuf()
      md.add("```fantom\n").add(sig).add("\n```")
      if (entry.node.doc != null) md.add("\n\n---\n\n").add(entry.node.doc)

      return [
        "contents": ["kind": "markdown", "value": md.toStr],
      ]
    }

    allEntries := symbolTable.allEntries
    allEntries.each |e|
    {
      e.node.children.each |child|
      {
        if (child.name == word)
        {
          sig := typeResolver.formatSignature(child)
          md := StrBuf()
          md.add("```fantom\n").add(sig).add("\n```")
          if (child.doc != null) md.add("\n\n---\n\n").add(child.doc)
          return [
            "contents": ["kind": "markdown", "value": md.toStr],
          ]
        }
      }
    }

    return null
  }
}
