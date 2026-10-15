class TypeResolver
{
  PodRegistry? podRegistry
  private Str:AstNode[] usingMap := [:]

  Void updateUsings(Str uri, ParseResult result)
  {
    usingMap[UriKey.canonical(uri)] = result.nodes.findAll |n| { n.kind == AstNodeKind.usingDef }
  }

  Str? resolveType(Str uri, Str name, SymbolTable symbolTable)
  {
    candidates := resolveTypes(uri, name, symbolTable)
    return candidates.size == 1 ? candidates.first : null
  }

  ** Visibility tiers from 7.4. Never pick the first equally visible import.
  Str[] resolveTypes(Str uri, Str name, SymbolTable symbolTable)
  {
    uri = UriKey.canonical(uri)
    if (name.contains("::")) return [name]
    own := podRegistry?.podForFile(uri)
    entries := symbolTable.findAllByName(name).findAll |e| { e.node.isType }
    if (own != null)
    {
      if (entries.any |e| { podRegistry.podForFile(e.uri)?.buildKey == own.buildKey })
        return ["${own.podName}::${name}"]
    }
    else if (entries.any |e| { UriKey.canonical(e.uri) == uri }) return [name]

    usings := usingMap[uri] ?: AstNode[,]
    explicit := Str[,]
    usings.each |node|
    {
      if (node.usingType != null && (node.usingAlias ?: node.usingType) == name)
        explicit.add((node.isJava ? "[java]" : "") + "${node.usingPod}::${node.usingType}")
    }
    if (!explicit.isEmpty) return explicit.unique.sort

    imported := Str[,]
    usings.each |node|
    {
      if (node.usingType != null || node.isJava || node.usingPod == null) return
      pod := node.usingPod
      workspaceType := entries.any |e| { podRegistry?.podForFile(e.uri)?.podName == pod }
      installedType := podRegistry?.isWorkspacePod(pod) == true ? false :
        Pod.find(pod, false)?.type(name, false) != null
      if (workspaceType || installedType)
        imported.add("${pod}::${name}")
    }
    if (!imported.isEmpty) return imported.unique.sort
    return isSysType(name) ? ["sys::${name}"] : Str[,]
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
