class CompletionProvider : LspUtils
{
  private static const Str[] fantomKeywords := [
    "abstract", "as", "assert", "break", "case", "catch", "class", "const",
    "continue", "default", "do", "else", "enum", "facet", "false", "final",
    "finally", "for", "foreach", "if", "internal", "is", "isnot", "it",
    "mixin", "native", "new", "null", "once", "override", "private",
    "protected", "public", "readonly", "return", "static", "super", "switch",
    "this", "throw", "true", "try", "using", "virtual", "void", "volatile",
    "while",
  ]

  Obj? complete(DocumentState doc, ParseResult parseResult, Position pos)
  {
    line := doc.getLine(pos.line) ?: ""

    // Using statement: suggest installed pod names
    trimmedLine := line.trim
    if (trimmedLine.startsWith("using "))
    {
      podPrefix := trimmedLine["using ".size..-1].trim
      return usingCompletions(podPrefix)
    }

    prefix := pos.character <= line.size ? line[0..<pos.character] : line

    // Extract the word being typed
    wordEnd := prefix.size - 1
    i := wordEnd
    while (i >= 0 && isIdentChar(prefix[i])) i--
    word := i < wordEnd ? prefix[i+1..wordEnd] : ""

    isDot := i >= 0 && prefix[i] == '.'

    podNames := extractUsings(parseResult)
    items := [Str:Obj?][,]

    if (isDot)
    {
      recvEnd := i - 1
      j := recvEnd
      while (j >= 0 && isIdentChar(prefix[j])) j--
      receiver := j < recvEnd ? prefix[j+1..recvEnd] : ""
      if (!receiver.isEmpty)
        items = dotCompletions(receiver, word, doc, parseResult, podNames, pos.line)
    }
    else
    {
      items = plainCompletions(word, doc, parseResult, podNames, pos.line)
    }

    return ["isIncomplete": false, "items": items]
  }

  // ── Using pod completion ────────────────────────────────────────────────────

  private Obj? usingCompletions(Str prefix)
  {
    items := [Str:Obj?][,]
    Pod.list.each |pod|
    {
      if (!isSyntheticName(pod.name) && pod.name.startsWith(prefix))
        items.add(CompletionItem(pod.name, CompletionItem.module).toMap)
    }
    return ["isIncomplete": false, "items": items]
  }

  // ── Dot completion ──────────────────────────────────────────────────────────

  private [Str:Obj?][] dotCompletions(Str receiver, Str word, DocumentState doc,
                                       ParseResult parseResult, Str[] podNames, Int line)
  {
    items := [Str:Obj?][,]

    // this. → slots of the enclosing class
    if (receiver == "this")
    {
      enclosing := findEnclosingClass(parseResult, line)
      if (enclosing != null)
        enclosing.children.each |child|
        {
          if (word.isEmpty || child.name.lower.startsWith(word.lower))
            items.add(makeLocalItem(child))
        }
      return items
    }

    // super. → slots of the parent type
    if (receiver == "super")
    {
      enclosing := findEnclosingClass(parseResult, line)
      if (enclosing != null)
      {
        parentName := findParentTypeName(doc, enclosing)
        if (parentName != null)
        {
          t := findType(podNames, parentName)
          if (t == null) t = findTypeInAnyPod(parentName)
          if (t != null) addTypeSlots(t, word, items)
        }
      }
      return items
    }

    // it. → element type inferred from the enclosing closure receiver
    if (receiver == "it")
    {
      itType := inferItType(doc, parseResult, podNames, line)
      if (itType != null)
      {
        local := findLocalType(parseResult, itType)
        if (local != null)
          local.children.each |child|
          {
            if (word.isEmpty || child.name.lower.startsWith(word.lower))
              items.add(makeLocalItem(child))
          }
        t := findType(podNames, itType)
        if (t == null) t = findTypeInAnyPod(itType)
        if (t != null) addTypeSlots(t, word, items)
      }
      return items
    }

    // General: infer receiver type, then show its slots
    typeName := inferVarType(doc, receiver, parseResult, podNames)
    if (typeName == null) typeName = receiver

    local := findLocalType(parseResult, typeName)
    if (local != null)
      local.children.each |child|
      {
        if (word.isEmpty || child.name.lower.startsWith(word.lower))
          items.add(makeLocalItem(child))
      }

    t := findType(podNames, typeName)
    if (t == null) t = findTypeInAnyPod(typeName)
    if (t != null) addTypeSlots(t, word, items)

    return items
  }

