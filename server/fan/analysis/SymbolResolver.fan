** Dispatch-thread facade. Never mutates indexes or compiles implicitly.
** Locations carry canonical keys; providers must call server.clientUri.
class SymbolResolver : LspUtils
{
  private FantomLanguageServer server
  private HeuristicResolver heuristic := HeuristicResolver()
  private Str:ResolverDiskParse disk := [:] { ordered = true }
  // Separate namespace for declarations on changed lines. Never index a
  // snapshot with a current-coordinate local key. Entries expire with text.
  private Str:ResolverBufferLocal bufferLocals := [:] { ordered = true }

  // Request-scoped memo (see batch). Main-thread only; every entry is dropped
  // when the outermost public call returns, so no text outlives a request.
  // Inputs (disk text, snapshots, open-buffer text) are re-fetched per scope;
  // derived values are pure functions of exactly those inputs:
  //   textMemo: content -> lines/SHA-1 (keyed by the text itself)
  //   oldMemo:  file -> (snapshot identity, compiled text, mapper for current)
  private Int scopeDepth := 0
  private Str:Str? diskMemo := [:]
  private Str:ResolverText textMemo := [:]
  private Str:ResolverOld oldMemo := [:]
  private Str:Obj podMemo := [:]
  private Str:Str[] filesMemo := [:]

  new make(FantomLanguageServer server) { this.server = server }

  ** Run f as one request scope: disk reads, per-file line/hash tables and
  ** compiled-text mappers are shared by nested resolver calls and dropped
  ** when the outermost scope exits. Open-buffer text and snapshot identity
  ** are re-checked on every use, so in-scope edits are never served stale.
  Obj? batch(|->Obj?| f)
  {
    outer := scopeDepth == 0
    scopeDepth++
    try { return f() }
    finally
    {
      scopeDepth--
      if (outer) { diskMemo.clear; textMemo.clear; oldMemo.clear; podMemo.clear; filesMemo.clear }
    }
  }

  private |->Bool|? cancelCheck

  ** Run f as one request scope (see batch) whose long loops poll check
  ** between files and fallback attempts. A firing check raises
  ** ResolverCancelledErr, which the request handler converts to a result.
  Obj? cancellable(|->Bool|? check, |->Obj?| f)
  {
    prev := cancelCheck
    if (check != null) cancelCheck = check
    try { return batch(f) }
    finally { cancelCheck = prev }
  }

  ** Poll point for long workspace loops; no-op outside cancellable.
  Void checkCancelled()
  {
    if (cancelCheck != null && cancelCheck()) throw ResolverCancelledErr()
  }

  ** The heuristic's type/slot loops poll this request's cancel check (read at
  ** poll time; a no-op outside cancellable).
  private HeuristicContext context()
  {
    HeuristicContext(server.symbolTable, server.typeResolver, server.podRegistry, server.podLookup,
      |->| { checkCancelled })
  }

  private PodInfo? podOf(Str file)
  {
    if (scopeDepth == 0) return server.podRegistry.podForFile(file)
    hit := podMemo[file]
    if (hit != null) return hit as PodInfo
    pod := server.podRegistry.podForFile(file)
    podMemo[file] = pod ?: "none"
    return pod
  }

  private SemanticSnapshot? snapshot(Str file)
  {
    build := podOf(file)?.buildKey ?: file
    return server.semanticSnapshots[build]
  }

  ** Read-only declarations from this file's own workspace build snapshot.
  ** Only unchanged, token-validated name ranges survive; no parsing, heuristic
  ** binding, cross-build target lookup, or implicit compilation is performed.
  SymbolTarget[] fileDeclarations(Str docKey)
  { batch |->Obj?| { doFileDeclarations(docKey) } }

  private SymbolTarget[] doFileDeclarations(Str docKey)
  {
    file := UriKey.canonical(docKey)
    pod := podOf(file)
    out := SymbolTarget[,]
    if (pod == null) return out
    snap := snapshot(file)
    if (snap == null || snap.podName != pod.podName || !snap.resolved ||
        snap.parseFailedFiles.contains(file)) return out
    snap.decls.vals.each |d|
    {
      if (d.fileKey != file) return
      name := declName(snap, d)
      if (name == null) return
      range := mapped(snap, file, d.nameRange, name)
      if (range != null)
        out.add(SymbolTarget(d.key, name, d.kind, "semantic", file, range, d.signature, d.doc))
    }
    return out.sort |a, b->Int|
    {
      n := a.range.start.line <=> b.range.start.line
      if (n != 0) return n
      n = a.range.start.character <=> b.range.start.character
      return n != 0 ? n : (a.key <=> b.key)
    }
  }

