class TypeResolver
{
  private Str:Str usingMap := [:]

  Void updateUsings(Str uri, ParseResult result)
  {
    result.nodes.each |node|
    {
      if (node.kind == AstNodeKind.usingDef)
      {
        parts := node.name.split('.')
        shortName := parts.last
        usingMap["${uri}::${shortName}"] = node.name
      }
    }
  }

  Str? resolveType(Str uri, Str name, SymbolTable symbolTable)
  {
    localType := symbolTable.findType(name)
    if (localType != null) return name

    fullName := usingMap["${uri}::${name}"]
    if (fullName != null) return fullName

    if (isSysType(name)) return "sys::${name}"

    return null
  }

  Str? resolveSlotType(Str uri, Str word, SymbolTable symbolTable)
  {
    if (word.contains("."))
    {
      parts := word.split('.')
      if (parts.size == 2)
      {
        typeName := parts[0]
        slotName := parts[1]
        slot := symbolTable.findSlot(typeName, slotName)
        if (slot != null) return slot.typeName ?: slot.returnType
      }
    }
    return null
  }

  Str formatSignature(AstNode node)
  {
    buf := StrBuf()
    if (!node.modifiers.isEmpty) buf.add(node.modifiers.join(" ")).add(" ")

    switch (node.kind)
    {
      case AstNodeKind.methodDef:
        if (node.returnType != null) buf.add(node.returnType).add(" ")
        buf.add(node.name).add("(")
        if (node.params != null) buf.add(node.params.join(", "))
        buf.add(")")
      case AstNodeKind.ctorDef:
        buf.add("new ").add(node.name).add("(")
        if (node.params != null) buf.add(node.params.join(", "))
        buf.add(")")
      case AstNodeKind.fieldDef:
        if (node.typeName != null) buf.add(node.typeName).add(" ")
        buf.add(node.name)
      case AstNodeKind.classDef:
        buf.add("class ").add(node.name)
      case AstNodeKind.mixinDef:
        buf.add("mixin ").add(node.name)
      case AstNodeKind.enumDef:
        buf.add("enum class ").add(node.name)
      default:
        buf.add(node.name)
    }
    return buf.toStr
  }

  private static Bool isSysType(Str name)
  {
    sysTypes := ["Obj", "Bool", "Int", "Float", "Decimal", "Str", "Duration",
      "Uri", "Type", "Range", "List", "Map", "Buf", "InStream", "OutStream",
      "File", "Err", "Void", "This", "Num", "Enum", "Facet", "Pod", "Slot",
      "Field", "Method", "Func", "Future", "DateTime", "Date", "Time",
      "TimeZone", "Locale", "Log", "Regex", "Version", "Depend", "Charset"]
    return sysTypes.contains(name)
  }
}
