using compiler

** Borrowed dispatch-thread services. Resolution never updates their indexes.
class HeuristicContext
{
  SymbolTable symbols
  TypeResolver types
  PodRegistry pods
  PodLookup lookup
  ** Optional request poll; throws to abandon the resolution (the caller's
  ** cancellation error). Never invoked inside a catch-all block.
  |->|? poll

  new make(SymbolTable symbols, TypeResolver types, PodRegistry pods,
           PodLookup lookup := PodLookup.current, |->|? poll := null)
  {
    this.symbols = symbols; this.types = types; this.pods = pods; this.lookup = lookup
    this.poll = poll
  }

  Void checkCancelled() { poll?.call }
}

** Conservative fallback: only declarations and scoped locals constitute proof.
** Workspace source wins over compiled copies; inheritance uses declaring keys.
class HeuristicResolver : LspUtils
{
  // Call-scoped memo of resolveTypeKeys(file, spelling). One resolveAt runs
  // synchronously on the dispatch thread, which is the only writer of the
  // symbol table, usings and registry, so the result is a pure function of
  // its key for the duration; dropped when the outermost call returns.
  private Str:Str[] typeKeyMemo := [:]
  private Str:Obj podMemo := [:]
  private Int depth := 0

  Resolution resolveAt(HeuristicContext ctx, Str docKey, ParseResult parsed,
                       DocumentState doc, Position pos)
  {
    depth++
    try return doResolveAt(ctx, docKey, parsed, doc, pos)
    finally { if (--depth == 0) { typeKeyMemo.clear; podMemo.clear } }
  }

  private Resolution doResolveAt(HeuristicContext ctx, Str docKey, ParseResult parsed,
                       DocumentState doc, Position pos)
  {
    docKey = UriKey.canonical(docKey)
    token := heuristicToken(doc, pos)
    if (token == null) return Resolution()
    // `|A a->R|`: the arrow of a function signature precedes its return type,
    // which is a type reference, not a dynamic call on the last parameter.
    if (token.dynamic && functionReturnType(doc, token))
      token = HeuristicToken(token.name, null, false, token.range)
    name := token.name
    range := token.range
    decl := declarationAt(parsed.nodes, name, range.start)
    if (decl != null)
      return Resolution([nodeTarget(ctx, docKey, decl)], Certainty.proven, range)

    enclosing := findEnclosingType(parsed, pos)
    if (token.receiver == null)
    {
      local := findHeuristicLocal(parsed, doc, name, pos)
      if (local != null)
        return Resolution([nodeTarget(ctx, docKey, local)], Certainty.proven, range)
      if (heuristicImplicitBlock(parsed, doc, pos) && !name[0].isUpper && !name.contains("::"))
        return result(ctx, docKey, parsed, candidates(ctx, docKey, parsed, name, true), range, true)
      targets := SymbolTarget[,]
      if (enclosing != null)
        targets = slots(ctx, docKey, typeKey(ctx, docKey, enclosing.name), name, Str[,])
      if (targets.isEmpty && (name[0].isUpper || name.contains("::")))
        targets = typeTargets(ctx, docKey, name)
      return result(ctx, docKey, parsed, targets, range)
    }

    if (token.dynamic)
      return result(ctx, docKey, parsed, candidates(ctx, docKey, parsed, name, false), range, true)
    recv := token.receiver
    typeKeys := Str[,]
    if (recv == "this" && enclosing != null)
      typeKeys.add(typeKey(ctx, docKey, enclosing.name))
    else if (recv == "super" && enclosing != null)
      typeKeys = resolveTypeKeys(ctx, docKey, enclosing.baseType ?: "sys::Obj")
    else
    {
      local := findHeuristicLocal(parsed, doc, recv, pos)
      Str? spelling := null
      if (local != null)
        spelling = local.typeName ?: inferDeclaredLocal(doc, local, parsed)
      else if (enclosing != null && !recv.contains("::") && !recv[0].isUpper &&
               !heuristicImplicitBlock(parsed, doc, pos))
      {
        fields := slots(ctx, docKey, typeKey(ctx, docKey, enclosing.name), recv, Str[,])
        fields.each |field|
        {
          fieldType := declaredFieldType(ctx, field)
          if (fieldType != null)
            typeKeys.addAll(resolveTypeKeys(ctx, field.fileKey ?: docKey, fieldType))
        }
      }
      if (spelling != null) typeKeys.addAll(resolveTypeKeys(ctx, docKey, spelling))
      // A shadowing local is not a static type name, even if inference failed.
      else if (local == null && (recv.contains("::") || recv[0].isUpper))
        typeKeys.addAll(resolveTypeKeys(ctx, docKey, recv))
    }
    targets := SymbolTarget[,]
    typeKeys.unique.each |key| { targets.addAll(slots(ctx, docKey, key, name, Str[,])) }
    if (!typeKeys.isEmpty) return result(ctx, docKey, parsed, targets, range)
    return result(ctx, docKey, parsed, candidates(ctx, docKey, parsed, name, true), range, true)
  }