  Resolution resolveAt(Str docKey, Position pos)
  { batch |->Obj?| { doResolveAt(docKey, pos) } }

  private Resolution doResolveAt(Str docKey, Position pos)
  {
    file := UriKey.canonical(docKey)
    doc := document(file)
    if (doc == null) return Resolution()
    snap := snapshot(file)
    // A mapped identifier range is single-line and the mapping is a line
    // bijection on unchanged lines, so only compiled entries on toOld(pos)
    // line can contain pos. Same order/first-match/dyn-break as a full scan.
    oldPos := snap != null && snap.resolved && !snap.parseFailedFiles.contains(file) ?
      toOld(snap, file, pos) : null
    if (oldPos != null)
    {
      occs := snap.occByFile[file] ?: Occurrence[,]
      for (i := firstOnLine(occs, oldPos.line); i < occs.size && occs[i].range.start.line == oldPos.line; i++)
      {
        occ := occs[i]
        range := mapped(snap, file, occ.range, occurrenceName(snap, occ))
        if (range == null || !heuristicContains(range, pos)) continue
        if (SymbolKey.isDyn(occ.key)) break
        return semanticResolution(occ.key, snap, file, range)
      }
      decl := snap.decls.vals.find |d|
      {
        if (d.fileKey != file || d.nameRange.start.line != oldPos.line) return false
        r := mapped(snap, file, d.nameRange, declName(snap, d))
        return r != null && heuristicContains(r, pos)
      }
      if (decl != null)
        return semanticResolution(decl.key, snap, file,
          mapped(snap, file, decl.nameRange, declName(snap, decl)))
    }
    fallback := heuristic.resolveAt(context, file, parsed(file, doc), doc, pos)
    // The recovering parser may omit a valid declaration (notably compact
    // constructors). For an explicit static receiver, retain fresh source
    // declarations rather than accidentally navigating to inherited Obj.make.
    token := heuristicToken(doc, pos)
    recv := token?.receiver
    if (recv != null && !token.dynamic && (recv.contains("::") || recv[0].isUpper))
    {
      targets := SymbolTarget[,]
      server.typeResolver.resolveTypes(file, recv, server.symbolTable).each |typeKey|
      {
        slotKey := SymbolKey.slotKey(typeKey, token.name)
        server.podRegistry.byName(SymbolKey.podOf(typeKey) ?: "", server.workspaceManager.folderFor(file)).each |pod|
        {
          source := server.semanticSnapshots[pod.buildKey]
          d := source?.decls?.get(slotKey)
          r := d == null ? null : mapped(source, d.fileKey, d.nameRange, token.name)
          if (r != null) targets.add(SymbolTarget(slotKey, token.name, d.kind, "heuristic", d.fileKey, r, d.signature, d.doc))
        }
      }
      if (!targets.isEmpty) return Resolution(targets, targets.size == 1 ? Certainty.unique : Certainty.ambiguous, token.range)
    }
    return normalizeLocals(fallback, doc, snap)
  }

  private Resolution normalizeLocals(Resolution res, DocumentState doc, SemanticSnapshot? snap)
  {
    SymbolTarget[] targets := res.targets.map |SymbolTarget t->SymbolTarget|
    {
      if (!SymbolKey.isLocal(t.key) || t.range == null || res.certainty != Certainty.proven) return t
      Str? key := null
      old := snap == null ? null : oldText(snap, doc.uri)
      if (old != null)
      {
        pos := mapper(doc.uri, old, doc.text).toOld(t.range.start)
        d := pos == null ? null : snap.decls[SymbolKey.localKey(doc.uri, pos)]
        r := d == null ? null : mapped(snap, doc.uri, d.nameRange, t.name)
        if (r != null && sameRange(r, t.range) && declName(snap, d) == t.name) key = d.key
      }
      if (key == null)
      {
        // SymbolKey's final position suffix remains readable, but this file
        // component is intentionally NOT a real file key. Only this facade
        // can unwrap it; downstream callers should use target.fileKey.
        key = SymbolKey.localKey(doc.uri + "#buffer:" + digest(doc.text), t.range.start)
      }
      normalized := SymbolTarget(key, t.name, t.kind, t.source, t.fileKey, t.range, t.signature, t.doc)
      if (key.contains("#buffer:"))
      {
        bufferLocals.remove(key)
        bufferLocals[key] = ResolverBufferLocal(normalized, digest(doc.text))
        if (bufferLocals.size > 200) bufferLocals.remove(bufferLocals.keys.first)
      }
      return normalized
    }
    certainty := res.certainty
    if (targets.any |t| { duplicateKey(t.key) }) certainty = Certainty.ambiguous
    return Resolution(targets, certainty, res.occurrenceRange)
  }

