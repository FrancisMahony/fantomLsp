using compiler

class DefinitionProvider : LspUtils
{
  Obj? definition(DocumentState doc, Position pos, FantomLanguageServer server)
  {
    res := server.resolver.resolveAt(doc.uri, pos)
    return result(locations(res, doc.uri, server), res.certainty, server)
  }

  Obj? declaration(DocumentState doc, Position pos, FantomLanguageServer server)
  { definition(doc, pos, server) }

  Obj? typeDefinition(DocumentState doc, Position pos, FantomLanguageServer server)
  {
    res := server.resolver.resolveAt(doc.uri, pos)
    locs := Location[,]
    res.targets.each |t|
    {
      typed := Location[,]
      declaredTypes(t, server).each |key|
      { typed.addAll(server.resolver.targetLocation(key, server.workspaceManager.folderFor(doc.uri))) }
      if (typed.isEmpty) typed = targetLocations(t, doc.uri, server)
      locs.addAll(typed)
    }
    return result(locs, res.certainty, server)
  }

  Obj? implementation(DocumentState doc, Position pos, FantomLanguageServer server)
  {
    res := server.resolver.resolveAt(doc.uri, pos)
    locs := Location[,]
    // One request-scoped heritage index. Previously every candidate rescanned
    // the whole symbol table and recomputed podForFile per entry: O(types x
    // entries) registry lookups, ~110s for 300 generated classes (A7).
    index := HeritageIndex(server)
    res.targets.each |target|
    {
      base := SymbolKey.typeKeyOf(target.key)
      if (base == null || SymbolKey.isLocal(target.key)) return
      isType := base == target.key
      // Enumerate declarations, then bind heritage in each declaring file's
      // scope. Matching a base type's spelling is never sufficient.
      index.ordered.each |e|
      {
        own := index.keyOf(e)
        if (own == base || !index.inherits(own, base)) return
        if (isType) locs.add(Location(e.uri, e.node.selectionRange))
        else
        {
          slot := e.node.children.find |n| { n.isSlotOrEnumVal && n.name == target.name }
          if (slot != null) locs.add(Location(e.uri, slot.selectionRange))
        }
      }
    }
    if (locs.isEmpty) return result(locations(res, doc.uri, server), res.certainty, server)
    return protocolLocations(locs, server)
  }

  private Str[] declaredTypes(SymbolTarget t, FantomLanguageServer s)
  {
    if (t.key == SymbolKey.typeKeyOf(t.key)) return [t.key]
    file := t.fileKey
    if (file != null && t.range != null)
    {
      doc := s.docManager.getDocument(file)
      parsed := doc == null ? null : s.docManager.parseDocument(file)
      if (parsed == null)
      {
        f := WorkspaceManager.uriToFile(file)
        if (f != null && f.exists) parsed = RecoveringParser().parse(file, f.readAllStr)
      }
      node := parsed == null ? null : nodeAt(parsed.nodes, t.range.start)
      spelling := node?.typeName ?: node?.returnType
      if (spelling != null)
        return s.typeResolver.resolveTypes(file, rawType(spelling), s.symbolTable)
    }
    // File-backed CTypes keep rebuilt libraries current; no JVM Pod.find.
    pod := SymbolKey.podOf(t.key)
    type := SymbolKey.typeKeyOf(t.key)
    if (pod != null && type != null && !s.podRegistry.isWorkspacePod(pod))
    {
      slot := s.podLookup.findSlot(pod, SymbolKey.simpleName(type), t.name)
      if (slot is CMethod) return [((CMethod)slot).returns.qname]
      if (slot is CField) return [((CField)slot).type.qname]
    }
    // Semantic locals store a CType signature, without the local name.
    if (SymbolKey.isLocal(t.key))
    {
      sig := s.resolver.signatureOf(t.key) ?: t.signature
      if (sig != null)
      {
        if (sig.endsWith(" " + t.name)) sig = sig[0..<sig.size-t.name.size-1]
        return s.typeResolver.resolveTypes(file ?: "", rawType(sig), s.symbolTable)
      }
    }
    return Str[,]
  }

  private Str rawType(Str name)
  {
    name = name.trim
    if (name.endsWith("?")) name = name[0..<-1]
    if (name.endsWith("[]")) return "sys::List"
    if (name.startsWith("[")) return "sys::Map"
    return name
  }

