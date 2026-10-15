using compiler

class SignatureHelpProvider : LspUtils
{
  Obj? signatureHelp(DocumentState doc, ParseResult parsed, Position pos, FantomLanguageServer server)
  {
    // Lex the prefix so strings/comments and commas inside nested arguments
    // (lists, maps, closures, calls) cannot change the outer active parameter.
    lines := TextDocumentManager.toLines(doc.text)
    if (pos.line < 0 || pos.line >= lines.size) return null
    prefix := lines[0..<pos.line].join("\n")
    if (pos.line > 0) prefix += "\n"
    prefix += lines[pos.line][0..<pos.character.max(0).min(lines[pos.line].size)]
    tokens := SemanticTokens(prefix).tokens.findAll |t| { !t.inString }
    opens := Int[,]
    commas := Int[,]
    tokens.each |t, i|
    {
      if (["(", "[", "{"].contains(t.text)) { opens.add(i); commas.add(0) }
      else if ([")", "]", "}"].contains(t.text))
      {
        if (!opens.isEmpty) { opens.removeAt(-1); commas.removeAt(-1) }
      }
      else if (t.text == "," && !opens.isEmpty) commas[-1]++
    }
    frame := opens.size - 1
    while (frame >= 0 && tokens[opens[frame]].text != "(") frame--
    if (frame < 0) return null
    open := opens[frame]
    if (open == 0) return null
    name := tokens[open-1]
    if (name.text.isEmpty || !isIdentChar(name.text[0])) return null
    res := server.resolver.resolveAt(doc.uri, name.range.start)
    if (res.certainty != Certainty.proven && res.certainty != Certainty.unique) return null
    target := res.targets.first
    if (target == null || SymbolKey.isLocal(target.key)) return null
    key := target.key
    if (key == SymbolKey.typeKeyOf(key)) key = SymbolKey.slotKey(key, "make")
    label := server.resolver.signatureOf(key) ?: (key == target.key ? target.signature : null)
    if (label == null) return null
    // Prefer the exact source declaration; compact declarations may be absent
    // from the recovering parser even when the resolver has fresh metadata.
    params := Str[,]
    found := false
    locs := server.resolver.targetLocation(key, server.workspaceManager.folderFor(doc.uri))
    if (locs.isEmpty && key == target.key && target.fileKey != null && target.range != null)
      locs.add(Location(target.fileKey, target.range))
    locs.eachWhile |loc|
    {
      d := server.docManager.getDocument(loc.uri)
      p := d == null ? null : server.docManager.parseDocument(loc.uri)
      if (p == null)
      {
        f := WorkspaceManager.uriToFile(loc.uri)
        if (f != null && f.exists) p = RecoveringParser().parse(loc.uri, f.readAllStr)
      }
      n := p == null ? null : methodAt(p.nodes, loc.range.start)
      if (n == null) return null
      params = n.params ?: Str[,]
      label = formatLocalSig(n)
      found = true
      return n
    }
    if (!found && server.podRegistry.isWorkspacePod(SymbolKey.podOf(key) ?: ""))
    {
      semanticParams := signatureParameters(label, key)
      if (semanticParams != null) { params = semanticParams; found = true }
    }
    if (!found)
    {
      pod := SymbolKey.podOf(key)
      type := SymbolKey.typeKeyOf(key)
      if (pod == null || type == null) return null
      // Missing workspace syntax is not permission to show an older build.
      if (server.podRegistry.isWorkspacePod(pod)) return null
      m := server.podLookup.findSlot(pod, SymbolKey.simpleName(type), SymbolKey.simpleName(key)) as CMethod
      if (m == null || m.parent.qname + "." + m.name != key) return null
      params = m.params.map |p->Str| { "${p.type.signature} ${p.name}" }
      label = (m.isCtor ? "new " : m.returns.signature + " ") + m.name + "(" + params.join(", ") + ")"
    }
    info := SignatureInformation(label, server.resolver.docOf(key), params.map |p->ParameterInformation| { ParameterInformation(p) })
    return ["signatures": [info.toMap], "activeSignature": 0,
      "activeParameter": commas[frame].min(params.size-1).max(0)]
  }

  ** Parse only the resolver's qualified method signature, never a bare-name
  ** match. Keep labels verbatim (including defaults).
  **
  ** Grammar (compiler 'MethodDef.signature' joins 'ParamType name' with ','):
  **   params  := [param (',' param)*]
  **   param   := TYPE WS name [WS? ':=' default]
  ** A compiler type signature never contains whitespace, so TYPE is the
  ** maximal non-whitespace run at a parameter start; that is what decides the
  ** parameter boundary, never pipe or comma counting inside the type. Each
  ** TYPE must also be accepted by the 'validType' grammar, and a default must
  ** be bracket/string balanced. Anything else returns null instead of a guess.
  internal static Str[]? signatureParameters(Str label, Str key)
  {
    if (!label.startsWith(key + "(") || !label.endsWith(")")) return null
    body := label[key.size+1..<label.size-1]
    if (body.trim.isEmpty) return Str[,]
    params := Str[,]
    n := body.size
    i := 0
    while (true)
    {
      i = skipWs(body, i)
      start := i
      while (i < n && !body[i].isSpace) i++
      if (i == start || !validType(body[start..<i])) return null
      if (i >= n) return null
      i = skipWs(body, i)
      nameEnd := identEnd(body, i)
      if (nameEnd == null) return null
      i = nameEnd
      end := i
      i = skipWs(body, i)
      if (i + 1 < n && body[i] == ':' && body[i+1] == '=')
      {
        defEnd := defaultEnd(body, i + 2)
        if (defEnd == null || body[i+2..<defEnd].trim.isEmpty) return null
        end = defEnd
        i = defEnd
      }
      params.add(body[start..<end].trim)
      if (i >= n) return params
      if (body[i] != ',') return null
      i++
    }
    return null
  }