  private SymbolTarget? bufferLocal(Str key)
  {
    entry := bufferLocals[key]
    if (entry == null) return null
    text := currentText(entry.target.fileKey)
    if (text == null || digest(text) != entry.contentHash) { bufferLocals.remove(key); return null }
    return entry.target
  }

  private Bool duplicateKey(Str key)
  { server.podRegistry.byName(SymbolKey.podOf(key) ?: "").size > 1 }

  private Resolution semanticResolution(Str key, SemanticSnapshot snap, Str file, LspRange range)
  {
    Resolution([target(key, snap, file)], duplicateKey(key) ? Certainty.ambiguous : Certainty.proven, range)
  }

  ** Ranked list, retaining all duplicate workspace builds. Not protocol URIs.
  Location[] targetLocation(Str key, Str? preferFolderKey := null)
  { batch |->Obj?| { doTargetLocation(key, preferFolderKey) } }

  private Location[] doTargetLocation(Str key, Str? preferFolderKey)
  {
    if (key.contains("#buffer:"))
    {
      t := bufferLocal(key)
      return t == null ? Location[,] : [Location(t.fileKey, t.range)]
    }
    if (SymbolKey.isDyn(key)) return Location[,]
    if (SymbolKey.isLocal(key))
    {
      file := SymbolKey.localFile(key)
      if (file == null) return Location[,]
      snap := snapshot(file)
      d := snap?.decls?.get(key)
      if (d != null)
      {
        r := mapped(snap, file, d.nameRange, declName(snap, d))
        return r == null ? Location[,] : [Location(file, r)]
      }
      doc := document(file)
      if (doc == null) return Location[,]
      res := heuristic.resolveAt(context, file, parsed(file, doc), doc, SymbolKey.localPosition(key))
      t := res.targets.find |t| { t.key == key }
      return t?.range == null ? Location[,] : [Location(file, t.range)]
    }
    pods := server.podRegistry.byName(SymbolKey.podOf(key) ?: "", preferFolderKey)
    locations := Location[,]
    pods.each |pod|
    {
      snap := server.semanticSnapshots[pod.buildKey]
      d := snap?.decls?.get(key)
      r := d == null ? null : mapped(snap, d.fileKey, d.nameRange, declName(snap, d))
      if (r != null) locations.add(Location(d.fileKey, r))
      else sourceEntries(key, pod).each |e| { locations.add(Location(UriKey.canonical(e.uri), e.node.selectionRange)) }
    }
    if (!pods.isEmpty) return locations
    loc := ExternalSourceLocator(|Str name->File?| { server.podLookup.namespace.podFile(name) ?: Env.cur.findPodFile(name) }).locateInstalled(key)
    if (loc != null) locations.add(Location(WorkspaceManager.fileToUri((File)loc[0]), (LspRange)loc[1]))
    return locations
  }

  private SymbolEntry[] sourceEntries(Str key, PodInfo pod)
  {
    type := SymbolKey.typeKeyOf(key)
    entries := SymbolEntry[,]
    files := filesOf(pod).dup
    server.docManager.openUris.each |f|
    { if (server.podRegistry.podForFile(f)?.buildKey == pod.buildKey) files.add(f) }
    typeName := SymbolKey.simpleName(type)
    files.unique.sort.each |file|
    {
      checkCancelled
      doc := document(file)
      if (doc == null) return
      // A parsed type node named n implies the substring n (exact prefilter).
      if (!doc.text.contains(typeName)) return
      parsed(file, doc).nodes.findAll |n| { n.isType && n.name == SymbolKey.simpleName(type) }.each |n|
      {
        if (key == type) entries.add(SymbolEntry(n.name, file, n))
        else n.children.findAll |c| { c.isSlotOrEnumVal && c.name == SymbolKey.simpleName(key) }.each |c|
          { entries.add(SymbolEntry(c.name, file, c)) }
      }
    }
    return entries
  }