  private AstNode? nodeAt(AstNode[] nodes, Position pos)
  {
    return nodes.eachWhile |n|
    {
      if (n.selectionRange.start.line == pos.line && n.selectionRange.start.character == pos.character) return n
      return nodeAt(n.children, pos)
    }
  }

  private Location[] targetLocations(SymbolTarget t, Str file, FantomLanguageServer s)
  {
    locs := s.resolver.targetLocation(t.key, s.workspaceManager.folderFor(file))
    // Scratch declarations and buffer-local identities carry authoritative
    // file coordinates on the target. Never decode the opaque local key.
    if (locs.isEmpty && t.fileKey != null && t.range != null)
      locs.add(Location(t.fileKey, t.range))
    return locs
  }

  private Location[] locations(Resolution res, Str file, FantomLanguageServer s)
  {
    out := Location[,]
    res.targets.each |t| { out.addAll(targetLocations(t, file, s)) }
    return out
  }

  private Obj? result(Location[] locs, Certainty certainty, FantomLanguageServer s)
  {
    out := protocolLocations(locs, s)
    if (out.isEmpty) return null
    if (out.size == 1 && (certainty == Certainty.proven || certainty == Certainty.unique)) return out.first
    return out
  }

  private Obj[] protocolLocations(Location[] locs, FantomLanguageServer s)
  {
    seen := Str[,]
    out := Obj[,]
    locs.each |l|
    {
      id := "${l.uri}:${l.range.start.line}:${l.range.start.character}:${l.range.end.line}:${l.range.end.character}"
      if (seen.contains(id)) return
      seen.add(id)
      out.add(Location(s.clientUri(l.uri), l.range).toMap)
    }
    return out
  }
}

** Request-scoped heritage graph for implementation. Snapshot of the main-thread
** symbol table: each type entry's pod is computed once, entries are grouped by
** resolved type key, and each key's direct supertypes are bound once in the
** declaring files' scopes. Reachability is exact: a duplicate key unions the
** heritage of all its declarations, as the per-call scan did.
internal class HeritageIndex
{
  new make(FantomLanguageServer s)
  {
    this.s = s
    ordered = s.symbolTable.allEntries.findAll |e| { e.node.isType }.sort |a, b| { a.uri <=> b.uri }
    ordered.each |e|
    {
      k := keyOf(e)
      group := byKey[k]
      if (group == null) byKey[k] = group = SymbolEntry[,]
      group.add(e)
    }
  }

  ** Type declarations in deterministic uri order (same order as before).
  SymbolEntry[] ordered { private set }

  Str keyOf(SymbolEntry e)
  {
    if (!podByUri.containsKey(e.uri)) podByUri[e.uri] = s.podRegistry.podForFile(e.uri)?.podName
    pod := podByUri[e.uri]
    return pod == null ? e.node.name : SymbolKey.typeKey(pod, e.node.name)
  }

  ** True when base is a proper (transitive) supertype of key.
  Bool inherits(Str key, Str base)
  {
    memo := key + "\u0000" + base
    cached := reach[memo]
    if (cached != null) return cached
    found := search(key, base, Str:Bool[:])
    reach[memo] = found
    return found
  }

  private Bool search(Str key, Str base, Str:Bool seen)
  {
    if (seen.containsKey(key)) return false
    seen[key] = true
    return supers(key).any |k| { k == base || search(k, base, seen) }
  }

  private Str[] supers(Str key)
  {
    cached := supersByKey[key]
    if (cached != null) return cached
    out := Str[,]
    entries := byKey[key]
    if (entries != null)
    {
      entries.each |e|
      {
        names := e.node.mixins.dup
        if (e.node.baseType != null) names.add(e.node.baseType)
        names.each |name| { out.addAll(s.typeResolver.resolveTypes(e.uri, name, s.symbolTable)) }
      }
    }
    else
    {
      // File-backed CTypes only (PodLookup); never Pod.find for workspace pods.
      pod := SymbolKey.podOf(key)
      t := pod == null ? null : s.podLookup.findType(pod, SymbolKey.simpleName(key))
      if (t?.base != null) out.add(t.base.qname)
      t?.mixins?.each |m| { out.add(m.qname) }
    }
    supersByKey[key] = out
    return out
  }

  private FantomLanguageServer s
  private Str:SymbolEntry[] byKey := [:]
  private Str:Str? podByUri := [:]
  private Str:Str[] supersByKey := [:]
  private Str:Bool reach := [:]
}
