class CallHierarchyProvider
{
  Obj? prepare(DocumentState doc, Position pos, FantomLanguageServer server)
  { server.resolver.batch |->Obj?| { doPrepare(doc, pos, server) } }

  private Obj? doPrepare(DocumentState doc, Position pos, FantomLanguageServer server)
  {
    ctx := HierarchyContext(server)
    items := [Str:Obj?][,]
    server.resolver.resolveAt(doc.uri, pos).targets.each |t|
    {
      if (!ctx.callable(t.kind)) return
      item := ctx.item(t.key, t)
      if (item != null) items.add(item)
    }
    return items.isEmpty ? null : items
  }

  Obj? incomingCalls([Str:Obj?] item, FantomLanguageServer server)
  { calls(item, server, true) }

  Obj? outgoingCalls([Str:Obj?] item, FantomLanguageServer server)
  { calls(item, server, false) }

  private Obj? calls([Str:Obj?] item, FantomLanguageServer server, Bool incoming)
  {
    key := (item["data"] as [Str:Obj?])?.get("key") as Str
    if (key == null) return [,]
    return server.resolver.batch |->Obj?| { doCalls(key, server, incoming) }
  }

  private Obj? doCalls(Str key, FantomLanguageServer server, Bool incoming)
  {
    ctx := HierarchyContext(server)
    groups := Str:Occurrence[][:] { ordered = true }
    ctx.callsFor(key, incoming).each |o|
    {
      if (incoming ? o.key != key : o.enclosingSlotKey != key) return
      other := incoming ? o.enclosingSlotKey : o.key
      if (other == null) return
      if (!groups.containsKey(other)) groups[other] = Occurrence[,]
      groups[other].add(o)
    }
    result := [Str:Obj?][,]
    groups.each |occs, other|
    {
      target := ctx.item(other)
      if (target == null) return
      // Fields may own initializer calls, but may not be outgoing callees.
      if (!incoming && !ctx.callable(target["kind"] as Int ?: 0)) return
      result.add([(incoming ? "from" : "to"): target,
        "fromRanges": occs.map |o| { o.range.toMap }])
    }
    return result
  }
}

** Borrowed dispatch-thread state shared by the hierarchy providers only.
** No index updates, compiler work, or bare-name binding happens here.
internal class HierarchyContext
{
  FantomLanguageServer server
  new make(FantomLanguageServer server) { this.server = server }

  ** §7.12.12 per-request cap on heuristic re-resolution of parser calls.
  static const Int fallbackCap := 500

  ** Heuristic re-resolutions performed by this request (<= fallbackCap).
  Int attempts

  // Request-scoped (one context per request): pod per file and the first
  // entry per key, both pure functions of registry/table state that cannot
  // change during a synchronous dispatch-thread request.
  private Str:Str? podNames := [:]
  private [Str:SymbolEntry?]? entryIndex

  Bool callable(Int kind)
  { kind == DocumentSymbol.methodKind || kind == DocumentSymbol.constructor }

  Bool typeKind(Int kind)
  { kind == DocumentSymbol.classKind || kind == DocumentSymbol.interfaceKind || kind == DocumentSymbol.enumKind }

  Str entryKey(SymbolEntry e)
  {
    if (!podNames.containsKey(e.uri))
      podNames[e.uri] = server.podRegistry.podForFile(e.uri)?.podName
    pod := podNames[e.uri]
    return pod == null ? e.node.qname : "$pod::${e.node.qname}"
  }

  ** First entry in allEntries order with this key (same as a linear find).
  ** entryKey is qname or "pod::qname", so the qname test is an exact
  ** prefilter that avoids pod lookups for unrelated entries.
  SymbolEntry? entry(Str key)
  {
    if (entryIndex == null) entryIndex = Str:SymbolEntry?[:]
    if (entryIndex.containsKey(key)) return entryIndex[key]
    e := server.symbolTable.allEntries.find |e| { keyMay(e, key) && entryKey(e) == key }
    entryIndex[key] = e
    return e
  }