  Str? signatureOf(Str key) { batch |->Obj?| { metadata(key, false) } }
  Str? docOf(Str key) { batch |->Obj?| { metadata(key, true) } }

  private Str? metadata(Str key, Bool doc)
  {
    if (key.contains("#buffer:"))
    {
      t := bufferLocal(key)
      return doc ? t?.doc : t?.signature
    }
    if (SymbolKey.isDyn(key)) return null
    if (SymbolKey.isLocal(key))
    {
      file := SymbolKey.localFile(key)
      d := file == null ? null : snapshot(file)?.decls?.get(key)
      if (d != null && mapped(snapshot(file), file, d.nameRange, declName(snapshot(file), d)) != null)
        return doc ? d.doc : d.signature
      loc := targetLocation(key).first
      if (loc == null) return null
      res := resolveAt(loc.uri, loc.range.start)
      t := res.targets.find |t| { t.key == key }
      return doc ? t?.doc : t?.signature
    }
    pods := server.podRegistry.byName(SymbolKey.podOf(key) ?: "")
    for (i := 0; i < pods.size; i++)
    {
      d := server.semanticSnapshots[pods[i].buildKey]?.decls?.get(key)
      if (d != null && mapped(snapshot(d.fileKey), d.fileKey, d.nameRange, declName(snapshot(d.fileKey), d)) != null)
        return doc ? d.doc : d.signature
      e := sourceEntries(key, pods[i]).first
      if (e != null) return doc ? e.node.doc : formatLocalSig(e.node)
    }
    if (!pods.isEmpty) return null // no stale compiled copy of workspace source
    try
    {
      typeKey := SymbolKey.typeKeyOf(key)
      pod := SymbolKey.podOf(key)
      if (pod == null || typeKey == null) return null
      t := server.podLookup.findType(pod, SymbolKey.simpleName(typeKey))
      if (t == null) return null
      if (key == typeKey) return doc ? server.podLookup.typeDoc(t) : t.signature
      s := t.slot(SymbolKey.simpleName(key))
      // Require the declaring key, not an inherited alias.
      if (s == null || SymbolKey.slotKey(s.parent.qname, s.name) != key) return null
      return doc ? server.podLookup.slotDoc(s) : s.signature
    }
    catch (Err e) { return null }
  }

  ** snapshotOnly is mandatory for code lens: no parsing or heuristic binding.
  ** complete is conservative even for resolved snapshots: every lexical name
  ** token must be covered, including occurrence classes omitted by the engine.
  **
  ** onlyFile restricts the audit to that one candidate file (document
  ** highlight / linked editing). Every per-file step depends only on that
  ** file, so its occurrences equal the whole-workspace result filtered to
  ** it, except that the 500-attempt heuristic cap is no longer consumed by
  ** other files first. complete/uncovered then describe only this file.
  **
  RefResult references(Str key, Bool includeDecl := false, Bool snapshotOnly := false, Str? onlyFile := null)
  { batch |->Obj?| { doReferences(key, includeDecl, snapshotOnly, onlyFile == null ? null : UriKey.canonical(onlyFile)) } }