  ** Lexical proof that the `->` before token closes the parameter list of a
  ** function signature `|params->Ret|`: on the masked code line, only
  ** parameter/type spellings lie between a single opening bar and the arrow,
  ** and only type suffixes lie between Ret and a closing bar. A dynamic call
  ** `recv->name` never has a bar on both sides (bodies/calls contain `{`,
  ** `(`, `.` or operators, and Fantom has no single-bar operator).
  private Bool functionReturnType(DocumentState doc, HeuristicToken token)
  {
    line := heuristicCodeLines(doc.text).getSafe(token.range.start.line) ?: ""
    i := token.range.end.character
    while (i < line.size && (line[i] == '?' || line[i] == '[' || line[i] == ']' || line[i] == ' ' || line[i] == '\t')) i++
    if (i >= line.size || line[i] != '|' || (i+1 < line.size && line[i+1] == '|')) return false
    head := line[0..<token.range.start.character].trimEnd
    if (!head.endsWith("->")) return false
    j := head.size - 2
    while (j > 0 && signatureChar(head[j-1])) j--
    return j > 0 && head[j-1] == '|' && (j < 2 || head[j-2] != '|')
  }

  private static Bool signatureChar(Int c)
  {
    c.isAlphaNum || c == '_' || c == ':' || c == '?' || c == '[' || c == ']' ||
    c == ',' || c == ' ' || c == '\t'
  }

  private AstNode? declarationAt(AstNode[] nodes, Str name, Position pos)
  {
    return nodes.eachWhile |node|
    {
      if ((node.isType || node.isSlotOrEnumVal || node.kind == AstNodeKind.localDef) &&
          node.name == name && heuristicContains(node.selectionRange, pos)) return node
      return declarationAt(node.children, name, pos)
    }
  }

  ** Call-scoped registry owner lookup (same rationale as typeKeyMemo).
  private PodInfo? podOf(HeuristicContext ctx, Str file)
  {
    if (depth == 0) return ctx.pods.podForFile(file)
    hit := podMemo[file]
    if (hit != null) return hit as PodInfo
    pod := ctx.pods.podForFile(file)
    podMemo[file] = pod ?: "none"
    return pod
  }

  private Str typeKey(HeuristicContext ctx, Str file, Str name)
  {
    pod := podOf(ctx, file)
    // Unregistered scratch files deliberately do not invent a real pod name.
    return pod == null ? name : SymbolKey.typeKey(pod.podName, name)
  }

  private SymbolTarget nodeTarget(HeuristicContext ctx, Str file, AstNode node)
  {
    key := node.kind == AstNodeKind.localDef ? SymbolKey.localKey(file, node.selectionRange.start) :
      (node.isType ? typeKey(ctx, file, node.name) :
      SymbolKey.slotKey(typeKey(ctx, file, node.parent.name), node.name))
    return SymbolTarget(key, node.name, node.symbolKind, "heuristic", file,
      node.selectionRange, formatLocalSig(node), node.doc)
  }

  private Str[] resolveTypeKeys(HeuristicContext ctx, Str file, Str spelling)
  {
    spelling = spelling.trim
    if (spelling.endsWith("?")) spelling = spelling[0..<-1]
    if (spelling.endsWith("[]")) return ["sys::List"]
    if (spelling.startsWith("[") && !spelling.startsWith("[java]")) return ["sys::Map"]
    memo := file + "\u0000" + spelling
    hit := typeKeyMemo[memo]
    if (hit != null) return hit.dup
    keys := ctx.types.resolveTypes(file, spelling, ctx.symbols)
    if (depth > 0) typeKeyMemo[memo] = keys.dup
    return keys
  }