  private Void addTypeSlots(Type t, Str word, [Str:Obj?][] items)
  {
    t.slots.each |slot|
    {
      if (isSyntheticName(slot.name)) return
      if (word.isEmpty || slot.name.lower.startsWith(word.lower))
        items.add(makeReflectedSlotItem(slot))
    }
  }

  // ── Plain completion ────────────────────────────────────────────────────────

  private [Str:Obj?][] plainCompletions(Str word, DocumentState doc,
                                         ParseResult parseResult, Str[] podNames, Int curLine)
  {
    items := [Str:Obj?][,]
    if (word.isEmpty) return items

    lw := word.lower

    // Scope-aware local variable names (only lines above cursor)
    collectLocalVarNames(doc, curLine).each |name|
    {
      if (name.lower.startsWith(lw))
        items.add(CompletionItem(name, CompletionItem.variable).toMap)
    }

    // Local types and their slots from the parsed AST
    parseResult.nodes.each |node|
    {
      if (node.kind == AstNodeKind.usingDef) return
      if (node.name.lower.startsWith(lw))
        items.add(makeLocalItem(node))
      node.children.each |child|
      {
        if (child.name.lower.startsWith(lw))
          items.add(makeLocalItem(child))
      }
    }

    // Override suggestions when cursor is in a class body (not inside a method)
    enclosing := findEnclosingClass(parseResult, curLine)
    if (enclosing != null && isInClassBody(enclosing, curLine))
    {
      parentName := findParentTypeName(doc, enclosing)
      if (parentName != null)
      {
        pt := findType(podNames, parentName)
        if (pt == null) pt = findTypeInAnyPod(parentName)
        if (pt != null)
          pt.slots.each |slot|
          {
            if (isSyntheticName(slot.name)) return
            if (slot is Method)
            {
              m := (Method)slot
              if ((m.isVirtual || m.isAbstract) && !m.isCtor && m.name.lower.startsWith(lw))
                items.add(makeOverrideItem(m))
            }
          }
      }
    }

    // Pod type names (skip compiler-generated synthetic types)
    podNames.each |pn|
    {
      pod := Pod.find(pn, false)
      if (pod == null) return
      pod.types.each |t|
      {
        if (isSyntheticName(t.name)) return
        if (t.name.lower.startsWith(lw))
          items.add(makeReflectedTypeItem(t))
      }
    }

    // Keywords
    fantomKeywords.each |kw|
    {
      if (kw.startsWith(lw))
        items.add(CompletionItem(kw, CompletionItem.keyword).toMap)
    }

    return items
  }

  // ── Context helpers ─────────────────────────────────────────────────────────

  // Only collect variable names from lines at or above the cursor
  private Str[] collectLocalVarNames(DocumentState doc, Int beforeLine)
  {
    names := Str[,]
    lines := doc.lines
    for (i := 0; i < lines.size && i <= beforeLine; i++)
    {
      trimmed := lines[i].trim
      idx := trimmed.index(":=")
      if (idx == null || idx == 0) continue
      lhs := trimmed[0..<idx].trim
      tokens := lhs.split
      name := tokens.last ?: ""
      if (name.isEmpty || !name[0].isLower) continue
      if (!names.contains(name)) names.add(name)
    }
    return names
  }

  // Find the top-level class/mixin/enum node whose range contains the given line
  private AstNode? findEnclosingClass(ParseResult parseResult, Int line)
  {
    return parseResult.nodes.find |node|
    {
      node.isType && node.range.start.line <= line && node.range.end.line >= line
    }
  }

  // True when the cursor is in the class body — not inside any child slot's range
  private Bool isInClassBody(AstNode classNode, Int line)
  {
    return !classNode.children.any |child|
    {
      child.isSlot && child.range.start.line < line && child.range.end.line >= line
    }
  }

  // Extract the parent type name from the class definition line (e.g. "class Foo : Bar")
  private Str? findParentTypeName(DocumentState doc, AstNode typeNode)
  {
    defLine := doc.getLine(typeNode.range.start.line) ?: ""
    colonIdx := defLine.index(":")
    if (colonIdx == null) return null
    // Skip "::" (pod separator)
    if (colonIdx + 1 < defLine.size && defLine[colonIdx + 1] == ':') return null
    rest := defLine[colonIdx + 1..-1].trim
    buf := StrBuf()
    for (i := 0; i < rest.size; i++)
    {
      ch := rest[i]
      if (ch.isAlphaNum || ch == '_') buf.addChar(ch)
      else if (buf.size > 0) break
    }
    // Handle "pod::Type" — skip to after "::"
    name := buf.toStr
    if (name.isEmpty) return null
    afterName := rest[name.size..-1]
    if (afterName.startsWith("::"))
    {
      buf2 := StrBuf()
      rest2 := afterName[2..-1]
      for (i := 0; i < rest2.size; i++)
      {
        ch := rest2[i]
        if (ch.isAlphaNum || ch == '_') buf2.addChar(ch)
        else if (buf2.size > 0) break
      }
      if (!buf2.isEmpty) return buf2.toStr
    }
    return name
  }