  private RefResult doReferences(Str key, Bool includeDecl, Bool snapshotOnly, Str? onlyFile)
  {
    if (SymbolKey.isDyn(key)) return RefResult()
    currentLocal := key.contains("#buffer:") ? bufferLocal(key) : null
    if (key.contains("#buffer:") && currentLocal == null) return RefResult()
    localFile := currentLocal?.fileKey ?: SymbolKey.localFile(key)
    if (SymbolKey.isLocal(key) && localFile == null) return RefResult()
    pods := server.podRegistry.allPods
    podName := SymbolKey.podOf(key)
    if (podName != null && server.podRegistry.isWorkspacePod(podName))
      pods = dependentPods(pods, podName)
    files := Str[,]
    if (onlyFile != null)
    {
      // Exactly the candidate set computed below, intersected with
      // [onlyFile], decided without walking any pod's source tree.
      member := localFile != null ? onlyFile == localFile : candidateFile(onlyFile, pods)
      if (member) files = [onlyFile]
    }
    else
    {
      // A local's candidate set is exactly [localFile] (assigned below), so the
      // workspace file walk is skipped; only the file list is affected.
      if (localFile == null) pods.each |p|
      {
        own := filesOf(p)
        // filesOf admits a file only when podForFile(file) is p; seed the
        // request-scoped memo with exactly that established fact.
        own.each |f| { if (!podMemo.containsKey(f)) podMemo[f] = p }
        files.addAll(own)
      }
      if (localFile == null) server.docManager.openUris.each |f|
      { if (pods.any |p| { p.buildKey == podOf(f)?.buildKey }) files.add(f) }
      if (localFile != null) files = [localFile]
    }
    out := Occurrence[,]
    uncovered := Str[,]
    // The public key has no declaring-build discriminator. Do not claim
    // merged duplicate-copy edits are safe, even with fresh snapshots.
    if (duplicateKey(key)) uncovered.add(podName)
    scopeFile := onlyFile ?: localFile
    pods.each |p|
    {
      if (scopeFile != null && server.podRegistry.podForFile(scopeFile)?.buildKey != p.buildKey) return
      snap := server.semanticSnapshots[p.buildKey]
      if (snap == null || !snap.resolved || !snap.parseFailedFiles.isEmpty) uncovered.add(p.podName)
      if (localFile == null && server.podRegistry.byName(p.podName).size > 1) uncovered.add(p.podName)
    }
    attempts := 0
    files.unique.sort.each |file|
    {
      checkCancelled
      snap := snapshot(file)
      name := SymbolKey.simpleName(key)
      if (localFile != null)
      {
        d := currentLocal == null ? snap?.decls?.get(key) : null
        if (currentLocal != null) name = currentLocal.name
        else if (d != null) name = declName(snap, d) ?: ""
        else
        {
          if (snapshotOnly) { uncovered.add(server.podRegistry.podForFile(file)?.podName ?: file); return }
          loc := targetLocation(key).first
          doc := document(file)
          name = loc == null || doc == null ? "" : (textAt(doc.text, loc.range) ?: "")
        }
      }
      text := currentText(file)
      label := podOf(file)?.podName ?: file
      if (currentLocal != null)
      {
        uncovered.add(label)
        if (snapshotOnly) return
      }
      if (text == null || name.isEmpty) { uncovered.add(label); return }
      if (snap == null || !snap.resolved || snap.parseFailedFiles.contains(file) ||
          digest(text) != snap.fileHash[file]) uncovered.add(label)
      // ReferenceIndex is a useful hint, but drops declarations/type spellings.
      // Actual lexical tokens are the conservative name prefilter/coverage audit.
      names := Str[name]
      // Named constructors use the type spelling (fromStr, not only make).
      // Missing declaration metadata defaults to the conservative audit;
      // never infer non-constructor status from a missing occurrence.
      typeKey := SymbolKey.typeKeyOf(key)
      if (typeKey != null && key != typeKey && mayBeConstructor(key))
        names.add(SymbolKey.simpleName(typeKey))
      // A token spelled n implies the substring n; skip lexing files that
      // cannot contain any candidate token (identical token set: empty).
      tokens := !names.any |n| { text.contains(n) } ? SemanticIndexToken[,] :
        SemanticTokens(text).tokens.findAll |t| { names.contains(t.text) }
      if (localFile != null && snap != null && currentLocal == null)
      {
        localDecl := snap.decls[key]
        owner := localDecl?.parentTypeKey == null ? null : snap.decls[localDecl.parentTypeKey]
        old := oldText(snap, file)
        if (owner == null || old == null) { uncovered.add(label); return }
        m := mapper(file, old, text)
        start := m.toNew(owner.fullRange.start)
        end := m.toNew(owner.fullRange.end)
        if (start == null || end == null) { uncovered.add(label); return }
        scope := LspRange(start, end)
        tokens = tokens.findAll |t| { heuristicContains(scope, t.range.start) }
      }
      if (tokens.isEmpty) return
      usable := currentLocal == null && snap != null && snap.resolved && !snap.parseFailedFiles.contains(file)
      mappedOccs := Occurrence[,]
      if (usable)
      {
        (snap.occByFile[file] ?: Occurrence[,]).each |o|
        {
          // Exact prefilter: any other occurrence's validated spelling is
          // simpleName(o.key) not in names, so it can neither cover a
          // candidate token, be a same-name dyn, nor match key/altKey.
          if (o.key != key && o.altKey != key && !SymbolKey.isDyn(o.key) &&
              !SymbolKey.isLocal(o.key) && o.kind != OccKind.ctorShorthand &&
              !names.contains(SymbolKey.simpleName(o.key))) return
          r := mapped(snap, file, o.range, occurrenceName(snap, o))
          if (r != null) mappedOccs.add(Occurrence(file, r, o.key, o.kind, o.altKey, o.enclosingSlotKey))
        }
      }
      covered := Str:Bool[:]
      mappedOccs.each |o| { covered[rangeId(o.range)] = true }
      missing := tokens.findAll |t| { !covered.containsKey(rangeId(t.range)) }
      // Unchanged occurrences alone do not establish coverage of edited lines.
      if (!usable || !missing.isEmpty) uncovered.add(label)
      if (mappedOccs.any |o| { SymbolKey.isDyn(o.key) && SymbolKey.simpleName(o.key) == name })
        uncovered.add(label)
      mappedOccs.each |o|
      { if ((o.key == key || o.altKey == key) && (includeDecl || o.kind != OccKind.decl)) out.add(o) }
      if (snapshotOnly || missing.isEmpty) return
      doc := document(file)
      if (doc == null) return
      parse := parsed(file, doc)
      missing.each |t|
      {
        if (attempts >= 500) return
        checkCancelled
        attempts++
        res := normalizeLocals(heuristic.resolveAt(context, file, parse, doc, t.range.start), doc, snap)
        if (res.certainty != Certainty.proven || !res.targets.any |v| { v.key == key }) return
        isDecl := res.targets.any |v| { v.fileKey == file && v.range != null && sameRange(v.range, t.range) }
        if (includeDecl || !isDecl) out.add(Occurrence(file, t.range, key, isDecl ? OccKind.decl : OccKind.local))
      }
    }
    seen := Str:Bool[:]
    out = out.findAll |o|
    {
      id := "${o.fileKey}#${o.range.start.line}:${o.range.start.character}:${o.range.end.character}"
      if (seen.containsKey(id)) return false
      seen[id] = true; return true
    }
    return RefResult(out, uncovered.isEmpty, uncovered.unique.sort)
  }