  ** Match all source declarations in the selected build, not first-by-name.
  private SymbolEntry[] sourceTypes(HeuristicContext ctx, Str file, Str key)
  {
    podName := SymbolKey.podOf(key)
    entries := ctx.symbols.findAllByName(SymbolKey.simpleName(key)).findAll |e|
    {
      return e.node.isType && (podName == null ? UriKey.canonical(e.uri) == file :
        podOf(ctx, e.uri)?.podName == podName)
    }
    own := podOf(ctx, file)
    if (own != null && own.podName == podName)
      return entries.findAll |e| { podOf(ctx, e.uri)?.buildKey == own.buildKey }
    selected := ctx.pods.byName(podName ?: "", own?.folderKey)
    if (!selected.isEmpty)
      return entries.findAll |e| { podOf(ctx, e.uri)?.buildKey == selected.first.buildKey }
    return entries
  }

  private SymbolTarget[] typeTargets(HeuristicContext ctx, Str file, Str name)
  {
    targets := SymbolTarget[,]
    resolveTypeKeys(ctx, file, name).each |key|
    {
      entries := sourceTypes(ctx, file, key)
      if (!entries.isEmpty)
        entries.each |e| { targets.add(nodeTarget(ctx, UriKey.canonical(e.uri), e.node)) }
      else if (!ctx.pods.isWorkspacePod(SymbolKey.podOf(key) ?: ""))
      {
        t := compilerType(ctx, key)
        if (t != null) targets.add(SymbolTarget(t.qname, t.name, DocumentSymbol.classKind,
          "reflection", null, null, t.signature, ctx.lookup.typeDoc(t)))
      }
    }
    return targets
  }

  private CType? compilerType(HeuristicContext ctx, Str key)
  {
    pod := SymbolKey.podOf(key)
    if (pod == null) return null
    try { return ctx.lookup.findType(pod, SymbolKey.simpleName(key)) }
    catch (Err e) { return null } // corrupt/unavailable pod is not a reflection fallback
  }

  private SymbolTarget[] slots(HeuristicContext ctx, Str file, Str key, Str name, Str[] visited)
  {
    ctx.checkCancelled
    identity := (podOf(ctx, file)?.buildKey ?: file) + "#" + key
    if (visited.contains(identity)) return SymbolTarget[,]
    visited = visited.dup.add(identity)
    entries := sourceTypes(ctx, file, key)
    targets := SymbolTarget[,]
    if (!entries.isEmpty)
    {
      entries.each |entry|
      {
        own := entry.node.children.findAll |c| { c.isSlotOrEnumVal && c.name == name }
        if (!own.isEmpty)
          own.each |node| { targets.add(nodeTarget(ctx, UriKey.canonical(entry.uri), node)) }
        else
        {
          supers := entry.node.mixins.dup
          if (entry.node.baseType != null) supers.insert(0, entry.node.baseType)
          // Fantom classes inherit Obj even without explicit heritage.
          if (supers.isEmpty && key != "sys::Obj") supers.add("sys::Obj")
          supers.each |base|
          {
            resolveTypeKeys(ctx, entry.uri, base).each |parent|
            { targets.addAll(slots(ctx, entry.uri, parent, name, visited)) }
          }
        }
      }
      return targets
    }
    if (ctx.pods.isWorkspacePod(SymbolKey.podOf(key) ?: "")) return targets
    t := compilerType(ctx, key)
    if (t == null) return targets
    try
    {
      s := ctx.lookup.findSlot(t.pod.name, t.name, name)
      if (s != null) targets.add(SymbolTarget(SymbolKey.slotKey(s.parent.qname, s.name), s.name,
        s is CMethod ? DocumentSymbol.methodKind : DocumentSymbol.fieldKind,
        "reflection", null, null, s.signature, ctx.lookup.slotDoc(s)))
    }
    catch (Err e) {} // retain other candidates on missing/corrupt dependencies
    return targets
  }

  private Str? declaredFieldType(HeuristicContext ctx, SymbolTarget target)
  {
    if (target.kind != DocumentSymbol.fieldKind) return null
    if (target.fileKey != null)
    {
      entries := sourceTypes(ctx, target.fileKey, SymbolKey.typeKeyOf(target.key))
      return entries.eachWhile |e| { e.node.children.find |c| { c.name == target.name }?.typeName }
    }
    t := compilerType(ctx, SymbolKey.typeKeyOf(target.key))
    try { return (t?.slot(target.name) as CField)?.type?.qname }
    catch (Err e) { return null }
  }

