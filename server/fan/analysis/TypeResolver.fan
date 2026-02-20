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

  private static const Str[] sysTypeNames :=
    Pod.find("sys").types.map |t -> Str| { t.name }.toImmutable

  private static Bool isSysType(Str name) { sysTypeNames.contains(name) }
}
