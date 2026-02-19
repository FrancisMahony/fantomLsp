**
** Shared utilities mixed into HoverProvider, CompletionProvider, and
** SignatureHelpProvider. Contains all type resolution, inference, and
** signature formatting logic so it is not duplicated across providers.
**
mixin LspUtils
{
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
      pod := Pod.find(pn, false)
      if (pod == null) return null
      return pod.type(name, false)
    }
  }

  Type? findTypeInAnyPod(Str name)
  {
    return Pod.list.eachWhile |pod| { pod.type(name, false) }
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
      default:
        buf.add(node.name)
    }
    return buf.toStr
  }

  // ── Utilities ───────────────────────────────────────────────────────────────

  Bool isIdentChar(Int ch) { ch.isAlphaNum || ch == '_' }

  // Compiler-generated synthetic names (closures, field accessors, etc.) contain '$'
  Bool isSyntheticName(Str name) { name.contains("\$") }
}
