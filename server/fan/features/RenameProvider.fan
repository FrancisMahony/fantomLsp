class RenameProvider
{
  [Str:Obj?] prepareRename(DocumentState doc, Position pos, FantomLanguageServer server)
  {
    res := renameTarget(doc, pos, server)
    requireNoWorkspaceSubtypes(res.targets.first, server)
    range := res.occurrenceRange
    if (range == null || textAt(doc, range) != res.targets.first.name)
      throw RequestFailedErr("Cannot rename safely: the token is not the declared symbol name (constructor shorthand is not supported)")
    return ["range": range.toMap, "placeholder": res.targets.first.name]
  }

  ** requestId must be the actual JSON-RPC id, not a generated refresh id.
  ** The serialized server/dispatcher owner must forward it without conversion.
  WorkspaceEdit rename(DocumentState doc, Position pos, Str newName, FantomLanguageServer server, Obj requestId)
  {
    if (!isValidIdent(newName)) throw RequestFailedErr("Cannot rename: new name must be a Fantom identifier")
    res := renameTarget(doc, pos, server)
    target := res.targets.first
    if (res.occurrenceRange == null || textAt(doc, res.occurrenceRange) != target.name)
      throw RequestFailedErr("Cannot rename safely: constructor shorthand does not spell the slot name")
    refs := server.resolver.references(target.key, true, false)
    if (!refs.complete)
    {
      builds := uncoveredBuildKeys(server, refs.uncoveredPods)
      fresh := server.ensureFresh(builds, 10sec, requestId)
      // Recompute even on timeout/failure; never return the pre-refresh edits.
      refs = server.resolver.references(target.key, true, false)
      if (!fresh || !refs.complete) throw incomplete(refs)
      current := renameTarget(doc, pos, server)
      if (current.targets.first.key != target.key)
        throw RequestFailedErr("Cannot rename safely: symbol identity changed during semantic refresh; retry the request")
    }

    // Hierarchy absence requires fresh whole-file coverage, not just complete
    // references to this slot's spelling. Keep this after the refresh above.
    requireNoWorkspaceSubtypes(target, server)
    changes := Str:TextEdit[][:]
    seen := Str:Bool[:]
    // Do not decode local keys: buffer-local identities contain an opaque file.
    declarations := server.resolver.targetLocation(target.key, server.workspaceManager.folderFor(doc.uri))
    if (declarations.isEmpty) throw RequestFailedErr("Cannot rename safely: workspace declaration is unavailable")
    declarations.each |loc| { addEdit(server, target, changes, seen, loc.uri, loc.range, newName) }
    refs.occurrences.each |o| { addEdit(server, target, changes, seen, o.fileKey, o.range, newName) }
    return WorkspaceEdit(changes)
  }

  private static Resolution renameTarget(DocumentState doc, Position pos, FantomLanguageServer server)
  {
    res := server.resolver.resolveAt(doc.uri, pos)
    if (res.certainty != Certainty.proven || res.targets.size != 1)
      throw RequestFailedErr("Cannot rename safely: target is ${res.certainty}; a proven, unambiguous binding is required")
    t := res.targets.first
    if (t.fileKey == null || t.range == null || server.workspaceManager.folderFor(t.fileKey) == null)
      throw RequestFailedErr("Cannot rename safely: target is external or has no workspace declaration")
    if (!SymbolKey.isLocal(t.key))
    {
      pod := server.podRegistry.podForFile(t.fileKey)
      if (pod == null || pod.podName != SymbolKey.podOf(t.key))
        throw RequestFailedErr("Cannot rename safely: target is not declared in a workspace pod")
      requireIndependentSlot(t, server)
    }
    return res
  }

  ** Exact-key edits cannot maintain dispatch families. A namespace slot can
  ** prove UNSAFE, but an old build (or absent parser modifiers) cannot prove
  ** safe. Check current source headers at resolver-mapped declaration tokens,
  ** including compact declarations which the recovering parser may omit.
  private static Void requireIndependentSlot(SymbolTarget target, FantomLanguageServer server)
  {
    typeKey := SymbolKey.typeKeyOf(target.key)
    if (typeKey == null || typeKey == target.key) return // types, not slots

    try
    {
      slot := server.podLookup.findSlot(SymbolKey.podOf(target.key), SymbolKey.simpleName(typeKey), target.name)
      if (slot != null && SymbolKey.slotKey(slot.parent.qname, slot.name) == target.key &&
          (slot.isVirtual || slot.isAbstract || slot.isOverride || slot.parent.isMixin))
        throw unsupportedFamily
    }
    catch (RequestFailedErr e) { throw e }
    catch (Err e) { /* Unavailable namespace metadata is not evidence of safety. */ }

    source := renameSource(target.fileKey, server)
    header := declarationPrefix(source, target.range, target.name)
    if (header == null) throw unknownSlotSafety
    if (Regex("\\b(virtual|abstract|override)\\b").matcher(header).find)
      throw unsupportedFamily
    // Accept only a simple declaration prefix, not an initializer, facet
    // expression, function type, or other syntax we cannot establish safely.
    if (!Regex("[A-Za-z_][A-Za-z0-9_ \\t\\r\\n:?\\[\\]<>.,]*").matches(header))
      throw unknownSlotSafety

    owners := server.resolver.targetLocation(typeKey, server.workspaceManager.folderFor(target.fileKey))
    if (owners.size != 1) throw unknownSlotSafety
    owner := owners.first
    ownerSource := renameSource(owner.uri, server)
    ownerHeader := declarationPrefix(ownerSource, owner.range, SymbolKey.simpleName(typeKey))
    if (ownerHeader == null) throw unknownSlotSafety
    if (Regex("\\bmixin\\b").matcher(ownerHeader).find) throw unsupportedFamily
    // A first type may follow using directives rather than a closing brace.
    ownerHeader = ownerHeader.splitLines.findAll |line| { !line.trim.startsWith("using ") }.join("\n").trim
    if (!Regex("(?:(?:public|internal|abstract|const|final)\\s+)*(?:(?:enum|facet)\\s+)?class").matches(ownerHeader))
      throw unknownSlotSafety
  }

  private static RequestFailedErr unsupportedFamily()
  {
    RequestFailedErr("Cannot rename safely: virtual, abstract, override, and mixin slot families are not supported by exact-key rename")
  }

  ** An unflagged inherited method/field can implicitly implement a mixin in
  ** a subclass. Until family renames exist, refuse ANY workspace subtype of
  ** the declaring owner, even one unrelated to a mixin. Audit the entire
  ** workspace (including dependent pods): name-prefiltered references miss
  ** subclasses which never spell the slot name. Do not rely on a potentially
  ** stale dependency registry to exclude pods. Preparation never compiles.
  private static Void requireNoWorkspaceSubtypes(SymbolTarget target, FantomLanguageServer server)
  {
    if (SymbolKey.isLocal(target.key)) return
    owner := SymbolKey.typeKeyOf(target.key)
    if (owner == null || owner == target.key) return
    pods := server.podRegistry.allPods
    types := Str:SymbolDecl[:]
    pods.each |pod|
    {
      snap := server.semanticSnapshots[pod.buildKey]
      if (server.podRegistry.byName(pod.podName).size != 1 || snap == null ||
          !snap.resolved || !snap.parseFailedFiles.isEmpty) throw unknownHierarchy
      files := server.podRegistry.filesOf(pod)
      server.docManager.openUris.each |file|
      { if (server.podRegistry.podForFile(file)?.buildKey == pod.buildKey) files.add(file) }
      files = files.unique.sort
      if (files != snap.fileHash.keys.sort) throw unknownHierarchy
      if (pod.srcDirs.any |dir| { !dir.exists || !dir.isDir }) throw unknownHierarchy
      files.each |file|
      {
        source := renameSource(file, server)
        if (source == null || source.text.toBuf.toDigest("SHA-1").toHex != snap.fileHash[file])
          throw unknownHierarchy
      }
      snap.decls.each |d, key|
      { if (!SymbolKey.isLocal(key) && SymbolKey.typeKeyOf(key) == key) types[key] = d }
    }
    if (types[owner] == null) throw unknownHierarchy
    types.each |d|
    {
      if (d.key == owner) return
      pending := d.superTypeKeys.dup
      seen := Str:Bool[:]
      while (!pending.isEmpty)
      {
        key := pending.removeAt(-1)
        if (key == owner)
          throw RequestFailedErr("Cannot rename safely: slot owner has a workspace subtype; inherited mixin slot families are not supported by exact-key rename")
        if (seen[key] == true || key == "sys::Obj") continue
        seen[key] = true
        parent := types[key]
        if (parent != null) pending.addAll(parent.superTypeKeys)
        else
        {
          if (server.podRegistry.isWorkspacePod(SymbolKey.podOf(key) ?: ""))
            throw unknownHierarchy
          // External ancestors can bridge back to the workspace owner. Never
          // interpret missing ancestry metadata as an empty inheritance list.
          try
          {
            t := server.podLookup.findType(SymbolKey.podOf(key), SymbolKey.simpleName(key))
            if (t == null) throw unknownHierarchy
            if (t.base != null) pending.add(t.base.qname)
            t.mixins.each |m| { pending.add(m.qname) }
          }
          catch (RequestFailedErr e) { throw e }
          catch (Err e) { throw unknownHierarchy }
        }
      }
    }
  }

  private static RequestFailedErr unknownHierarchy()
  {
    RequestFailedErr("Cannot rename safely: current workspace subtype coverage is unavailable or stale; refresh semantic indexes and retry")
  }

  private static RequestFailedErr unknownSlotSafety()
  {
    RequestFailedErr("Cannot rename safely: cannot establish that the slot is independent of a virtual, abstract, override, or mixin family")
  }

  private static DocumentState? renameSource(Str file, FantomLanguageServer server)
  {
    doc := server.docManager.getDocument(file)
    if (doc != null) return doc
    try
    {
      disk := WorkspaceManager.uriToFile(file)
      if (disk != null && disk.exists) return DocumentState(file, 0, disk.readAllStr)
    }
    catch (Err e) { /* Refuse below rather than authorizing from old metadata. */ }
    return null
  }

  ** Mask comments/literals without moving token coordinates. Scan back to a
  ** structural boundary rather than a line start: modifiers can span lines,
  ** and a class and its slots can share one line.
  private static Str? declarationPrefix(DocumentState? doc, LspRange range, Str name)
  {
    if (doc == null || textAt(doc, range) != name) return null
    lines := RenameSourceMask().heuristicCodeLines(doc.text)
    if (lines[range.start.line][range.start.character..<range.end.character] != name) return null
    prefix := lines[0..<range.start.line].join("\n") + "\n" + lines[range.start.line][0..<range.start.character]
    boundary := -1
    prefix.each |ch, i| { if (ch == '{' || ch == '}' || ch == ';') boundary = i }
    return boundary+1 >= prefix.size ? "" : prefix[boundary+1..-1].trim
  }

  ** Expand pod labels to every build identity; never collapse duplicate builds.
  internal static Str[] uncoveredBuildKeys(FantomLanguageServer server, Str[] labels)
  {
    builds := Str[,]
    labels.each |label|
    {
      pods := server.podRegistry.byName(label)
      if (!pods.isEmpty) builds.addAll(pods.map |p->Str| { p.buildKey })
      else
      {
        pod := server.podRegistry.byBuildKey(label) ?: server.podRegistry.podForFile(label)
        if (pod != null) builds.add(pod.buildKey)
      }
    }
    return builds.unique.sort
  }

  private static RequestFailedErr incomplete(RefResult refs)
  {
    labels := refs.uncoveredPods.isEmpty ? "unknown workspace coverage or cancelled refresh" : refs.uncoveredPods.join(", ")
    return RequestFailedErr("Cannot rename safely: semantic index unavailable for pods $labels (they may not compile)")
  }

  private static Void addEdit(FantomLanguageServer server, SymbolTarget target,
    Str:TextEdit[] changes, Str:Bool seen, Str file, LspRange range, Str newName)
  {
    if (server.workspaceManager.folderFor(file) == null)
      throw RequestFailedErr("Cannot rename safely: occurrence is outside the workspace")
    if (SymbolKey.isLocal(target.key) && file != target.fileKey)
      throw RequestFailedErr("Cannot rename safely: local occurrence escapes its declaring file")
    doc := server.docManager.getDocument(file)
    if (doc == null)
    {
      try
      {
        disk := WorkspaceManager.uriToFile(file)
        if (disk != null && disk.exists) doc = DocumentState(file, 0, disk.readAllStr)
      }
      catch (Err e) { throw RequestFailedErr("Cannot rename safely: cannot read source $file") }
    }
    if (doc == null || textAt(doc, range) != target.name)
      throw RequestFailedErr("Cannot rename safely: occurrence does not spell '${target.name}' (stale source or constructor shorthand)")
    uri := server.clientUri(file)
    id := "${file}|${range.start.line}:${range.start.character}-${range.end.line}:${range.end.character}"
    if (seen[id] == true) return
    seen[id] = true
    if (changes[uri] == null) changes[uri] = TextEdit[,]
    changes[uri].add(TextEdit(range, newName))
  }

  internal static Str? textAt(DocumentState doc, LspRange r)
  {
    line := doc.getLine(r.start.line)
    if (line == null || r.start.line != r.end.line || r.start.character < 0 ||
        r.end.character < r.start.character || r.end.character > line.size) return null
    return line[r.start.character..<r.end.character]
  }

  private static Bool isValidIdent(Str name)
  {
    if (name.isEmpty || !(name[0].isAlpha || name[0] == '_')) return false
    return name.all |ch| { ch.isAlphaNum || ch == '_' }
  }
}

** Reuse the established coordinate-preserving comment/literal masker without
** adding a shared metadata contract or trusting recovering-parser flags.
internal class RenameSourceMask : LspUtils {}
