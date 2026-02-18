class CompletionProvider
{
  private static const Str[] fantomKeywords := [
    "abstract", "as", "assert", "break", "case", "catch", "class", "const",
    "continue", "default", "do", "else", "enum", "facet", "false", "final",
    "finally", "for", "foreach", "if", "internal", "is", "isnot", "it",
    "mixin", "native", "new", "null", "once", "override", "private",
    "protected", "public", "readonly", "return", "static", "super", "switch",
    "this", "throw", "true", "try", "using", "virtual", "void", "volatile",
    "while",
  ]

  Obj? complete(DocumentState doc, Position pos, SymbolTable symbolTable, TypeResolver typeResolver)
  {
    line := doc.getLine(pos.line) ?: ""
    prefix := pos.character <= line.size ? line[0..<pos.character] : line

    word := ""
    i := prefix.size - 1
    while (i >= 0 && (prefix[i].isAlphaNum || prefix[i] == '_'))
    {
      word = prefix[i].toChar + word
      i--
    }

    isDot := i >= 0 && prefix[i] == '.'

    items := [Str:Obj?][,]

    if (isDot)
    {
      receiver := ""
      j := i - 1
      while (j >= 0 && (prefix[j].isAlphaNum || prefix[j] == '_'))
      {
        receiver = prefix[j].toChar + receiver
        j--
      }
      if (!receiver.isEmpty)
      {
        typeNode := symbolTable.findType(receiver)
        if (typeNode != null)
        {
          typeNode.children.each |child|
          {
            if (child.name.lower.startsWith(word.lower))
              items.add(makeItem(child, typeResolver))
          }
        }
      }
    }
    else
    {
      if (!word.isEmpty)
      {
        symbolTable.allEntries.each |entry|
        {
          if (entry.node.name.lower.startsWith(word.lower))
            items.add(makeItem(entry.node, typeResolver))
        }

        fantomKeywords.each |kw|
        {
          if (kw.startsWith(word.lower))
            items.add(CompletionItem(kw, CompletionItem.keyword).toMap)
        }
      }
    }

    return ["isIncomplete": true, "items": items]
  }

  private [Str:Obj?] makeItem(AstNode node, TypeResolver typeResolver)
  {
    Int kind
    switch (node.kind)
    {
      case AstNodeKind.classDef:      kind = CompletionItem.classKind
      case AstNodeKind.mixinDef:      kind = CompletionItem.interfaceKind
      case AstNodeKind.enumDef:       kind = CompletionItem.classKind
      case AstNodeKind.methodDef:     kind = CompletionItem.method
      case AstNodeKind.ctorDef:       kind = CompletionItem.constructor
      case AstNodeKind.fieldDef:      kind = CompletionItem.field
      case AstNodeKind.enumValDef:    kind = CompletionItem.enumMember
      default:                        kind = CompletionItem.text
    }

    detail := typeResolver.formatSignature(node)
    return CompletionItem(node.name, kind, detail, node.doc).toMap
  }
}