  private static Bool keyMay(SymbolEntry e, Str key)
  {
    q := e.node.qname
    return key == q || (key.size >= q.size + 2 && key.endsWith(q) &&
      key[key.size - q.size - 2..<key.size - q.size] == "::")
  }

  SymbolDecl? declaration(Str key)
  {
    server.semanticSnapshots.vals.eachWhile |snap|
    {
      d := snap.decls[key]
      if (!snap.resolved || d == null || snap.parseFailedFiles.contains(d.fileKey)) return null
      m := mapperFor(d.fileKey)
      if (m == null || m.rangeToNew(d.nameRange) == null) return null
      return d
    }
  }

  [Str:Obj?]? item(Str key, SymbolTarget? target := null)
  {
    if (SymbolKey.isDyn(key) || SymbolKey.isLocal(key)) return null
    d := declaration(key)
    e := entry(key)
    loc := server.resolver.targetLocation(key).first
    file := loc?.uri ?: (target?.fileKey ?: e?.uri)
    selection := loc?.range ?: (target?.range ?: e?.node?.selectionRange)
    if (file == null || selection == null) return null
    full := e?.node?.range ?: selection
    if (d != null)
    {
      // Full ranges span lines; map endpoints separately, not as an identifier.
      mapper := mapperFor(d.fileKey)
      if (mapper != null)
      {
        start := mapper.toNew(d.fullRange.start)
        end := mapper.toNew(d.fullRange.end)
        if (start != null && end != null) full = LspRange(start, end)
      }
    }
    return ["name": target?.name ?: SymbolKey.simpleName(key),
      "kind": d?.kind ?: (e?.node?.symbolKind ?: (target?.kind ?:
        (SymbolKey.typeKeyOf(key) == key ? DocumentSymbol.classKind : DocumentSymbol.methodKind))),
      "uri": server.clientUri(file), "range": full.toMap,
      "selectionRange": selection.toMap, "data": ["key": key]]
  }

  private Str? text(Str file)
  {
    doc := server.docManager.getDocument(file)
    if (doc != null) return doc.text
    return diskText(file)
  }

  private Str? diskText(Str file)
  {
    try { return WorkspaceManager.uriToFile(file)?.readAllStr }
    catch (Err e) { return null }
  }

  private SemanticSnapshot? snapshot(Str file)
  { server.semanticSnapshots[server.podRegistry.podForFile(file)?.buildKey ?: file] }

  private Str? oldText(Str file)
  {
    snap := snapshot(file)
    old := snap?.openText?.get(file)
    if (old != null) return old
    disk := diskText(file)
    return disk != null && disk.toBuf.toDigest("SHA-1").toHex == snap?.fileHash?.get(file) ? disk : null
  }

