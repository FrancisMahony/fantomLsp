class RecoveringParser
{
  private Str[] lines := [,]
  // Same offsets as lines, with literals and comments replaced by spaces.
  private Str[] codeLines := [,]
  private Int curLine := 0
  private ParseResult result := ParseResult("")
  private static const Str[] modifierKeywords := ["public", "protected", "private", "internal",
    "static", "virtual", "override", "abstract", "final", "const", "native", "once", "readonly"]
  private static const Str[] typeKeywords := ["class", "mixin", "enum", "facet"]

  new make() {}

  ParseResult parse(Str uri, Str text)
  {
    this.result = ParseResult(uri)
    this.lines = text.splitLines
    this.codeLines = maskNonCode
    this.curLine = 0

    while (curLine < lines.size)
    {
      try
      {
        parseLine
      }
      catch (Err e)
      {
        addError(curLine, 0, "Parse error: $e.msg")
        curLine++
      }
    }

    validateBraceBalance
    return result
  }

  private Str[] maskNonCode()
  {
    masked := Str[,]
    inTripleStr := false
    inBlockComment := false
    lines.each |line|
    {
      buf := StrBuf()
      quote := 0
      i := 0
      while (i < line.size)
      {
        ch := line[i]
        if (inBlockComment)
        {
          if (ch == '*' && i + 1 < line.size && line[i+1] == '/')
          {
            inBlockComment = false
            buf.add("  ")
            i += 2
          }
          else
          {
            buf.addChar(' ')
            i++
          }
          continue
        }
        if (inTripleStr)
        {
          if (ch == '\\' && i + 1 < line.size)
          {
            buf.add("  ")
            i += 2
          }
          else if (ch == '"' && i + 2 < line.size && line[i+1] == '"' && line[i+2] == '"')
          {
            inTripleStr = false
            buf.add("   ")
            i += 3
          }
          else
          {
            buf.addChar(' ')
            i++
          }
          continue
        }
        if (quote != 0)
        {
          buf.addChar(' ')
          if (ch == '\\' && i + 1 < line.size)
          {
            buf.addChar(' ')
            i += 2
          }
          else
          {
            if (ch == quote) quote = 0
            i++
          }
          continue
        }
        if (ch == '/' && i + 1 < line.size && line[i+1] == '/')
        {
          while (i < line.size) { buf.addChar(' '); i++ }
          break
        }
        if (ch == '/' && i + 1 < line.size && line[i+1] == '*')
        {
          inBlockComment = true
          buf.add("  ")
          i += 2
          continue
        }
        if (ch == '"' && i + 2 < line.size && line[i+1] == '"' && line[i+2] == '"')
        {
          inTripleStr = true
          buf.add("   ")
          i += 3
          continue
        }
        if (ch == '"' || ch == '\'')
        {
          quote = ch
          buf.addChar(' ')
          i++
          continue
        }
        buf.addChar(ch)
        i++
      }
      masked.add(buf.toStr)
    }
    return masked
  }

  private Void validateBraceBalance()
  {
    openBraces := Int[,]
    openParens := Int[,]
    openBrackets := Int[,]
    codeLines.each |line, lineNum|
    {
      line.each |ch, i|
      {
        if (ch == '{')
          openBraces.push(lineNum)
        else if (ch == '}')
        {
          if (openBraces.isEmpty)
            addError(lineNum, i, "Unexpected closing brace '}'")
          else
            openBraces.pop
        }
        else if (ch == '(')
          openParens.push(lineNum)
        else if (ch == ')')
        {
          if (openParens.isEmpty)
            addError(lineNum, i, "Unexpected closing parenthesis ')'")
          else
            openParens.pop
        }
        else if (ch == '[')
          openBrackets.push(lineNum)
        else if (ch == ']')
        {
          if (openBrackets.isEmpty)
            addError(lineNum, i, "Unexpected closing bracket ']'")
          else
            openBrackets.pop
        }
      }
    }

    openBraces.each |lineNum|
    {
      addError(lineNum, 0, "Unclosed brace '{'")
    }
    openParens.each |lineNum|
    {
      addError(lineNum, 0, "Unclosed parenthesis '('")
    }
    openBrackets.each |lineNum|
    {
      addError(lineNum, 0, "Unclosed bracket '['")
    }
  }

  private Void parseLine()
  {
    line := curLine < lines.size ? codeLines[curLine].trim : ""

    if (line.isEmpty || line.startsWith("//"))
    {
      curLine++
      return
    }

    if (line.startsWith("using "))
    {
      parseUsing
      return
    }

    if (line.startsWith("**"))
    {
      curLine++
      return
    }

    if (line.startsWith("/*"))
    {
      skipBlockComment
      return
    }

    if (line.startsWith("@"))
    {
      skipFacet
      return
    }

    mods := Str[,]
    rest := line
    while (true)
    {
      found := false
      modifierKeywords.each |m|
      {
        if (rest.startsWith(m) && rest.size > m.size && !rest[m.size].isAlphaNum)
        {
          mods.add(m)
          rest = rest[m.size..-1].trim
          found = true
        }
      }
      if (!found) break
    }

    node := tryParseTypeDef(mods, rest)
    if (node != null) result.nodes.add(node)
    else curLine++
  }

  private AstNode? tryParseTypeDef(Str[] mods, Str rest)
  {
    if (rest.startsWith("class ") || rest.startsWith("class\t"))
    {
      return parseTypeDef(AstNodeKind.classDef, mods, rest["class ".size..-1].trim)
    }
    if (rest.startsWith("mixin ") || rest.startsWith("mixin\t"))
    {
      return parseTypeDef(AstNodeKind.mixinDef, mods, rest["mixin ".size..-1].trim)
    }
    if (rest.startsWith("enum ") || rest.startsWith("enum\t"))
    {
      rest2 := rest["enum ".size..-1].trim
      if (rest2.startsWith("class ") || rest2.startsWith("class\t"))
      {
        return parseTypeDef(AstNodeKind.enumDef, mods, rest2["class ".size..-1].trim)
      }
    }
    if (rest.startsWith("facet ") || rest.startsWith("facet\t"))
    {
      rest2 := rest["facet ".size..-1].trim
      if (rest2.startsWith("class ") || rest2.startsWith("class\t"))
      {
        return parseTypeDef(AstNodeKind.facetClassDef, mods, rest2["class ".size..-1].trim)
      }
    }

    return null
  }

  private Void parseUsing()
  {
    line := lines[curLine].trim
    name := line["using ".size..-1].trim
    commentIdx := name.index("//")
    if (commentIdx != null) name = name[0..<commentIdx].trim
    if (name.endsWith(";")) name = name[0..<name.size-1]
    parts := name.split.findAll |s| { !s.isEmpty }
    Str? alias := null
    if (parts.size >= 3 && parts[-2] == "as")
    {
      alias = parts.last
      name = parts[0..<-2].join(" ")
    }
    java := name.startsWith("[java]")
    if (java) name = name["[java]".size..-1].trim

    pos := Position(curLine, 0)
    endPos := Position(curLine, lines[curLine].size)
    selStart := Position(curLine, lines[curLine].index("using ") + "using ".size)
    selEnd := Position(curLine, lines[curLine].size)

    node := AstNode(AstNodeKind.usingDef, name, LspRange(pos, endPos), LspRange(selStart, selEnd))
    colonIdx := name.index("::")
    node.usingPod = colonIdx == null ? name : name[0..<colonIdx]
    node.usingType = colonIdx == null ? null : name[colonIdx+2..-1]
    node.usingAlias = alias
    node.isJava = java
    result.nodes.add(node)
    curLine++
  }

  private AstNode parseTypeDef(AstNodeKind kind, Str[] mods, Str rest)
  {
    name := extractName(rest)
    header := rest
    openIdx := header.index("{")
    if (openIdx != null) header = header[0..<openIdx]
    heritage := Str[,]
    colonIdx := header.index(":")
    if (colonIdx != null)
    {
      header[colonIdx+1..-1].split(',').each |s|
      {
        if (!s.trim.isEmpty) heritage.add(s.trim)
      }
    }
    startLine := curLine
    col := lines[curLine].index(name) ?: 0
    selRange := LspRange(Position(startLine, col), Position(startLine, col + name.size))

    doc := collectDoc(startLine)
    curLine++

    children := AstNode[,]
    braceDepth := 0
    foundOpen := false

    if (codeLines[startLine].contains("{"))
    {
      foundOpen = true
      braceDepth = braceDelta(codeLines[startLine])
    }

    while (curLine < lines.size && (!foundOpen || braceDepth > 0))
    {
      cline := codeLines[curLine].trim

      if (!foundOpen)
      {
        if (cline.contains("{"))
        {
          foundOpen = true
          braceDepth = braceDelta(cline)
          curLine++
          continue
        }
        curLine++
        continue
      }

      if (cline.isEmpty || cline.startsWith("//") || cline.startsWith("**"))
      {
        curLine++
        continue
      }

      consumedFrom := curLine
      if (cline.startsWith("@"))
      {
        skipFacet
      }
      else if (braceDepth == 1 && !cline.startsWith("}"))
      {
        child := tryParseSlot(kind)
        if (child != null) children.add(child)
        else curLine++
      }
      else
      {
        curLine++
      }
      // Slot parsers may consume multiple lines. Count every real brace once.
      for (i := consumedFrom; i < curLine; i++)
        braceDepth += braceDelta(codeLines[i])
    }

    endLine := (curLine - 1).max(startLine)
    fullRange := LspRange(Position(startLine, 0), Position(endLine, lines.getSafe(endLine)?.size ?: 0))

    node := AstNode(kind, name, fullRange, selRange)
    node.modifiers = mods
    node.doc = doc
    if (!heritage.isEmpty)
    {
      node.baseType = heritage.first
      node.mixins = heritage[1..<heritage.size]
    }
    children.each |c| { c.parent = node; node.children.add(c) }
    return node
  }

  private AstNode? tryParseSlot(AstNodeKind parentKind)
  {
    line := lines[curLine].trim
    if (bodyCallKeywords.contains(extractName(codeLines[curLine].trim))) return null

    mods := Str[,]
    rest := line
    while (true)
    {
      found := false
      modifierKeywords.each |m|
      {
        if (rest.startsWith(m) && rest.size > m.size && !rest[m.size].isAlphaNum)
        {
          mods.add(m)
          rest = rest[m.size..-1].trim
          found = true
        }
      }
      if (!found) break
    }

    code := codeLines[curLine].trim
    nestedRest := code
    mods.each |m| { nestedRest = nestedRest[m.size..-1].trim }
    nested := tryParseTypeDef(mods, nestedRest)
    if (nested != null) return nested

    // Static initializers and bare it-blocks are not slot signatures, even
    // when their opening line contains a call. The type loop tracks the body.
    if (nestedRest.isEmpty || nestedRest == "static" || nestedRest.startsWith("{")) return null

    // A trailing closure is an expression, not a method/field declaration.
    // Do not reject function types in return types, fields, or parameters.
    pipeIdx := code.index("|")
    braceIdx := code.index("{")
    initIdx := code.index(":=")
    if (pipeIdx != null && (braceIdx == null || pipeIdx < braceIdx) &&
        (initIdx == null || initIdx > pipeIdx))
    {
      prefix := code[0..<pipeIdx].trim
      if (!prefix.isEmpty && (prefix.split.size == 1 || prefix.endsWith(")"))) return null
    }

    if (rest.startsWith("new "))
    {
      return parseMethodOrCtor(AstNodeKind.ctorDef, mods, rest["new ".size..-1].trim)
    }

    if (parentKind == AstNodeKind.enumDef && !rest.contains("(") && !rest.contains(" "))
    {
      name := rest
      if (name.endsWith(",")) name = name[0..<name.size-1]
      if (name.endsWith(";")) name = name[0..<name.size-1]
      name = name.trim
      if (!name.isEmpty && name[0].isUpper)
      {
        col := lines[curLine].index(name) ?: 0
        r := LspRange(Position(curLine, 0), Position(curLine, lines[curLine].size))
        sr := LspRange(Position(curLine, col), Position(curLine, col + name.size))
        curLine++
        return AstNode(AstNodeKind.enumValDef, name, r, sr) { it.modifiers = mods }
      }
    }

    parenIdx := indexOutsideIdent(rest, '(')
    assignIdx := rest.index(":=")
    isFieldInit := assignIdx != null && (parenIdx == null || assignIdx < parenIdx)
    looksLikeMethod := parenIdx != null && !isFieldInit && methodNameBeforeParen(rest, parenIdx)

    if (looksLikeMethod)
    {
      return parseMethodOrCtor(AstNodeKind.methodDef, mods, rest)
    }

    if (rest.contains(":=") || rest.contains(" ") && !rest.startsWith("{") && !rest.startsWith("}"))
    {
      return parseField(mods, rest)
    }

    return null
  }

  private static Int? indexOutsideIdent(Str s, Int ch)
  {
    s.index(ch.toChar)
  }

  private static Bool methodNameBeforeParen(Str rest, Int parenIdx)
  {
    if (parenIdx <= 0) return false
    i := parenIdx - 1
    while (i >= 0 && rest[i].isSpace) i--
    if (i < 0) return false
    return rest[i].isAlphaNum || rest[i] == '_'
  }

  private AstNode parseMethodOrCtor(AstNodeKind kind, Str[] mods, Str rest)
  {
    startLine := curLine
    doc := collectDoc(startLine)

    parenIdx := rest.index("(")
    namePart := parenIdx != null ? rest[0..<parenIdx].trim : rest
    tokens := namePart.split
    name := tokens.last ?: namePart
    returnType := tokens.size > 1 ? tokens[0..<tokens.size-1].join(" ") : null

    if (kind == AstNodeKind.ctorDef)
    {
      returnType = null
      name = extractName(rest)
    }

    col := lines[curLine].index(name) ?: 0
    selRange := LspRange(Position(startLine, col), Position(startLine, col + name.size))

    params := Str[,]
    if (parenIdx != null)
    {
      closeIdx := rest.index(")")
      if (closeIdx != null && closeIdx > parenIdx)
      {
        paramStr := rest[parenIdx+1..<closeIdx]
        if (!paramStr.trim.isEmpty)
          splitParams(paramStr).each |p| { params.add(p) }
      }
    }

    endLine := startLine
    callRefs := BodyCallRef[,]
    locals := AstNode[,]
    bodyLine := curLine
    openCol := codeLines[bodyLine].index("{")
    if (openCol == null)
    {
      bodyLine++
      while (bodyLine < lines.size && codeLines[bodyLine].trim.isEmpty) bodyLine++
      if (bodyLine < lines.size && codeLines[bodyLine].trim.startsWith("{"))
        openCol = codeLines[bodyLine].index("{")
    }
    curLine++
    if (openCol != null)
    {
      curLine = bodyLine
      depth := 0
      closureDepths := Int[,]
      closureLocals := AstNode[][,]
      while (curLine < lines.size)
      {
        cl := codeLines[curLine]
        // Preserve columns while excluding the method signature from body refs.
        if (curLine == bodyLine)
          cl = Str.spaces(openCol + 1) + cl[openCol+1..-1]
        extractBodyTypeRefs(curLine, cl)
        extractBodyCallRefs(curLine, cl, callRefs)
        beforeClosures := locals.size
        local := parseBodyLocal(curLine, cl)
        if (local != null) locals.add(local)
        extractClosureParams(curLine, cl, locals)
        openedClosure := locals.size > beforeClosures && cl.index("|") != null &&
          (cl.index("{") != null || nextNonEmptyTrimStartsWith(curLine, "{"))
        startDepth := depth
        depth += braceDelta(codeLines[curLine])
        if (openedClosure)
        {
          group := AstNode[,]
          for (li := beforeClosures; li < locals.size; li++) group.add(locals[li])
          if (depth <= startDepth)
            group.each |n| { n.scopeEndLine = curLine }
          else
          {
            closureDepths.add(depth)
            closureLocals.add(group)
          }
        }
        else if (!closureLocals.isEmpty && local != null)
          closureLocals.last.add(local)
        while (!closureDepths.isEmpty && depth < closureDepths.last)
        {
          closureDepths.pop
          group := closureLocals.pop
          group.each |n| { n.scopeEndLine = curLine }
        }
        curLine++
        if (depth <= 0) break
      }
      endLine = (curLine - 1).max(startLine)
    }

    fullRange := LspRange(Position(startLine, 0), Position(endLine, lines.getSafe(endLine)?.size ?: 0))
    node := AstNode(kind, name, fullRange, selRange)
    node.modifiers = mods
    node.returnType = returnType
    node.params = params
    node.doc = doc
    node.bodyCallRefs = callRefs
    addParamLocalDefs(node, params, startLine)
    locals.each |local| { local.parent = node; node.children.add(local) }
    return node
  }

  // Only explicit typed parameters of a body closure, not function-type
  // declarations or boolean OR expressions. Keep this a line-local heuristic.
  private Void extractClosureParams(Int lineNum, Str code, AstNode[] locals)
  {
    from := 0
    while (from < code.size)
    {
      open := code.index("|", from)
      if (open == null) return
      close := code.index("|", open + 1)
      if (close == null) return
      from = close + 1
      tail := code[from..-1].trim
      if (tail.isEmpty)
      {
        next := lineNum + 1
        while (next < codeLines.size && codeLines[next].trim.isEmpty) next++
        tail = next < codeLines.size ? codeLines[next].trim : ""
      }
      if (!tail.startsWith("{")) continue

      signature := code[open+1..<close]
      arrow := signature.index("->")
      if (arrow != null) signature = signature[0..<arrow]
      paramCol := open + 1
      signature.split(',', false).each |param|
      {
        tokens := param.split
        if (tokens.size == 2)
        {
          type := tokens[0]
          name := tokens[1]
          if ((type[0].isUpper || type[0] == '[' || type.contains("::")) &&
              type.all |ch| { ch.isAlphaNum || "_:?[]".containsChar(ch) } &&
              (name[0].isLower || name[0] == '_') &&
              name.all |ch| { ch.isAlphaNum || ch == '_' })
          {
            col := paramCol + (param.indexr(name) ?: 0)
            r := LspRange(Position(lineNum, col), Position(lineNum, col + name.size))
            locals.add(AstNode(AstNodeKind.localDef, name, r, r) { it.typeName = type })
          }
        }
        paramCol += param.size + 1
      }
    }
  }

  // Best-effort declarations only: no assignment/member-expression inference.
  private AstNode? parseBodyLocal(Int lineNum, Str code)
  {
    assignIdx := code.index(":=")
    if (assignIdx == null) return null
    lhs := code[0..<assignIdx].trim
    tokens := lhs.split
    if (tokens.size < 1 || tokens.size > 2) return null
    name := tokens.last
    if (name.isEmpty || !name[0].isLower ||
        !name.all |ch| { ch.isAlphaNum || ch == '_' }) return null
    if (bodyCallKeywords.contains(tokens.first)) return null
    Str? typeName := null
    if (tokens.size == 2)
    {
      typeName = tokens.first
      // Accept simple, qualified, nullable, list, and map type spellings.
      if (!(typeName[0].isUpper || typeName[0] == '[' || typeName.contains("::"))) return null
      if (!typeName.all |ch| { ch.isAlphaNum || "_:?[]".containsChar(ch) }) return null
    }
    col := code[0..<assignIdx].indexr(name) ?: 0
    sr := LspRange(Position(lineNum, col), Position(lineNum, col + name.size))
    r := LspRange(Position(lineNum, 0), Position(lineNum, lines[lineNum].size))
    return AstNode(AstNodeKind.localDef, name, r, sr) { it.typeName = typeName }
  }

  ** Attach each method/ctor param as a localDef child so rename and
  ** document symbols can see the identifier. Name is the last token of
  ** the param string ("Int x" → "x"). Range is on the signature line.
  private Void addParamLocalDefs(AstNode node, Str[] params, Int startLine)
  {
    line := lines.getSafe(startLine) ?: ""
    // Start after the method-name token, never in a return type or a method
    // substring (e.g. parameter s in process). Match the complete parameter
    // spelling before selecting its final declaration token; function type
    // annotations may themselves contain same-named identifiers.
    searchFrom := line.index("(", node.selectionRange.end.character)
    if (searchFrom == null) return
    searchFrom++
    params.each |p|
    {
      decl := p
      eq := p.index(":=")
      if (eq != null) decl = p[0..<eq].trim
      tokens := decl.split
      if (tokens.isEmpty) return
      pname := tokens.last
      if (pname.isEmpty) return
      if (pname == "null" || pname == "true" || pname == "false") return
      paramStart := line.index(p, searchFrom)
      if (paramStart == null) return
      col := paramStart + decl.size - pname.size
      if (col < paramStart || line[col..<col+pname.size] != pname) return
      searchFrom = paramStart + p.size
      pr := LspRange(Position(startLine, col), Position(startLine, col + pname.size))
      child := AstNode(AstNodeKind.localDef, pname, pr, pr)
      if (tokens.size >= 2) child.typeName = tokens[0..<tokens.size-1].join(" ")
      child.parent = node
      node.children.add(child)
    }
  }

  private AstNode? parseField(Str[] mods, Str rest)
  {
    startLine := curLine

    tokens := rest.split
    if (tokens.size < 2) return null

    Str? typeName := null
    Str? name := null

    assignIdx := rest.index(":=")
    if (assignIdx != null)
    {
      lhs := rest[0..<assignIdx].trim
      ltokens := lhs.split
      if (ltokens.size >= 2)
      {
        typeName = ltokens[0]
        name = ltokens[1]
      }
      else
      {
        name = ltokens[0]
      }
    }
    else
    {
      typeName = tokens[0]
      name = tokens[1]
      if (name.endsWith(";")) name = name[0..<name.size-1]
    }

    if (name == null || name.isEmpty) return null

    col := lines[curLine].index(name) ?: 0
    selRange := LspRange(Position(startLine, col), Position(startLine, col + name.size))

    endLine := startLine
    if (codeLines[curLine].contains("{"))
    {
      depth := braceDelta(codeLines[curLine])
      curLine++
      while (curLine < lines.size && depth > 0)
      {
        depth += braceDelta(codeLines[curLine])
        curLine++
      }
      endLine = (curLine - 1).max(startLine)
    }
    else
    {
      curLine++
    }

    fullRange := LspRange(Position(startLine, 0), Position(endLine, lines.getSafe(endLine)?.size ?: 0))
    doc := collectDoc(startLine)

    node := AstNode(AstNodeKind.fieldDef, name, fullRange, selRange)
    node.modifiers = mods
    node.typeName = typeName
    node.doc = doc
    return node
  }

  private Void extractBodyTypeRefs(Int lineNum, Str lineText)
  {
    i := 0
    while (i < lineText.size)
    {
      ch := lineText[i]
      if (ch.isUpper && (i == 0 || (!lineText[i-1].isAlphaNum && lineText[i-1] != '_')))
      {
        j := i
        buf := StrBuf()
        while (j < lineText.size && (lineText[j].isAlphaNum || lineText[j] == '_'))
        {
          buf.addChar(lineText[j])
          j++
        }
        name := buf.toStr
        r := LspRange(Position(lineNum, i), Position(lineNum, i + name.size))
        result.bodyRefs.add(BodyRef(name, r))
        i = j
      }
      else i++
    }
  }

  private static const Str[] bodyCallKeywords := [
    "if", "else", "while", "for", "foreach", "return", "throw",
    "try", "catch", "finally", "switch", "case", "break", "continue", "super"
  ]

  private Void extractBodyCallRefs(Int lineNum, Str lineText, BodyCallRef[] callRefs)
  {
    i := 0
    while (i < lineText.size)
    {
      ch := lineText[i]
      if ((ch.isAlpha || ch == '_') && (i == 0 || (!lineText[i-1].isAlphaNum && lineText[i-1] != '_')))
      {
        j := i
        buf := StrBuf()
        while (j < lineText.size && (lineText[j].isAlphaNum || lineText[j] == '_'))
        {
          buf.addChar(lineText[j])
          j++
        }
        name := buf.toStr
        if (j < lineText.size && lineText[j] == '(' && !bodyCallKeywords.contains(name))
        {
          r := LspRange(Position(lineNum, i), Position(lineNum, i + name.size))
          callRefs.add(BodyCallRef(name, r))
        }
        i = j
      }
      else i++
    }
  }

  private static Str[] splitParams(Str paramStr)
  {
    result := Str[,]
    buf := StrBuf()
    depth := 0
    paramStr.each |ch|
    {
      if (ch == '[' || ch == '(' || ch == '<') depth++
      else if (ch == ']' || ch == ')' || ch == '>') depth--
      if (ch == ',' && depth == 0)
      {
        t := buf.toStr.trim
        if (!t.isEmpty) result.add(t)
        buf.clear
      }
      else buf.addChar(ch)
    }
    t := buf.toStr.trim
    if (!t.isEmpty) result.add(t)
    return result
  }

  private static Int braceDelta(Str code)
  {
    depth := 0
    code.each |ch|
    {
      if (ch == '{') depth++
      else if (ch == '}') depth--
    }
    return depth
  }

  private Bool nextNonEmptyTrimStartsWith(Int lineNum, Str prefix)
  {
    next := lineNum + 1
    while (next < codeLines.size && codeLines[next].trim.isEmpty) next++
    return next < codeLines.size && codeLines[next].trim.startsWith(prefix)
  }

  private Str extractName(Str text)
  {
    buf := StrBuf()
    for (i := 0; i < text.size; i++)
    {
      ch := text[i]
      if (ch.isAlphaNum || ch == '_') buf.addChar(ch)
      else if (buf.size > 0) break
    }
    return buf.toStr
  }

  private Str? collectDoc(Int beforeLine)
  {
    docs := Str[,]
    i := beforeLine - 1
    while (i >= 0)
    {
      dl := lines[i].trim
      if (dl.startsWith("**"))
      {
        docs.insert(0, dl[2..-1].trim)
        i--
      }
      else if (dl.startsWith("@") || dl.isEmpty)
      {
        i--
      }
      else break
    }
    return docs.isEmpty ? null : docs.join("\n")
  }

  // A facet's initializer may contain nested blocks and masked literal braces.
  // Do not search beyond the next nonblank line for its opening brace.
  private Void skipFacet()
  {
    openLine := curLine
    openCol := codeLines[openLine].index("{")
    if (openCol == null)
    {
      openLine++
      while (openLine < lines.size && codeLines[openLine].trim.isEmpty) openLine++
      if (openLine < lines.size && codeLines[openLine].trim.startsWith("{"))
        openCol = codeLines[openLine].index("{")
    }
    if (openCol == null) { curLine++; return }

    curLine = openLine
    depth := 0
    while (curLine < lines.size)
    {
      code := codeLines[curLine]
      for (i := curLine == openLine ? openCol : 0; i < code.size; i++)
      {
        if (code[i] == '{') depth++
        else if (code[i] == '}')
        {
          depth--
          if (depth == 0) { curLine++; return }
        }
      }
      curLine++
    }
  }

  private Void skipBlockComment()
  {
    while (curLine < lines.size)
    {
      if (lines[curLine].contains("*/")) { curLine++; return }
      curLine++
    }
  }

  private Void addError(Int line, Int col, Str msg)
  {
    r := LspRange(Position(line, col), Position(line, lines.getSafe(line)?.size ?: col))
    result.errors.add(ParseError(r, msg))
  }
}