  ** Visible types first; unknown receivers may also offer other workspace pods.
  ** This enumerates types, never a global name-only slot/child first match.
  private SymbolTarget[] candidates(HeuristicContext ctx, Str file, ParseResult parsed,
                                    Str name, Bool otherWorkspace)
  {
    keys := Str[,]
    ctx.symbols.typeEntries.each |e|
    {
      ctx.checkCancelled
      key := typeKey(ctx, UriKey.canonical(e.uri), e.node.name)
      if (otherWorkspace || visibleType(ctx, file, parsed, key)) keys.add(key)
    }
    pods := usingPods(parsed)
    own := podOf(ctx, file)
    if (own != null) pods.add(own.podName)
    pods.unique.sort.each |pod|
    {
      if (ctx.pods.isWorkspacePod(pod)) return
      // Poll outside the catch-all below, which must not swallow cancellation.
      ctx.checkCancelled
      try
      {
        ctx.lookup.namespace.resolvePod(pod, null).types.each |t|
        {
          if (visibleType(ctx, file, parsed, t.qname)) keys.add(t.qname)
        }
      }
      catch (Err e) {} // one bad imported pod must not hide healthy candidates
    }
    targets := SymbolTarget[,]
    keys.unique.sort.each |key| { targets.addAll(slots(ctx, file, key, name, Str[,])) }
    return targets
  }

  private Bool visibleType(HeuristicContext ctx, Str file, ParseResult parsed, Str key)
  {
    if (resolveTypeKeys(ctx, file, SymbolKey.simpleName(key)).contains(key)) return true
    return parsed.nodes.any |n|
    {
      return n.kind == AstNodeKind.usingDef && !n.isJava && n.usingType != null &&
        SymbolKey.typeKey(n.usingPod, n.usingType) == key
    }
  }

  private Str[] usingPods(ParseResult parsed)
  {
    pods := Str["sys"]
    parsed.nodes.each |n|
    { if (n.kind == AstNodeKind.usingDef && n.usingPod != null && !n.isJava) pods.add(n.usingPod) }
    return pods.unique
  }

  private Resolution result(HeuristicContext ctx, Str file, ParseResult parsed,
                            SymbolTarget[] targets, LspRange range, Bool uncertain := false)
  {
    imports := parsed.nodes.findAll |n| { n.kind == AstNodeKind.usingDef && !n.isJava }.
      map |n->Str| { n.usingPod ?: "" }
    own := podOf(ctx, file)
    targets = targets.dup.sort |a, b -> Int|
    {
      ar := rank(ctx, file, own, imports, a)
      br := rank(ctx, file, own, imports, b)
      if (ar != br) return ar <=> br
      n := a.key <=> b.key
      if (n != 0) return n
      n = (a.fileKey ?: "") <=> (b.fileKey ?: "")
      if (n != 0) return n
      n = (a.range?.start?.line ?: -1) <=> (b.range?.start?.line ?: -1)
      return n != 0 ? n : (a.range?.start?.character ?: -1) <=> (b.range?.start?.character ?: -1)
    }
    seen := Str[,]
    targets = targets.findAll |t|
    {
      identity := t.key + "#" + (t.fileKey ?: "") +
        "#${t.range?.start?.line}:${t.range?.start?.character}"
      if (seen.contains(identity)) return false
      seen.add(identity)
      return true
    }
    if (uncertain && targets.size > 20) targets = targets[0..<20]
    certainty := targets.isEmpty ? Certainty.none : ((uncertain || targets.size > 1) ?
      Certainty.ambiguous : Certainty.unique)
    return Resolution(targets, certainty, range)
  }

  private Int rank(HeuristicContext ctx, Str file, PodInfo? own, Str[] imports, SymbolTarget t)
  {
    if (t.fileKey == file) return 0
    pod := t.fileKey == null ? null : podOf(ctx, t.fileKey)
    if (own != null && pod?.buildKey == own.buildKey) return 1
    if (imports.contains(SymbolKey.podOf(t.key))) return 2
    return pod != null ? 3 : 4
  }
}