  ** Membership of file in the whole-workspace candidate list (filesOf of a
  ** selected pod, or an open buffer owned by one) without walking any tree:
  ** filesOf(p) admits exactly the existing non-build.fan .fan/.fwt files
  ** below one of p's existing srcDirs whose owner is p.
  private Bool candidateFile(Str file, PodInfo[] pods)
  {
    owner := podOf(file)
    if (owner == null || !pods.any |p| { p.buildKey == owner.buildKey }) return false
    if (server.docManager.getDocument(file) != null) return true
    f := WorkspaceManager.uriToFile(file)
    if (f == null || !f.exists || f.isDir || f.name == "build.fan" || (f.ext != "fan" && f.ext != "fwt")) return false
    return owner.srcDirs.any |dir|
    {
      if (!dir.exists || !dir.isDir) return false
      prefix := WorkspaceManager.fileToUri(dir)
      return file.startsWith(prefix.endsWith("/") ? prefix : prefix + "/")
    }
  }

  ** Request-scoped filesOf: one source-tree walk per build per request
  ** (definition of N candidate targets in one pod walked it N times).
  ** Callers must not mutate the returned list.
  private Str[] filesOf(PodInfo pod)
  {
    if (scopeDepth == 0) return server.podRegistry.filesOf(pod)
    hit := filesMemo[pod.buildKey]
    if (hit != null) return hit
    files := server.podRegistry.filesOf(pod)
    filesMemo[pod.buildKey] = files
    return files
  }

  ** Reverse dependency closure, sorted by build key; names form a monotone
  ** visited set so cycles and duplicate builds cannot destabilize traversal.
  private PodInfo[] dependentPods(PodInfo[] pods, Str name)
  {
    names := Str[name]
    changed := true
    while (changed)
    {
      changed = false
      pods.each |p|
      {
        if (!names.contains(p.podName) && p.dependNames.any |d| { names.contains(d) })
        { names.add(p.podName); changed = true }
      }
    }
    return pods.findAll |p| { names.contains(p.podName) }.sort |a, b| { a.buildKey <=> b.buildKey }
  }

