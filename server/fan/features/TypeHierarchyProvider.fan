class TypeHierarchyProvider
{
  Obj? prepare(DocumentState doc, Position pos, FantomLanguageServer server)
  {
    ctx := HierarchyContext(server)
    result := [Str:Obj?][,]
    server.resolver.resolveAt(doc.uri, pos).targets.each |t|
    {
      if (!ctx.typeKind(t.kind) || SymbolKey.typeKeyOf(t.key) != t.key) return
      item := ctx.item(t.key, t)
      if (item != null) result.add(item)
    }
    return result.isEmpty ? null : result
  }

  Obj? supertypes([Str:Obj?] item, FantomLanguageServer server)
  {
    key := (item["data"] as [Str:Obj?])?.get("key") as Str
    if (key == null) return [,]
    ctx := HierarchyContext(server)
    return items(ctx, ctx.supers(key))
  }

  Obj? subtypes([Str:Obj?] item, FantomLanguageServer server)
  {
    key := (item["data"] as [Str:Obj?])?.get("key") as Str
    if (key == null) return [,]
    ctx := HierarchyContext(server)
    keys := Str[,]
    server.semanticSnapshots.vals.each |snap|
    {
      if (!snap.resolved) return
      snap.decls.vals.each |d|
      { if (ctx.typeKind(d.kind) && ctx.supers(d.key).contains(key)) keys.add(d.key) }
    }
    server.symbolTable.allEntries.each |e|
    {
      if (!e.node.isType) return
      candidate := ctx.entryKey(e)
      if (ctx.supers(candidate).contains(key)) keys.add(candidate)
    }
    return items(ctx, keys)
  }

  private [Str:Obj?][] items(HierarchyContext ctx, Str[] keys)
  {
    result := [Str:Obj?][,]
    keys.unique.sort.each |key|
    {
      item := ctx.item(key)
      if (item != null && ctx.typeKind(item["kind"] as Int ?: 0)) result.add(item)
    }
    return result
  }
}
