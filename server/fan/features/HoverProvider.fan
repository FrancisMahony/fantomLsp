class HoverProvider : LspUtils
{
  [Str:Obj?]? hover(DocumentState doc, ParseResult parseResult, Position pos)
  {
    word := doc.getWordAt(pos)
    if (word.isEmpty) return null

    podNames := extractUsings(parseResult)

    // 1. Local variable with an inferable type
    typeName := inferVarType(doc, word, parseResult, podNames)
    if (typeName != null)
    {
      md := StrBuf()
      md.add("```fantom\n${typeName} ${word}\n```")
      typeNode := findLocalNode(parseResult, typeName)
      if (typeNode != null)
      {
        md.add("\n\n---\n\n```fantom\n${formatLocalSig(typeNode)}\n```")
        makeNode := typeNode.children.find |c| { c.kind == AstNodeKind.ctorDef && c.name == "make" }
        if (makeNode != null)
          md.add("\n```fantom\n${formatLocalSig(makeNode)}\n```")
      }
      return ["contents": ["kind": "markdown", "value": md.toStr]]
    }

    // 2. Local file definition (type, method, or field)
    localNode := findLocalNode(parseResult, word)
    if (localNode != null)
    {
      md := StrBuf()
      md.add("```fantom\n${formatLocalSig(localNode)}\n```")
      if (localNode.doc != null) md.add("\n\n---\n\n").add(localNode.doc)
      if (localNode.isType)
      {
        makeNode := localNode.children.find |c| { c.kind == AstNodeKind.ctorDef && c.name == "make" }
        if (makeNode != null)
          md.add("\n\n**Constructor:** `").add(formatLocalSig(makeNode)).add("`")
      }
      return ["contents": ["kind": "markdown", "value": md.toStr]]
    }

    // 3. Pod type (usings first, then all pods)
    t := findType(podNames, word)
    if (t == null) t = findTypeInAnyPod(word)
    if (t != null)
    {
      md := StrBuf()
      md.add("```fantom\n${formatTypeSig(t)}\n```")
      if (t.doc != null) md.add("\n\n---\n\n").add(t.doc)
      makeMethod := t.method("make", false)
      if (makeMethod != null)
        md.add("\n\n**Constructor:** `").add(formatMethodSig(makeMethod)).add("`")
      return ["contents": ["kind": "markdown", "value": md.toStr]]
    }

    // 4. Pod slot
    slot := findSlot(podNames, word)
    if (slot != null)
    {
      sig := formatSlotSig(slot)
      md := "```fantom\n${sig}\n```\n\n*${slot.parent.qname}*"
      if (slot.doc != null) md = md + "\n\n---\n\n" + slot.doc
      return ["contents": ["kind": "markdown", "value": md]]
    }

    return null
  }

  private Slot? findSlot(Str[] podNames, Str name)
  {
    return podNames.eachWhile |pn|
    {
      pod := Pod.find(pn, false)
      if (pod == null) return null
      return pod.types.eachWhile |t|
      {
        s := t.slot(name, false)
        if (s != null && s.parent == t) return s
        return null
      }
    }
  }
}