  ** Snapshot-only metadata inspection: no parsing or heuristic re-resolution.
  ** Unknown metadata (including installed slots) warrants a type-name audit.
  private Bool mayBeConstructor(Str key)
  {
    decls := SymbolDecl[,]
    server.podRegistry.byName(SymbolKey.podOf(key) ?: "").each |pod|
    {
      d := server.semanticSnapshots[pod.buildKey]?.decls?.get(key)
      if (d != null) decls.add(d)
    }
    return decls.isEmpty || decls.any |d| { d.kind == DocumentSymbol.constructor }
  }

  private SymbolTarget target(Str key, SemanticSnapshot snap, Str requestFile)
  {
    folder := server.workspaceManager.folderFor(requestFile)
    d := snap.decls[key]
    if (d == null)
      server.podRegistry.byName(SymbolKey.podOf(key) ?: "", folder).eachWhile |p|
      { d = server.semanticSnapshots[p.buildKey]?.decls?.get(key); return d }
    loc := targetLocation(key, folder).first
    name := SymbolKey.isLocal(key) ? (d == null ? "" : (declName(snapshot(d.fileKey), d) ?: "")) : SymbolKey.simpleName(key)
    return SymbolTarget(key, name, d?.kind ?: (key == SymbolKey.typeKeyOf(key) ? DocumentSymbol.classKind : DocumentSymbol.methodKind),
      "semantic", loc?.uri, loc?.range, signatureOf(key), docOf(key))
  }

  private Str? occurrenceName(SemanticSnapshot snap, Occurrence o)
  {
    if (o.kind == OccKind.ctorShorthand)
    {
      // The indexer proved this token's spelling in the compiled text: the
      // type name, or a using alias the compiler resolved to that type. Use
      // exactly that snapshot spelling (never an arbitrary current token);
      // mapped() then requires the identical spelling at the mapped range.
      old := oldText(snap, o.fileKey)
      spelled := old == null ? null : textAt(old, o.range)
      if (spelled == null || spelled.isEmpty || !(spelled[0].isAlpha || spelled[0] == '_') ||
          !spelled.all |ch| { ch.isAlphaNum || ch == '_' }) return null
      return spelled
    }
    if (SymbolKey.isLocal(o.key))
    {
      d := snap.decls[o.key]
      return d == null ? null : declName(snap, d)
    }
    return SymbolKey.simpleName(o.key)
  }

  private Str? declName(SemanticSnapshot snap, SymbolDecl d)
  {
    if (!SymbolKey.isLocal(d.key)) return SymbolKey.simpleName(d.key)
    old := oldText(snap, d.fileKey)
    return old == null ? null : textAt(old, d.nameRange)
  }

  private Str? oldText(SemanticSnapshot snap, Str file)
  {
    old := snap.openText[file]
    if (old != null) return old
    text := readDisk(file)
    return text != null && digest(text) == snap.fileHash[file] ? text : null
  }

  private LspRange? mapped(SemanticSnapshot snap, Str file, LspRange range, Str? name)
  {
    if (!snap.resolved || snap.parseFailedFiles.contains(file) || name == null) return null
    text := currentText(file)
    if (text == null) return null
    doc := server.docManager.getDocument(file)
    LspRange? r := range
    if (doc != null)
    {
      old := oldText(snap, file)
      if (old == null) return null
      r = mapper(file, old, text).rangeToNew(range)
    }
    else if (digest(text) != snap.fileHash[file]) return null
    return r != null && textAt(text, r) == name ? r : null
  }

  ** Inverse of mapped's coordinate transform for a current position; null
  ** exactly when mapped() could not produce any range on that line.
  private Position? toOld(SemanticSnapshot snap, Str file, Position pos)
  {
    text := currentText(file)
    if (text == null) return null
    if (server.docManager.getDocument(file) == null)
      return digest(text) == snap.fileHash[file] ? pos : null
    old := oldText(snap, file)
    return old == null ? null : mapper(file, old, text).toOld(pos)
  }

