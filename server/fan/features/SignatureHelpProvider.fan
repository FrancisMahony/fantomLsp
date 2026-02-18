class SignatureHelpProvider
{
  Obj? signatureHelp(DocumentState doc, Position pos, SymbolTable symbolTable, TypeResolver typeResolver)
  {
    line := doc.getLine(pos.line) ?: ""
    prefix := pos.character <= line.size ? line[0..<pos.character] : line

    parenDepth := 0
    activeParam := 0
    funcEnd := -1

    i := prefix.size - 1
    while (i >= 0)
    {
      ch := prefix[i]
      if (ch == ')') parenDepth++
      else if (ch == '(')
      {
        if (parenDepth == 0) { funcEnd = i; break }
        parenDepth--
      }
      else if (ch == ',' && parenDepth == 0) activeParam++
      i--
    }

    if (funcEnd < 0) return null

    funcName := ""
    j := funcEnd - 1
    while (j >= 0 && (prefix[j].isAlphaNum || prefix[j] == '_'))
    {
      funcName = prefix[j].toChar + funcName
      j--
    }

    if (funcName.isEmpty) return null

    entry := symbolTable.findByName(funcName)
    node := entry?.node
    if (node == null)
    {
      symbolTable.allEntries.each |e|
      {
        e.node.children.each |child|
        {
          if (child.name == funcName && (child.kind == AstNodeKind.methodDef || child.kind == AstNodeKind.ctorDef))
            node = child
        }
      }
    }

    if (node == null) return null
    if (node.kind != AstNodeKind.methodDef && node.kind != AstNodeKind.ctorDef) return null

    sig := typeResolver.formatSignature(node)
    params := ParameterInformation[,]
    if (node.params != null)
    {
      node.params.each |p| { params.add(ParameterInformation(p)) }
    }

    sigInfo := SignatureInformation(sig, node.doc, params)
    return [
      "signatures": [sigInfo.toMap],
      "activeSignature": 0,
      "activeParameter": activeParam.min(params.size - 1).max(0),
    ]
  }
}
