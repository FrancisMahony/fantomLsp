class SemanticTokensProvider
{
  static const Str[] tokenTypes := [
    "namespace", "type", "class", "enum", "interface",
    "struct", "typeParameter", "parameter", "variable", "property",
    "enumMember", "event", "function", "method", "macro",
    "keyword", "modifier", "comment", "string", "number",
    "regexp", "operator", "decorator",
  ]

  static const Str[] tokenModifiers := [
    "declaration", "definition", "readonly", "static",
    "deprecated", "abstract", "async", "modification",
    "documentation", "defaultLibrary",
  ]

  Obj? provideTokens(DocumentState doc, SymbolTable symbolTable, TypeResolver typeResolver)
  {
    data := Int[,]
    prevLine := 0
    prevChar := 0

    entries := symbolTable.allEntries
    tokens := SemanticToken[,]

    entries.each |e|
    {
      if (e.uri != doc.uri) return
      node := e.node
      addToken(tokens, node)
      node.children.each |child| { addToken(tokens, child) }
    }

    tokens.sort |a, b| 
    {
      if (a.line != b.line) return a.line <=> b.line
      return a.char <=> b.char
    }

    tokens.each |t|
    {
      deltaLine := t.line - prevLine
      deltaChar := deltaLine == 0 ? t.char - prevChar : t.char
      data.add(deltaLine)
      data.add(deltaChar)
      data.add(t.length)
      data.add(t.type)
      data.add(t.modifiers)
      prevLine = t.line
      prevChar = t.char
    }

    return ["data": data]
  }

  private Void addToken(SemanticToken[] tokens, AstNode node)
  {
    line := node.selectionRange.start.line
    char := node.selectionRange.start.character
    length := node.name.size

    Int type
    Int modifiers := 0
    switch (node.kind)
    {
      case AstNodeKind.classDef:      type = 2
      case AstNodeKind.mixinDef:      type = 4
      case AstNodeKind.enumDef:       type = 3
      case AstNodeKind.facetClassDef: type = 22
      case AstNodeKind.methodDef:     type = 13
      case AstNodeKind.ctorDef:       type = 13
      case AstNodeKind.fieldDef:      type = 9
      case AstNodeKind.enumValDef:    type = 10
      case AstNodeKind.usingDef:      type = 0
      default:                        type = 8
    }

    if (node.modifiers.contains("static")) modifiers = modifiers.or(1.shiftl(3))
    if (node.modifiers.contains("const") || node.modifiers.contains("readonly")) modifiers = modifiers.or(1.shiftl(2))
    if (node.modifiers.contains("abstract")) modifiers = modifiers.or(1.shiftl(5))

    if (node.isType || node.isSlot || node.kind == AstNodeKind.enumValDef)
      modifiers = modifiers.or(1.shiftl(0))

    tokens.add(SemanticToken(line, char, length, type, modifiers))
  }
}

class SemanticToken
{
  Int line
  Int char
  Int length
  Int type
  Int modifiers

  new make(Int line, Int char, Int length, Int type, Int modifiers)
  {
    this.line = line
    this.char = char
    this.length = length
    this.type = type
    this.modifiers = modifiers
  }
}
