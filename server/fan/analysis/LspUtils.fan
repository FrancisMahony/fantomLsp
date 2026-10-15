using compiler

**
** Shared utilities mixed into HoverProvider, CompletionProvider, and
** SignatureHelpProvider. Contains all type resolution, inference, and
** signature formatting logic so it is not duplicated across providers.
**
mixin LspUtils
{
  ** Dispatch-thread routing; standalone providers use installed runtime only.
  PodLookup podLookup() { PodLookup.current }

  ** Additive compiler-backed APIs. CType/CSlot are deliberately distinct from
  ** legacy final sys::Type/Slot; provider migration must use these together.
  CType? findCompilerType(Str[] podNames, Str name)
  {
    podLookup.findTypeInPods(podNames, name)
  }

  CType? findCompilerTypeInAnyPod(Str name) { podLookup.findTypeInAnyPod(name) }

  CSlot? findCompilerSlot(Str podName, Str typeName, Str name)
  {
    podLookup.findSlot(podName, typeName, name)
  }

  // ── Pod / using helpers ─────────────────────────────────────────────────────

  Str[] extractUsings(ParseResult parseResult)
  {
    podNames := Str["sys"]
    parseResult.nodes.each |node|
    {
      if (node.kind != AstNodeKind.usingDef) return
      name := node.name
      colonIdx := name.index("::")
      if (colonIdx != null) name = name[0..<colonIdx]
      if (!podNames.contains(name)) podNames.add(name)
    }
    return podNames
  }

  // Search declared usings first, then every loaded pod
  Type? findType(Str[] podNames, Str name)
  {
    return podNames.eachWhile |pn|
    {
      return podLookup.reflectionType(pn, name)
    }
  }

  Type? findTypeInAnyPod(Str name)
  {
    return podLookup.reflectionTypeInAnyPod(name)
  }

  // ── Local AST helpers ───────────────────────────────────────────────────────

  // Find a top-level type (class / mixin / enum) by name
  AstNode? findLocalType(ParseResult result, Str name)
  {
    result.nodes.find |node| { node.isType && node.name == name }
  }

  // Find any named node — top-level or direct slot child
  AstNode? findLocalNode(ParseResult result, Str name)
  {
    return result.nodes.eachWhile |node|
    {
      if (node.name == name) return node
      return node.children.eachWhile |child|
      {
        if (child.name == name) return child
        return null
      }
    }
  }

  ** Local/param in the method whose range contains pos (not a global slot).
  ** Last declaration at or before pos wins (inner/later shadow).
  AstNode? findEnclosingLocal(ParseResult result, Str name, Position pos)
  {
    slot := findEnclosingSlot(result, pos)
    if (slot == null) return null
    AstNode? best := null
    slot.children.each |c|
    {
      if (c.kind != AstNodeKind.localDef || c.name != name) return
      if (posBefore(pos, c.selectionRange.start)) return
      if (c.scopeEndLine != null && pos.line > c.scopeEndLine) return
      if (best == null || posBefore(best.selectionRange.start, c.selectionRange.start))
        best = c
    }
    return best
  }

  AstNode? findEnclosingSlot(ParseResult result, Position pos)
  {
    AstNode? found := null
    result.nodes.each |node| { found = findEnclosingSlotIn(node, pos) ?: found }
    return found
  }

  private AstNode? findEnclosingSlotIn(AstNode node, Position pos)
  {
    if (node.isType)
    {
      AstNode? nested := null
      node.children.each |child|
      {
        found := findEnclosingSlotIn(child, pos)
        if (found != null) nested = found
      }
      return nested
    }
    if (node.kind != AstNodeKind.methodDef && node.kind != AstNodeKind.ctorDef) return null
    if (!lineInRange(node.range, pos.line)) return null
    return node
  }

  AstNode? findEnclosingType(ParseResult result, Position pos)
  {
    AstNode? found := null
    result.nodes.each |node|
    {
      if (!node.isType) return
      if (!lineInRange(node.range, pos.line)) return
      found = node
      node.children.each |child|
      {
        if (child.isType && lineInRange(child.range, pos.line)) found = child
      }
    }
    return found
  }

  Bool lineInRange(LspRange range, Int line)
  {
    line >= range.start.line && line <= range.end.line
  }

  Bool posBefore(Position a, Position b)
  {
    if (a.line < b.line) return true
    if (a.line > b.line) return false
    return a.character < b.character
  }

  Bool rangeContains(LspRange range, Position pos)
  {
    if (pos.line < range.start.line || pos.line > range.end.line) return false
    if (pos.line == range.start.line && pos.character < range.start.character) return false
    if (pos.line == range.end.line && pos.character > range.end.character) return false
    return true
  }

  // ── Type inference ──────────────────────────────────────────────────────────

  // Infer the type of a local variable by scanning for "varName :=" assignments
  Str? inferVarType(DocumentState doc, Str varName, ParseResult parseResult, Str[] podNames)
  {
    Str? found := null
    doc.lines.each |line|
    {
      if (found != null) return
      trimmed := line.trim
      pattern := varName + " :="
      idx := trimmed.index(pattern)
      if (idx == null) return
      if (idx > 0)
      {
        prev := trimmed[idx - 1]
        if (prev.isAlphaNum || prev == '_') return
      }
      rhs := trimmed[idx + pattern.size..-1].trim
      found = extractTypeFromRhs(rhs, parseResult, podNames)
    }
    return found
  }

  // Resolve the type produced by a RHS expression:
  //   "hello"        → Str
  //   true           → Bool
  //   42             → Int
  //   3.14           → Float
  //   User(...)      → User      (constructor shorthand)
  //   User.make(...) → User      (explicit constructor)
  //   User[,]        → User      (list literal — element type, useful for it.)
  //   Etc.dict2(...) → Dict      (resolved via Method.returns)
  Str? extractTypeFromRhs(Str rhs, ParseResult parseResult, Str[] podNames)
  {
    if (rhs.isEmpty) return null
    first := rhs[0]
    if (first == '"' || first == '`') return "Str"
    if (rhs.startsWith("true") || rhs.startsWith("false")) return "Bool"
    if (first.isDigit) { return rhs.contains(".") ? "Float" : "Int" }
    if (!first.isUpper) return null

    buf := StrBuf()
    for (i := 0; i < rhs.size; i++)
    {
      ch := rhs[i]
      if (ch.isAlphaNum || ch == '_') buf.addChar(ch)
      else break
    }
    typeName := buf.toStr
    if (typeName.isEmpty) return null
    rest := rhs[typeName.size..-1].trim

    if (rest.startsWith("(") || rest.startsWith("[")) return typeName

    if (rest.startsWith("."))
    {
      afterDot := rest[1..-1].trim
      mBuf := StrBuf()
      for (i := 0; i < afterDot.size; i++)
      {
        ch := afterDot[i]
        if (ch.isAlphaNum || ch == '_') mBuf.addChar(ch)
        else break
      }
      methodName := mBuf.toStr
      if (methodName.isEmpty) return null
      if (methodName == "make") return typeName

      t := findType(podNames, typeName)
      if (t != null)
      {
        m := t.method(methodName, false)
        if (m != null)
        {
          ret := m.returns
          if (ret.name == "This") return typeName
          if (ret.name != "Void") return ret.toNonNullable.name
        }
      }
      localType := findLocalType(parseResult, typeName)
      if (localType != null)
      {
        lm := localType.children.find |c| { c.name == methodName }
        if (lm?.returnType != null) return lm.returnType
      }
    }
    return null
  }

  // ── Signature formatting ────────────────────────────────────────────────────

  Str formatTypeSig(Type t)
  {
    buf := StrBuf()
    if (t.isConst)     buf.add("const ")
    if (t.isMixin)     buf.add("mixin ")
    else if (t.isEnum) buf.add("enum class ")
    else               buf.add("class ")
    buf.add(t.name)
    if (!t.isMixin && t.base != null && t.base != Obj#)
      buf.add(" : ${t.base.name}")
    return buf.toStr
  }

  Str formatMethodSig(Method m)
  {
    buf := StrBuf()
    if (m.isStatic)       buf.add("static ")
    if (m.isAbstract)     buf.add("abstract ")
    else if (m.isVirtual) buf.add("virtual ")
    buf.add(m.returns.name).add(" ").add(m.name).add("(")
    m.params.each |p, i|
    {
      if (i > 0) buf.add(", ")
      buf.add(p.type.name).add(" ").add(p.name)
    }
    buf.add(")")
    return buf.toStr
  }

  Str formatFieldSig(Field f)
  {
    buf := StrBuf()
    if (f.isStatic) buf.add("static ")
    if (f.isConst)  buf.add("const ")
    buf.add(f.type.name).add(" ").add(f.name)
    return buf.toStr
  }

  Str formatSlotSig(Slot slot)
  {
    if (slot is Method) return formatMethodSig((Method)slot)
    if (slot is Field)  return formatFieldSig((Field)slot)
    return slot.name
  }

  Str formatLocalSig(AstNode node)
  {
    buf := StrBuf()
    mods := node.modifiers.join(" ")
    if (!mods.isEmpty) buf.add(mods).add(" ")
    switch (node.kind)
    {
      case AstNodeKind.classDef:
        buf.add("class ").add(node.name)
      case AstNodeKind.mixinDef:
        buf.add("mixin ").add(node.name)
      case AstNodeKind.enumDef:
        buf.add("enum class ").add(node.name)
      case AstNodeKind.facetClassDef:
        buf.add("facet class ").add(node.name)
      case AstNodeKind.methodDef:
        if (node.returnType != null) buf.add(node.returnType).add(" ")
        buf.add(node.name).add("(")
        node.params?.each |p, i| { if (i > 0) buf.add(", "); buf.add(p) }
        buf.add(")")
      case AstNodeKind.ctorDef:
        buf.add("new ").add(node.name).add("(")
        node.params?.each |p, i| { if (i > 0) buf.add(", "); buf.add(p) }
        buf.add(")")
      case AstNodeKind.fieldDef:
        if (node.typeName != null) buf.add(node.typeName).add(" ")
        buf.add(node.name)
      case AstNodeKind.localDef:
        if (node.typeName != null) buf.add(node.typeName).add(" ")
        buf.add(node.name)
      default:
        buf.add(node.name)
    }
    return buf.toStr
  }

  // ── Utilities ───────────────────────────────────────────────────────────────

  Bool isIdentChar(Int ch) { ch.isAlphaNum || ch == '_' }

  // Compiler-generated synthetic names (closures, field accessors, etc.) contain '$'
  Bool isSyntheticName(Str name) { name.contains("\$") }

  ** Half-open token containment, unlike legacy rangeContains.
  Bool heuristicContains(LspRange range, Position pos)
  {
    !posBefore(pos, range.start) && posBefore(pos, range.end)
  }

  ** Document-aware closure/block bounds supplement the parser's line-only
  ** scopeEndLine (notably a closure brace on the following line).
  AstNode? findHeuristicLocal(ParseResult parsed, DocumentState doc, Str name, Position pos)
  {
    slot := findEnclosingSlot(parsed, pos)
    if (slot == null) return null
    code := heuristicCodeLines(doc.text)
    AstNode? best := null
    locals := slot.children.dup
    headerEnds := Str:Position[:]
    // Catch/for declarations precede their block, and a for variable is also
    // visible in its condition/update. Give these explicit lexical bounds
    // rather than borrowing the surrounding method's brace.
    for (ln := slot.range.start.line; ln <= slot.range.end.line && ln < code.size; ln++)
    {
      header := Regex("\\b(catch|for)\\s*\\(\\s*(?:([A-Za-z_][A-Za-z0-9_:?\\[\\]]*)\\s+)?([A-Za-z_][A-Za-z0-9_]*)\\s*(?::=|\\))").matcher(code[ln])
      while (header.find)
      {
        if (header.group(1) == "catch" && header.group(2) == null) continue
        col := header.start(3)
        // Balance the whole header, including constructor/function calls in
        // the initializer. Only its subsequent body owns this variable.
        paren := code[ln].index("(", header.start)
        depth := 0
        Position? endHeader := null
        for (hl := ln; hl <= slot.range.end.line && hl < code.size; hl++)
        {
          for (hc := hl == ln ? paren : 0; hc < code[hl].size; hc++)
          {
            if (code[hl][hc] == '(') depth++
            if (code[hl][hc] == ')')
            {
              depth--
              if (depth == 0) { endHeader = Position(hl, hc); break }
            }
          }
          if (endHeader != null) break
        }
        if (endHeader == null) continue
        bl := endHeader.line
        bc := endHeader.character + 1
        while (bl < code.size)
        {
          while (bc < code[bl].size && code[bl][bc].isSpace) bc++
          if (bc < code[bl].size) break
          bl++; bc = 0
        }
        // Braced bodies have exact scope. For an unbraced loop include just
        // its balanced first statement, not the surrounding method block.
        close := endHeader
        if (bl < code.size && code[bl][bc] == '{')
          close = heuristicBraceEnd(code, Position(bl, bc), slot.range.end.line) ?: slot.range.end
        else if (header.group(1) == "for" && bl <= slot.range.end.line && bl < code.size)
          close = heuristicStatementEnd(code, Position(bl, bc), slot.range.end.line)
        r := LspRange(Position(ln, col), Position(ln, col+header.group(3).size))
        local := AstNode(AstNodeKind.localDef, header.group(3), r, r)
          { it.parent = slot; it.typeName = header.group(2) }
        locals.add(local)
        headerEnds["${ln}:${col}"] = close
      }
    }
    // The recovering parser records typed closure params only. Supplement it
    // lexically, without mutating the AST, for inferred/mixed signatures.
    for (ln := slot.range.start.line; ln <= slot.range.end.line && ln < code.size; ln++)
    {
      matcher := Regex("\\|([^|]*)\\|\\s*(?:\\{|\$)").matcher(code[ln])
      while (matcher.find)
      {
        next := ln + 1
        while (next < code.size && code[next].trim.isEmpty) next++
        // A pipe-ended function type/declaration is not necessarily a body
        // closure. Require its actual opening brace before synthesizing locals.
        if (!code[ln][matcher.start..<matcher.end].trim.endsWith("{") &&
            (next >= code.size || !code[next].trim.startsWith("{"))) continue
        signature := matcher.group(1)
        arrow := signature.index("->")
        if (arrow != null) signature = signature[0..<arrow]
        from := matcher.start(1)
        signature.split(',', false).each |param|
        {
          words := param.trim.split
          if (!words.isEmpty)
          {
            pname := words.last
            if (Regex("[A-Za-z_][A-Za-z0-9_]*").matches(pname))
            {
              col := from + (param.indexr(pname) ?: 0)
              r := LspRange(Position(ln, col), Position(ln, col+pname.size))
              if (!locals.any |l| { l.selectionRange.start.line == ln && l.selectionRange.start.character == col })
                locals.add(AstNode(AstNodeKind.localDef, pname, r, r)
                  { it.parent = slot; it.typeName = words.size > 1 ? words[0..<-1].join(" ") : null })
            }
          }
          from += param.size + 1
        }
      }
    }
    locals.each |local|
    {
      if (local.kind != AstNodeKind.localDef || local.name != name ||
          posBefore(pos, local.selectionRange.start)) return
      decl := local.selectionRange.start
      headerEnd := headerEnds["${decl.line}:${decl.character}"]
      if (headerEnd != null)
      {
        if (!posBefore(pos, headerEnd)) return
        if (best == null || posBefore(best.selectionRange.start, decl)) best = local
        return
      }
      stack := Position[,]
      for (ln := slot.range.start.line; ln <= decl.line && ln < code.size; ln++)
      {
        limit := ln == decl.line ? decl.character : code[ln].size
        for (col := 0; col < limit; col++)
        {
          if (code[ln][col] == '{') stack.add(Position(ln, col))
          if (code[ln][col] == '}' && !stack.isEmpty) stack.pop
        }
      }
      // Closure params precede their own brace, possibly on the next line.
      line := code.getSafe(decl.line) ?: ""
      pipe := line.indexr("|", decl.character)
      if (pipe != null && line[0..<decl.character].contains("|"))
      {
        open := line.index("{", local.selectionRange.end.character)
        next := decl.line + 1
        while (open == null && next < code.size && code[next].trim.isEmpty) next++
        if (open != null) stack.add(Position(decl.line, open))
        else if (next < code.size && code[next].trim.startsWith("{"))
          stack.add(Position(next, code[next].index("{")))
      }
      if (!stack.isEmpty)
      {
        open := stack.last
        depth := 0
        Position? close := null
        for (ln := open.line; ln <= slot.range.end.line && ln < code.size; ln++)
        {
          for (col := ln == open.line ? open.character : 0; col < code[ln].size; col++)
          {
            if (code[ln][col] == '{') depth++
            if (code[ln][col] == '}')
            {
              depth--
              if (depth == 0) { close = Position(ln, col); break }
            }
          }
          if (close != null) break
        }
        if (close != null && !posBefore(pos, close)) return
      }
      if (best == null || posBefore(best.selectionRange.start, decl)) best = local
    }
    return best
  }

  private Position? heuristicBraceEnd(Str[] code, Position open, Int lastLine)
  {
    depth := 0
    for (ln := open.line; ln <= lastLine && ln < code.size; ln++)
    {
      for (col := ln == open.line ? open.character : 0; col < code[ln].size; col++)
      {
        if (code[ln][col] == '{') depth++
        if (code[ln][col] == '}')
        {
          depth--
          if (depth == 0) return Position(ln, col)
        }
      }
    }
    return null
  }

  ** Fantom permits newline-terminated statements. Continue beyond the first
  ** body line only while delimiters are open; a top-level semicolon ends the
  ** body even if another statement follows on that same line. Masked lexical
  ** input keeps comments/literal delimiters out of the balance.
  private Position heuristicStatementEnd(Str[] code, Position start, Int lastLine)
  {
    parens := 0
    brackets := 0
    braces := 0
    for (ln := start.line; ln <= lastLine && ln < code.size; ln++)
    {
      for (col := ln == start.line ? start.character : 0; col < code[ln].size; col++)
      {
        c := code[ln][col]
        if (c == ';' && parens == 0 && brackets == 0 && braces == 0)
          return Position(ln, col+1)
        if (c == '}' && braces == 0) return Position(ln, col)
        if (c == '(') parens++
        else if (c == ')') parens--
        else if (c == '[') brackets++
        else if (c == ']') brackets--
        else if (c == '{') braces++
        else if (c == '}') braces--
        if (parens < 0 || brackets < 0 || braces < 0) return Position(ln, col)
      }
      if (parens == 0 && brackets == 0 && braces == 0)
        return Position(ln, code[ln].size)
    }
    // Incomplete statements stay shadowed to the enclosing method's end.
    end := lastLine.min(code.size-1)
    return Position(end, code[end].size)
  }

  ** In an implicit it-block the enclosing type is not necessarily the bare
  ** slot/field receiver. Do not invent its binding without receiver typing.
  Bool heuristicImplicitBlock(ParseResult parsed, DocumentState doc, Position pos)
  {
    slot := findEnclosingSlot(parsed, pos)
    if (slot == null) return false
    code := heuristicCodeLines(doc.text)
    stack := Bool[,]
    for (ln := slot.range.start.line; ln <= pos.line && ln < code.size; ln++)
    {
      line := code[ln]
      limit := ln == pos.line ? pos.character.min(line.size) : line.size
      for (col := 0; col < limit; col++)
      {
        if (line[col] == '{')
        {
          prefix := line[0..<col].trim
          if (prefix.isEmpty && ln > slot.range.start.line) prefix = code[ln-1].trim
          // A same-line closing branch is not part of the next control header.
          close := prefix.indexr("}")
          if (close != null) prefix = prefix[close+1..-1].trim
          control := Regex("^(?:if|else|for|while|switch|try|catch|finally)\\b.*").matches(prefix)
          implicit := !stack.isEmpty && !control && !prefix.endsWith("|") && !prefix.isEmpty
          stack.add(implicit)
        }
        else if (line[col] == '}' && !stack.isEmpty) stack.pop
      }
    }
    return stack.contains(true)
  }

  ** Same-length lexical view; braces/identifiers in literals and comments do
  ** not participate in fallback navigation or scope bounds.
  Str[] heuristicCodeLines(Str text)
  {
    lines := text.splitLines
    result := Str[,]
    block := 0
    quote := 0
    triple := false
    dsl := false
    lines.each |line|
    {
      out := StrBuf()
      i := 0
      if (!dsl && block == 0 && quote == 0 && line.trimStart.startsWith("**"))
      { result.add(Str.spaces(line.size)); return }
      while (i < line.size)
      {
        c := line[i]
        n := i+1 < line.size ? line[i+1] : 0
        if (dsl)
        {
          if (c == '|' && n == '>') { dsl = false; out.add("  "); i += 2 }
          else { out.addChar(' '); i++ }
        }
        else if (block > 0)
        {
          if (c == '/' && n == '*') { block++; out.add("  "); i += 2 }
          else if (c == '*' && n == '/') { block--; out.add("  "); i += 2 }
          else { out.addChar(' '); i++ }
        }
        else if (quote != 0)
        {
          if (c == '\\')
          { count := (line.size-i).min(2); out.add(Str.spaces(count)); i += count }
          else if (triple && c == '"' && n == '"' && i+2 < line.size && line[i+2] == '"')
          { quote = 0; triple = false; out.add("   "); i += 3 }
          else { if (!triple && c == quote) quote = 0; out.addChar(' '); i++ }
        }
        else if (c == '/' && n == '/')
        { out.add(Str.spaces(line.size-i)); i = line.size }
        else if (c == '/' && n == '*')
        { block = 1; out.add("  "); i += 2 }
        else if (c == '<' && n == '|')
        { dsl = true; out.add("  "); i += 2 }
        else if (c == '"' || c == '\'' || c == '`')
        {
          quote = c
          triple = c == '"' && n == '"' && i+2 < line.size && line[i+2] == '"'
          count := triple ? 3 : 1
          out.add(Str.spaces(count)); i += count
        }
        else { out.addChar(c); i++ }
      }
      result.add(out.toStr)
    }
    return result
  }

  ** Infer only from the selected declaration, never another method's assignment.
  Str? inferDeclaredLocal(DocumentState doc, AstNode local, ParseResult parsed)
  {
    line := doc.getLine(local.selectionRange.start.line) ?: ""
    from := local.selectionRange.end.character
    if (from > line.size) return null
    rest := line[from..-1].trim
    if (!rest.startsWith(":=")) return null
    rhs := rest[2..-1].trim
    // A for initializer ends at its first header separator, not the end of
    // the condition/update/body line. Calls are still rejected below.
    prefix := line[0..<local.selectionRange.start.character]
    if (Regex(".*\\bfor\\s*\\(.*").matches(prefix))
    {
      semicolon := rhs.index(";")
      if (semicolon == null) return null
      rhs = rhs[0..<semicolon].trim
    }
    // No legacy prefix inference: 0..<10, 5ms, trueX and 3.abs are not
    // Float/Int/Bool literals. Only complete literal/constructor expressions.
    if (rhs.endsWith(";")) rhs = rhs[0..<-1].trim
    if (rhs == "true" || rhs == "false") return "Bool"
    if (Regex("[-+]?[0-9]+(?:\\.[0-9]+)?(?:ns|ms|sec|min|hr|day)").matches(rhs)) return "Duration"
    if (Regex("[-+]?[0-9]+\\s*\\.\\.<?\\s*[-+]?[0-9]+").matches(rhs)) return "Range"
    if (Regex("[-+]?[0-9]+").matches(rhs)) return "Int"
    if (Regex("[-+]?[0-9]+\\.[0-9]+(?:[eE][-+]?[0-9]+)?[fF]?").matches(rhs)) return "Float"
    if (Regex("\"(?:[^\"\\\\]|\\\\.)*\"").matches(rhs)) return "Str"
    if (Regex("`(?:[^`\\\\]|\\\\.)*`").matches(rhs)) return "Uri"
    match := Regex("^((?:[A-Za-z_][A-Za-z0-9_]*::)?[A-Z][A-Za-z0-9_]*)\\s*(?:\\.make\\s*)?\\(").matcher(rhs)
    if (!match.find) return null
    // Matching the closing paren must consume the whole RHS, not a chained
    // call or arithmetic expression following a constructor.
    masked := heuristicCodeLines(rhs).first
    depth := 0
    for (i := match.end-1; i < masked.size; i++)
    {
      if (masked[i] == '(') depth++
      if (masked[i] == ')')
      {
        depth--
        if (depth == 0) return masked[i+1..-1].trim.isEmpty ? match.group(1) : null
      }
    }
    return null
  }

  ** Identifier and immediate deterministic receiver. No expression-chain guessing.
  HeuristicToken? heuristicToken(DocumentState doc, Position pos)
  {
    line := heuristicCodeLines(doc.text).getSafe(pos.line) ?: ""
    if (pos.character < 0 || pos.character > line.size) return null
    if (pos.character == line.size || !isIdentChar(line[pos.character]))
    {
      if (pos.character == 0 || !isIdentChar(line[pos.character-1])) return null
    }
    start := pos.character
    end := start
    while (start > 0 && isIdentChar(line[start-1])) start--
    while (end < line.size && isIdentChar(line[end])) end++
    // Qualified type identifiers are one occurrence, whichever half is selected.
    if (start >= 2 && line[start-2..<start] == "::")
    {
      start -= 2
      while (start > 0 && isIdentChar(line[start-1])) start--
    }
    if (end+2 < line.size && line[end..<end+2] == "::")
    {
      end += 2
      while (end < line.size && isIdentChar(line[end])) end++
    }
    name := line[start..<end]
    before := line[0..<start].trimEnd
    Str? receiver := null
    dynamic := before.endsWith("->")
    opSize := dynamic || before.endsWith("?.") ? 2 : (before.endsWith(".") ? 1 : 0)
    if (opSize > 0)
    {
      before = before[0..<before.size-opSize].trimEnd
      rstart := before.size
      while (rstart > 0 && (isIdentChar(before[rstart-1]) || before[rstart-1] == ':')) rstart--
      receiver = rstart == before.size ? "?" : before[rstart..-1]
      // A chain/call is unknown, not the last property mistaken for a local.
      prefix := before[0..<rstart].trimEnd
      // A separated ')' may end a control header (for (...) v.close),
      // not a receiver expression. Only adjacency implies a malformed chain.
      adjacentParen := prefix.endsWith(")") && rstart > 0 && !before[rstart-1].isSpace
      if (prefix.endsWith(".") || prefix.endsWith("->") || adjacentParen) receiver = "?"
    }
    return HeuristicToken(name, receiver, dynamic,
      LspRange(Position(pos.line, start), Position(pos.line, end)))
  }
}

const class HeuristicToken
{
  const Str name
  const Str? receiver
  const Bool dynamic
  const LspRange range
  new make(Str name, Str? receiver, Bool dynamic, LspRange range)
  { this.name = name; this.receiver = receiver; this.dynamic = dynamic; this.range = range }
}