  // Infer the "it" type by scanning backwards for the nearest enclosing closure receiver
  // e.g.  users.each { it.name }  →  infer type of "users" → "User"
  private Str? inferItType(DocumentState doc, ParseResult parseResult, Str[] podNames, Int line)
  {
    lines := doc.lines
    for (i := line; i >= 0; i--)
    {
      l := lines.getSafe(i)?.trim ?: ""
      if (l.isEmpty) continue
      braceIdx := l.index("{")
      if (braceIdx == null) continue
      before := l[0..<braceIdx].trim
      if (before.isEmpty) continue
      dotIdx := before.indexr(".")
      if (dotIdx == null || dotIdx == 0) continue
      receiverPart := before[0..<dotIdx].trim
      receiverName := lastIdent(receiverPart)
      if (receiverName.isEmpty) break
      t := inferVarType(doc, receiverName, parseResult, podNames)
      if (t != null) return t
      break
    }
    return null
  }

  // Extract the last identifier from a string (e.g. "user1.items" → "items")
  private Str lastIdent(Str s)
  {
    end := s.size - 1
    while (end >= 0 && !isIdentChar(s[end])) end--
    if (end < 0) return ""
    start := end
    while (start > 0 && isIdentChar(s[start - 1])) start--
    return s[start..end]
  }

  // ── Item builders ───────────────────────────────────────────────────────────

  private [Str:Obj?] makeLocalItem(AstNode node)
  {
    Int kind := CompletionItem.text
    switch (node.kind)
    {
      case AstNodeKind.classDef:      kind = CompletionItem.classKind
      case AstNodeKind.mixinDef:      kind = CompletionItem.interfaceKind
      case AstNodeKind.enumDef:       kind = CompletionItem.classKind
      case AstNodeKind.facetClassDef: kind = CompletionItem.classKind
      case AstNodeKind.methodDef:     kind = CompletionItem.method
      case AstNodeKind.ctorDef:       kind = CompletionItem.constructor
      case AstNodeKind.fieldDef:      kind = CompletionItem.field
      case AstNodeKind.enumValDef:    kind = CompletionItem.enumMember
      default:                        kind = CompletionItem.text
    }
    detail := formatLocalSig(node)

    // Snippet: place cursor inside parens for methods/ctors
    Str? insertText := null
    Int? insertFmt := null
    if (node.kind == AstNodeKind.methodDef || node.kind == AstNodeKind.ctorDef)
    {
      params := node.params
      insertText = params == null || params.isEmpty ? node.name + "()" : node.name + "(\$0)"
      insertFmt = 2
    }

    return CompletionItem(node.name, kind, detail, node.doc, insertText, insertFmt).toMap
  }

  private [Str:Obj?] makeReflectedTypeItem(Type t)
  {
    return CompletionItem(t.name, CompletionItem.classKind, formatTypeSig(t), t.doc).toMap
  }

  private [Str:Obj?] makeReflectedSlotItem(Slot slot)
  {
    Int kind := CompletionItem.text
    Str detail := slot.name
    Str? insertText := null
    Int? insertFmt := null

    if (slot is Method)
    {
      m := (Method)slot
      kind = m.isCtor ? CompletionItem.constructor : CompletionItem.method
      detail = formatMethodSig(m)
      insertText = m.params.isEmpty ? slot.name + "()" : slot.name + "(\$0)"
      insertFmt = 2
    }
    else
    {
      f := (Field)slot
      kind = CompletionItem.field
      detail = "${f.type.name} ${f.name}"
    }
    return CompletionItem(slot.name, kind, detail, slot.doc, insertText, insertFmt).toMap
  }

  // Override stub: label is the method name, insertText is the full override block
  private [Str:Obj?] makeOverrideItem(Method m)
  {
    sigBuf := StrBuf()
    sigBuf.add("override ").add(m.returns.name).add(" ").add(m.name).add("(")
    m.params.each |p, i| { if (i > 0) sigBuf.add(", "); sigBuf.add(p.type.name).add(" ").add(p.name) }
    sigBuf.add(")")
    sig := sigBuf.toStr

    insert := sig + "\n{\n  \$0\n}"

    return CompletionItem(m.name, CompletionItem.method, sig, m.doc, insert, 2).toMap
  }
}