  private static Int skipWs(Str s, Int i)
  {
    while (i < s.size && s[i].isSpace) i++
    return i
  }

  ** End offset of a default expression (exclusive): the next comma outside
  ** brackets and string/char/uri literals. A bare '|' outside brackets would
  ** be a closure signature whose commas are unbracketed; refuse it (null).
  private static Int? defaultEnd(Str s, Int i)
  {
    stack := Int[,]
    while (i < s.size)
    {
      c := s[i]
      if (c == '"' || c == '\'' || c == '`')
      {
        i++
        while (i < s.size && s[i] != c) { if (s[i] == '\\') i++; i++ }
        if (i >= s.size) return null
      }
      else if (c == '(' || c == '[' || c == '{') stack.push(c)
      else if (c == ')' || c == ']' || c == '}')
      {
        open := c == ')' ? '(' : (c == ']' ? '[' : '{')
        if (stack.isEmpty || stack.last != open) return null
        stack.pop
      }
      else if (c == '|')
      {
        if (i + 1 < s.size && s[i+1] == '|') i++
        else if (stack.isEmpty) return null
      }
      else if (c == ',' && stack.isEmpty) return i
      i++
    }
    return stack.isEmpty ? i : null
  }

  ** Whitespace-free type signature grammar, accepting the compiler's
  ** canonical form plus tolerated shorthands ('||', '|->|'):
  **   type  := base ('?' | '[]')*
  **   base  := '|' [type (',' type)*] ['->' [type]] '|'
  **          | '[' type ':' type ']' | '[' ident ']' qname | qname
  **   qname := ident ('.' ident)* ['::' ident]
  ** '||' may be an empty function type or two openers, so parsing returns
  ** every possible end offset; the token is valid iff one parse covers it.
  internal static Bool validType(Str s)
  {
    return typeEnds(s, 0, Int:Int[][:]).contains(s.size)
  }

  private static Int[] typeEnds(Str s, Int i, Int:Int[] memo)
  {
    cached := memo[i]
    if (cached != null) return cached
    memo[i] = Int[,] // every base consumes a char, so no left recursion
    out := Int[,]
    baseEnds(s, i, memo).each |b|
    {
      e := b
      while (true)
      {
        if (!out.contains(e)) out.add(e)
        if (e < s.size && s[e] == '?') e++
        else if (e + 1 < s.size && s[e] == '[' && s[e+1] == ']') e += 2
        else break
      }
    }
    memo[i] = out
    return out
  }

  private static Int[] baseEnds(Str s, Int i, Int:Int[] memo)
  {
    out := Int[,]
    if (i >= s.size) return out
    if (s[i] == '|')
    {
      funcBodyEnds(s, i + 1, memo).each |e|
      {
        if (e < s.size && s[e] == '|' && !out.contains(e + 1)) out.add(e + 1)
      }
    }
    else if (s[i] == '[')
    {
      ffi := identEnd(s, i + 1)
      if (ffi != null && ffi < s.size && s[ffi] == ']')
      {
        q := qnameEnd(s, ffi + 1)
        if (q != null) out.add(q)
      }
      typeEnds(s, i + 1, memo).each |k|
      {
        if (k >= s.size || s[k] != ':') return
        typeEnds(s, k + 1, memo).each |v|
        {
          if (v < s.size && s[v] == ']' && !out.contains(v + 1)) out.add(v + 1)
        }
      }
    }
    else
    {
      q := qnameEnd(s, i)
      if (q != null) out.add(q)
    }
    return out
  }

  ** Offsets where a function type body starting at i can end (before '|').
  private static Int[] funcBodyEnds(Str s, Int i, Int:Int[] memo)
  {
    out := Int[,]
    out.add(i)
    arrowEnds(s, i, memo, out)
    pending := typeEnds(s, i, memo).dup
    seen := Int[,]
    while (!pending.isEmpty)
    {
      e := pending.pop
      if (seen.contains(e)) continue
      seen.add(e)
      if (!out.contains(e)) out.add(e)
      arrowEnds(s, e, memo, out)
      if (e < s.size && s[e] == ',') pending.addAll(typeEnds(s, e + 1, memo))
    }
    return out
  }

  private static Void arrowEnds(Str s, Int i, Int:Int[] memo, Int[] out)
  {
    if (i + 1 >= s.size || s[i] != '-' || s[i+1] != '>') return
    if (!out.contains(i + 2)) out.add(i + 2)
    typeEnds(s, i + 2, memo).each |r| { if (!out.contains(r)) out.add(r) }
  }

  private static Int? qnameEnd(Str s, Int i)
  {
    e := identEnd(s, i)
    if (e == null) return null
    while (e < s.size && s[e] == '.')
    {
      next := identEnd(s, e + 1)
      if (next == null) return null
      e = next
    }
    if (e + 1 < s.size && s[e] == ':' && s[e+1] == ':')
    {
      next := identEnd(s, e + 2)
      if (next == null) return null
      e = next
    }
    return e
  }

  private static Int? identEnd(Str s, Int i)
  {
    if (i >= s.size || !(s[i].isAlpha || s[i] == '_')) return null
    while (i < s.size && (s[i].isAlphaNum || s[i] == '_')) i++
    return i
  }

  private AstNode? methodAt(AstNode[] nodes, Position pos)
  {
    return nodes.eachWhile |n|
    {
      if ((n.kind == AstNodeKind.methodDef || n.kind == AstNodeKind.ctorDef) &&
          n.selectionRange.start.line == pos.line && n.selectionRange.start.character == pos.character) return n
      return methodAt(n.children, pos)
    }
  }
}
