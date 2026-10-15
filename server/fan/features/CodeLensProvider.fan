class CodeLensProvider
{
  private SymbolResolver resolver
  private |Str->Str| clientUri
  private [Str:Obj?] options

  ** options is the current Fantom configuration (not the outer settings map).
  new make(SymbolResolver resolver, |Str->Str| clientUri, [Str:Obj?] options := [:])
  {
    this.resolver = resolver
    this.clientUri = clientUri
    this.options = options
  }

  ** One resolver request scope: per-file text/hash/mapper work is shared by
  ** the declaration scan and every parser-slot fallback lookup.
  [Str:Obj?][] lenses(ParseResult result)
  { resolver.batch |->Obj?| { doLenses(result) } }

  private [Str:Obj?][] doLenses(ParseResult result)
  {
    output := [Str:Obj?][,]
    lensOptions := options["codeLens"] as [Str:Obj?]
    if (lensOptions?.get("enabled") == false) return output
    // Compiler declarations cover layouts the recovering parser omits, and
    // the facade maps them to current buffer coordinates before returning.
    resolver.fileDeclarations(result.uri).each |target|
    { if (slotKind(target.kind)) addLens(result.uri, target, output) }
    result.nodes.each |node| { addDeclarations(result.uri, node, output) }
    return output
  }

  [Str:Obj?] resolve([Str:Obj?] lens)
  { resolver.batch |->Obj?| { doResolve(lens) } }

  private [Str:Obj?] doResolve([Str:Obj?] lens)
  {
    data := lens["data"] as [Str:Obj?]
    key := data?.get("key") as Str
    uri := data?.get("uri") as Str
    if (key == null || uri == null) return lens
    // Retain the declaring file in duplicate-pod workspaces.
    decl := resolver.targetLocation(key).find |loc| { UriKey.canonical(loc.uri) == UriKey.canonical(uri) }
    if (decl == null) return lens
    refs := resolver.references(key, false, true)
    count := refs.occurrences.size
    suffix := refs.complete ? "" : "+"
    command := Str:Obj?["title": "0$suffix references", "command": ""]
    if (count > 0)
    {
      locations := refs.occurrences.map |o-> [Str:Obj?]| { Location(clientUri(o.fileKey), o.range).toMap }
      command = ["title": "$count$suffix references", "command": "fantom.showReferences",
                  "arguments": [clientUri(decl.uri), decl.range.start.toMap, locations]]
    }
    resolved := lens.dup
    resolved["command"] = command
    return resolved
  }

  private Void addDeclarations(Str uri, AstNode node, [Str:Obj?][] output)
  {
    if (node.isType)
    {
      node.children.each |child|
      {
        if (child.isSlot)
        {
          // Prefer a mapped semantic declaration at this position. Do not
          // re-resolve it through the parser or emit a second lens for it.
          if (output.any |lens|
          { (lens["range"] as [Str:Obj?])?.get("start") == child.selectionRange.start.toMap }) return
          resolution := resolver.resolveAt(uri, child.selectionRange.start)
          target := resolution.targets.find |t|
          {
            t.fileKey != null && UriKey.canonical(t.fileKey) == UriKey.canonical(uri) &&
            t.range != null && t.range.start.line == child.selectionRange.start.line &&
            t.range.start.character == child.selectionRange.start.character &&
            slotKind(t.kind)
          }
          if (target == null || SymbolKey.podOf(target.key) == null) return
          addLens(uri, target, output)
        }
      }
    }
    node.children.each |child| { addDeclarations(uri, child, output) }
  }

  private static Bool slotKind(Int kind)
  {
    kind == DocumentSymbol.methodKind || kind == DocumentSymbol.constructor ||
    kind == DocumentSymbol.fieldKind
  }

  private Void addLens(Str uri, SymbolTarget target, [Str:Obj?][] output)
  {
    if (target.range == null || SymbolKey.podOf(target.key) == null ||
        output.any |lens| { (lens["data"] as [Str:Obj?])?.get("key") == target.key }) return
    output.add(["range": target.range.toMap,
                "data": ["uri": clientUri(uri), "key": target.key]])
  }
}