  ** Calls relevant to one hierarchy edge set: incoming calls OF key, or
  ** outgoing calls FROM key. Equivalent to filtering the full workspace call
  ** list by (incoming ? o.key == key : o.enclosingSlotKey == key), except the
  ** parser fallback is name-prefiltered and capped at fallbackCap
  ** re-resolutions per request (§7.12.12); beyond the cap results are partial.
  Occurrence[] callsFor(Str key, Bool incoming)
  {
    result := Occurrence[,]
    server.semanticSnapshots.vals.each |snap|
    {
      if (!snap.resolved) return
      snap.occByFile.each |occs, file|
      {
        server.resolver.checkCancelled
        if (snap.parseFailedFiles.contains(file)) return
        relevant := occs.findAll |o|
        {
          (o.kind == OccKind.call || o.kind == OccKind.ctorShorthand) &&
          !SymbolKey.isDyn(o.key) && o.enclosingSlotKey != null &&
          (incoming ? o.key == key : o.enclosingSlotKey == key)
        }
        if (relevant.isEmpty) return
        m := mapperFor(file)
        if (m == null) return
        relevant.each |o|
        {
          r := m.rangeToNew(o.range)
          if (r != null) result.add(Occurrence(file, r, o.key, o.kind, o.altKey, o.enclosingSlotKey))
        }
      }
    }
    // Recover only parser call tokens not already covered by semantic data.
    // Resolve each token in its actual receiver/scope; ambiguity is not a call.
    name := SymbolKey.simpleName(key)
    // Constructor shorthand spells the type name or a using alias of it, so a
    // possible constructor admits every type-like spelling (conservative).
    ctorLike := incoming && mayBeConstructor(key)
    server.symbolTable.allEntries.each |e|
    {
      if (!callable(e.node.symbolKind)) return
      if (!incoming && !(keyMay(e, key) && entryKey(e) == key)) return
      file := UriKey.canonical(e.uri)
      e.node.bodyCallRefs.each |cr|
      {
        if (incoming && cr.name != name && !(ctorLike && cr.name[0].isUpper)) return
        if (coveredAt(file, cr.range.start)) return
        if (attempts >= fallbackCap) return
        server.resolver.checkCancelled
        attempts++
        res := server.resolver.resolveAt(file, cr.range.start)
        if (res.certainty != Certainty.proven && res.certainty != Certainty.unique) return
        t := res.targets.first
        if (t == null || !callable(t.kind) || SymbolKey.isDyn(t.key)) return
        result.add(Occurrence(file, cr.range, t.key, OccKind.call, null, entryKey(e)))
      }
    }
    return result
  }

  ** Missing declaration metadata never proves non-constructor status.
  private Bool mayBeConstructor(Str key)
  {
    typeKey := SymbolKey.typeKeyOf(key)
    if (typeKey == null || typeKey == key) return false
    decls := SymbolDecl[,]
    server.semanticSnapshots.each |snap| { d := snap.decls[key]; if (d != null) decls.add(d) }
    if (decls.isEmpty)
    {
      e := entry(key)
      return e == null || e.node.symbolKind == DocumentSymbol.constructor
    }
    return decls.any |d| { d.kind == DocumentSymbol.constructor }
  }

  // Per-request memo; the dispatch thread cannot observe edits mid-request.
  private Str:Obj mappers := [:]
  private Str:[Str:Bool] coverage := [:]

  private PositionMapper? mapperFor(Str file)
  {
    hit := mappers[file]
    if (hit != null) return hit as PositionMapper
    old := oldText(file)
    current := old == null ? null : text(file)
    PositionMapper? m := current == null ? null : PositionMapper(old, current)
    mappers[file] = m ?: "none"
    return m
  }

  ** Current positions of mapped semantic occurrences (any kind) in file,
  ** across every resolved snapshot that indexes it.
  private Bool coveredAt(Str file, Position pos)
  {
    set := coverage[file]
    if (set == null)
    {
      set = Str:Bool[:]
      server.semanticSnapshots.vals.each |snap|
      {
        occs := snap.occByFile[file]
        if (!snap.resolved || occs == null || snap.parseFailedFiles.contains(file)) return
        m := mapperFor(file)
        if (m == null) return
        occs.each |o|
        {
          r := m.rangeToNew(o.range)
          if (r != null) set["${r.start.line}:${r.start.character}"] = true
        }
      }
      coverage[file] = set
    }
    return set.containsKey("${pos.line}:${pos.character}")
  }

  Str[] supers(Str key)
  {
    d := declaration(key)
    if (d != null) return d.superTypeKeys
    e := entry(key)
    if (e == null || !e.node.isType) return Str[,]
    names := e.node.mixins.dup
    if (e.node.baseType != null) names.insert(0, e.node.baseType)
    keys := Str[,]
    names.each |name|
    {
      resolved := server.typeResolver.resolveTypes(e.uri, name, server.symbolTable)
      if (resolved.size == 1) keys.add(resolved.first)
    }
    return keys.unique
  }
}
