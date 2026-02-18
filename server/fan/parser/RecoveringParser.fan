class RecoveringParser
{
  private Str[] lines := [,]
  private Int curLine := 0
  private ParseResult result := ParseResult("")
  private static const Str[] modifierKeywords := ["public", "protected", "private", "internal",
    "static", "virtual", "override", "abstract", "final", "const", "native", "once", "readonly"]
  private static const Str[] typeKeywords := ["class", "mixin", "enum", "facet"]

  ParseResult parse(Str uri, Str text)
  {
    this.result = ParseResult(uri)
    this.lines = text.splitLines
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
    return result
  }

  private Void parseLine()
  {
    line := curLine < lines.size ? lines[curLine].trim : ""

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
      curLine++
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

    if (rest.startsWith("class ") || rest.startsWith("class\t"))
    {
      parseTypeDef(AstNodeKind.classDef, mods, rest["class ".size..-1].trim)
      return
    }
    if (rest.startsWith("mixin ") || rest.startsWith("mixin\t"))
    {
      parseTypeDef(AstNodeKind.mixinDef, mods, rest["mixin ".size..-1].trim)
      return
    }
    if (rest.startsWith("enum "))
    {
      rest2 := rest["enum ".size..-1].trim
      if (rest2.startsWith("class "))
      {
        parseTypeDef(AstNodeKind.enumDef, mods, rest2["class ".size..-1].trim)
        return
      }
    }
    if (rest.startsWith("facet "))
    {
      rest2 := rest["facet ".size..-1].trim
      if (rest2.startsWith("class "))
      {
        parseTypeDef(AstNodeKind.facetClassDef, mods, rest2["class ".size..-1].trim)
        return
      }
    }

    curLine++
  }

  private Void parseUsing()
  {
    line := lines[curLine].trim
    name := line["using ".size..-1].trim
    if (name.endsWith(";")) name = name[0..<name.size-1]

    pos := Position(curLine, 0)
    endPos := Position(curLine, lines[curLine].size)
    selStart := Position(curLine, lines[curLine].index("using ") + "using ".size)
    selEnd := Position(curLine, lines[curLine].size)

    node := AstNode(AstNodeKind.usingDef, name, LspRange(pos, endPos), LspRange(selStart, selEnd))
    result.nodes.add(node)
    curLine++
  }

  private Void parseTypeDef(AstNodeKind kind, Str[] mods, Str rest)
  {
    name := extractName(rest)
    startLine := curLine
    col := lines[curLine].index(name) ?: 0
    selRange := LspRange(Position(startLine, col), Position(startLine, col + name.size))

    doc := collectDoc(startLine)
    curLine++

    children := AstNode[,]
    braceDepth := 0
    foundOpen := false

    if (rest.contains("{"))
    {
      foundOpen = true
      braceDepth = 1
    }

    while (curLine < lines.size)
    {
      cline := lines[curLine].trim

      if (!foundOpen)
      {
        if (cline.contains("{"))
        {
          foundOpen = true
          braceDepth = 1
          curLine++
          continue
        }
        curLine++
        continue
      }

      if (cline.isEmpty || cline.startsWith("//") || cline.startsWith("**") || cline.startsWith("@"))
      {
        curLine++
        continue
      }

      if (cline == "}" || cline.startsWith("}"))
      {
        braceDepth--
        if (braceDepth <= 0) { curLine++; break }
      }

      if (cline.startsWith("/*")) { skipBlockComment; continue }

      if (braceDepth == 1 && foundOpen)
      {
        child := tryParseSlot(kind)
        if (child != null) children.add(child)
        else curLine++
      }
      else
      {
        if (cline.contains("{")) braceDepth++
        curLine++
      }
    }

    endLine := (curLine - 1).max(startLine)
    fullRange := LspRange(Position(startLine, 0), Position(endLine, lines.getSafe(endLine)?.size ?: 0))

    node := AstNode(kind, name, fullRange, selRange)
    node.modifiers = mods
    node.doc = doc
    children.each |c| { c.parent = node; node.children.add(c) }
    result.nodes.add(node)
  }

  private AstNode? tryParseSlot(AstNodeKind parentKind)
  {
    line := lines[curLine].trim

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
        return AstNode(AstNodeKind.enumValDef, name, r, sr) { it.modifiers = mods }
      }
    }

    if (rest.contains("("))
    {
      return parseMethodOrCtor(AstNodeKind.methodDef, mods, rest)
    }

    if (rest.contains(":=") || rest.contains(" ") && !rest.startsWith("{") && !rest.startsWith("}"))
    {
      return parseField(mods, rest)
    }

    return null
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
        {
          paramStr.split(',').each |p| { params.add(p.trim) }
        }
      }
    }

    endLine := startLine
    if (rest.contains("{"))
    {
      depth := 1
      curLine++
      while (curLine < lines.size && depth > 0)
      {
        cl := lines[curLine]
        cl.each |ch|
        {
          if (ch == '{') depth++
          else if (ch == '}') depth--
        }
        curLine++
      }
      endLine = (curLine - 1).max(startLine)
    }
    else
    {
      curLine++
      if (curLine < lines.size && lines[curLine].trim.startsWith("{"))
      {
        depth := 1
        curLine++
        while (curLine < lines.size && depth > 0)
        {
          cl := lines[curLine]
          cl.each |ch|
          {
            if (ch == '{') depth++
            else if (ch == '}') depth--
          }
          curLine++
        }
        endLine = (curLine - 1).max(startLine)
      }
      else
      {
        endLine = startLine
      }
    }

    fullRange := LspRange(Position(startLine, 0), Position(endLine, lines.getSafe(endLine)?.size ?: 0))
    node := AstNode(kind, name, fullRange, selRange)
    node.modifiers = mods
    node.returnType = returnType
    node.params = params
    node.doc = doc
    return node
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
    if (rest.contains("{"))
    {
      depth := 1
      curLine++
      while (curLine < lines.size && depth > 0)
      {
        cl := lines[curLine]
        cl.each |ch|
        {
          if (ch == '{') depth++
          else if (ch == '}') depth--
        }
        curLine++
      }
      endLine = (curLine - 1).max(startLine)
    }

    fullRange := LspRange(Position(startLine, 0), Position(endLine, lines.getSafe(endLine)?.size ?: 0))
    doc := collectDoc(startLine)

    node := AstNode(AstNodeKind.fieldDef, name, fullRange, selRange)
    node.modifiers = mods
    node.typeName = typeName
    node.doc = doc
    return node
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
