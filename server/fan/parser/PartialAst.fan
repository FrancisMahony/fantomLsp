class ParseResult
{
  AstNode[] nodes := [,]
  ParseError[] errors := [,]
  Str uri

  new make(Str uri) { this.uri = uri }

  static ParseResult empty() { ParseResult("") }
}

class ParseError
{
  LspRange range
  Str message

  new make(LspRange range, Str message)
  {
    this.range = range
    this.message = message
  }
}

enum class AstNodeKind
{
  usingDef,
  classDef,
  mixinDef,
  enumDef,
  facetClassDef,
  fieldDef,
  methodDef,
  ctorDef,
  enumValDef,
  block,
  localDef,
  expr,
  comment,
  unknown
}

class AstNode
{
  AstNodeKind kind
  Str name
  LspRange range
  LspRange selectionRange
  Str? typeName
  Str[] modifiers := [,]
  AstNode[] children := [,]
  AstNode? parent { get { &parent } set { &parent = it } }
  Str? doc
  Str? returnType
  Str[]? params

  new make(AstNodeKind kind, Str name, LspRange range, LspRange selectionRange)
  {
    this.kind = kind
    this.name = name
    this.range = range
    this.selectionRange = selectionRange
  }

  Bool isType()
  {
    kind === AstNodeKind.classDef || kind === AstNodeKind.mixinDef ||
    kind === AstNodeKind.enumDef || kind === AstNodeKind.facetClassDef
  }

  Bool isSlot()
  {
    kind === AstNodeKind.fieldDef || kind === AstNodeKind.methodDef || kind === AstNodeKind.ctorDef
  }

  Str qname()
  {
    if (parent != null && parent.isType)
      return "${parent.name}.${name}"
    return name
  }

  Int symbolKind()
  {
    switch (kind)
    {
      case AstNodeKind.classDef:      return DocumentSymbol.classKind
      case AstNodeKind.mixinDef:      return DocumentSymbol.interfaceKind
      case AstNodeKind.enumDef:       return DocumentSymbol.enumKind
      case AstNodeKind.facetClassDef: return DocumentSymbol.classKind
      case AstNodeKind.fieldDef:      return DocumentSymbol.fieldKind
      case AstNodeKind.methodDef:     return DocumentSymbol.methodKind
      case AstNodeKind.ctorDef:       return DocumentSymbol.constructor
      case AstNodeKind.enumValDef:    return DocumentSymbol.enumMember
      default:                        return DocumentSymbol.variable
    }
  }
}