  ** Lower bound in a line/character-sorted occurrence list.
  private static Int firstOnLine(Occurrence[] occs, Int line)
  {
    lo := 0; hi := occs.size
    while (lo < hi)
    {
      mid := (lo + hi) / 2
      if (occs[mid].range.start.line < line) lo = mid + 1
      else hi = mid
    }
    return lo
  }

  // Derived values are pure functions of their validated inputs: a mapper is
  // reused only for the identical (compiled, current) text pair.
  private PositionMapper mapper(Str file, Str old, Str text)
  {
    hit := oldMemo[file]
    if (hit != null && hit.old == old && hit.cur == text) return hit.mapper
    m := PositionMapper(old, text)
    if (scopeDepth > 0) oldMemo[file] = ResolverOld(old, text, m)
    return m
  }

  private ResolverText info(Str text)
  {
    hit := textMemo[text]
    if (hit != null) return hit
    t := ResolverText(text)
    if (scopeDepth > 0)
    {
      if (textMemo.size >= 256) textMemo.clear
      textMemo[text] = t
    }
    return t
  }

  private Str? textAt(Str text, LspRange r)
  {
    lines := info(text).lines
    if (r.start.line != r.end.line || r.start.line < 0 || r.start.line >= lines.size ||
      r.start.character < 0 || r.end.character < r.start.character || r.end.character > lines[r.start.line].size) return null
    return lines[r.start.line][r.start.character..<r.end.character]
  }
  private static Str rangeId(LspRange r)
  { "${r.start.line}:${r.start.character}:${r.end.line}:${r.end.character}" }
  private static Bool sameRange(LspRange a, LspRange b)
  { a.start.line == b.start.line && a.start.character == b.start.character && a.end.line == b.end.line && a.end.character == b.end.character }
  private Str digest(Str text) { info(text).sha1 }
  private Str? currentText(Str file) { server.docManager.getDocument(file)?.text ?: readDisk(file) }
  private Str? readDisk(Str file)
  {
    if (scopeDepth > 0 && diskMemo.containsKey(file)) return diskMemo[file]
    Str? text := null
    try { f := WorkspaceManager.uriToFile(file); text = f == null || !f.exists ? null : f.readAllStr }
    catch (Err e) { text = null }
    if (scopeDepth > 0)
    {
      // Bound retained text even within one workspace-wide request. Every
      // memo is a pure derivation, so dropping all of them is always safe.
      if (diskMemo.size >= 256) { diskMemo.clear; textMemo.clear; oldMemo.clear }
      diskMemo[file] = text
    }
    return text
  }
  private DocumentState? document(Str file)
  {
    doc := server.docManager.getDocument(file)
    if (doc != null) return doc
    text := readDisk(file)
    return text == null ? null : DocumentState(file, 0, text)
  }
  private ParseResult parsed(Str file, DocumentState doc)
  {
    if (server.docManager.getDocument(file) != null) return server.docManager.parseDocument(file)
    hash := digest(doc.text)
    cached := disk.remove(file)
    if (cached == null || cached.contentHash != hash)
      cached = ResolverDiskParse(hash, RecoveringParser().parse(file, doc.text))
    disk[file] = cached
    if (disk.size > 200) disk.remove(disk.keys.first)
    return cached.parse
  }
}

internal class ResolverBufferLocal
{
  SymbolTarget target
  Str contentHash
  new make(SymbolTarget target, Str contentHash) { this.target = target; this.contentHash = contentHash }
}

** The current request was cancelled by the client; never a JSON-RPC error.
const class ResolverCancelledErr : Err
{
  new make() : super("Request cancelled") {}
}

** Line table and digest of one exact text; memoized per request scope only.
internal class ResolverText
{
  new make(Str text) { this.text = text }
  Str text
  Str[] lines() { if (linesMemo == null) linesMemo = TextDocumentManager.toLines(text); return linesMemo }
  Str sha1() { if (hashMemo == null) hashMemo = text.toBuf.toDigest("SHA-1").toHex; return hashMemo }
  private Str[]? linesMemo
  private Str? hashMemo
}

internal class ResolverOld
{
  Str old
  Str cur
  PositionMapper mapper
  new make(Str old, Str cur, PositionMapper mapper) { this.old = old; this.cur = cur; this.mapper = mapper }
}

internal class ResolverDiskParse
{
  Str contentHash
  ParseResult parse
  new make(Str hash, ParseResult parse) { this.contentHash = hash; this.parse = parse }
}
