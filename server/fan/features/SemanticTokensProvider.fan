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

  Obj? provideTokens(DocumentState doc, SymbolTable symbolTable, TypeResolver typeResolver, ParseResult? parseResult := null)
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
      node.children.each |child|
      {
        addToken(tokens, child)
        child.bodyCallRefs.each |cr| { addRawToken(tokens, cr.range, 13, 0) }
      }
    }

    if (parseResult != null)
    {
      parseResult.bodyRefs.each |br|
      {
        typeIdx := br.name.size > 0 && br.name[0].isUpper ? 2 : 1
        addRawToken(tokens, br.range, typeIdx, 0)
      }
      parseResult.nodes.each |node|
      {
        node.bodyCallRefs.each |cr| { addRawToken(tokens, cr.range, 13, 0) }
        node.children.each |child|
        {
          child.bodyCallRefs.each |cr| { addRawToken(tokens, cr.range, 13, 0) }
        }
      }
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

  Obj? provideTokensRange(DocumentState doc, SymbolTable symbolTable, ParseResult? parseResult, LspRange range)
  {
    full := provideTokens(doc, symbolTable, TypeResolver(), parseResult) as [Str:Obj?]
    data := full["data"] as Int[] ?: Int[,]
    filtered := Int[,]
    prevLine := 0
    prevChar := 0
    i := 0
    absLine := 0
    absChar := 0
    startLine := range.start.line
    endLine := range.end.line
    while (i + 4 < data.size)
    {
      dLine := data[i]
      dChar := data[i+1]
      length := data[i+2]
      type := data[i+3]
      mods := data[i+4]
      i += 5
      absLine += dLine
      absChar = dLine == 0 ? absChar + dChar : dChar
      if (absLine < startLine || absLine > endLine) continue
      deltaLine := absLine - prevLine
      deltaChar := deltaLine == 0 ? absChar - prevChar : absChar
      filtered.add(deltaLine)
      filtered.add(deltaChar)
      filtered.add(length)
      filtered.add(type)
      filtered.add(mods)
      prevLine = absLine
      prevChar = absChar
    }
    return ["data": filtered]
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
      case AstNodeKind.facetClassDef: type = 2
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

  private Void addRawToken(SemanticToken[] tokens, LspRange range, Int type, Int modifiers)
  {
    line := range.start.line
    char := range.start.character
    length := (range.end.character - range.start.character).max(0)
    if (length == 0) return
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
