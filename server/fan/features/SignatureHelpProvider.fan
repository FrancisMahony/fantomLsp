class SignatureHelpProvider : LspUtils
{
  Obj? signatureHelp(DocumentState doc, ParseResult parseResult, Position pos)
  {
    line := doc.getLine(pos.line) ?: ""
    prefix := pos.character <= line.size ? line[0..<pos.character] : line

    // Scan backwards to find the opening '(' we're inside, counting commas for activeParam
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

    // Extract the function/method name before '('
    funcName := ""
    j := funcEnd - 1
    while (j >= 0 && isIdentChar(prefix[j]))
    {
      funcName = prefix[j].toChar + funcName
      j--
    }
    if (funcName.isEmpty) return null

    // Check for a receiver before the dot: "receiver.funcName("
    Str? receiver := null
    if (j >= 0 && prefix[j] == '.')
    {
      k := j - 1
      recv := ""
      while (k >= 0 && isIdentChar(prefix[k]))
      {
        recv = prefix[k].toChar + recv
        k--
      }
      if (!recv.isEmpty) receiver = recv
    }

    podNames := extractUsings(parseResult)
    Method? reflected := null
    AstNode? local := null

    if (receiver != null)
    {
      // Dot call: resolve receiver type then find the method
      typeName := inferVarType(doc, receiver, parseResult, podNames) ?: receiver
      t := findType(podNames, typeName)
      if (t == null) t = findTypeInAnyPod(typeName)
      if (t != null) reflected = t.method(funcName, false)
      if (reflected == null)
      {
        localType := findLocalType(parseResult, typeName)
        if (localType != null)
          local = localType.children.find |c|
          {
            c.name == funcName && (c.kind == AstNodeKind.methodDef || c.kind == AstNodeKind.ctorDef)
          }
      }
    }
    else if (!funcName.isEmpty && funcName[0].isUpper)
    {
      // Type(...) constructor shorthand — look up make()
      t := findType(podNames, funcName)
      if (t == null) t = findTypeInAnyPod(funcName)
      if (t != null) reflected = t.method("make", false)
      if (reflected == null)
      {
        localType := findLocalType(parseResult, funcName)
        if (localType != null)
          local = localType.children.find |c| { c.kind == AstNodeKind.ctorDef && c.name == "make" }
      }
    }
    else
    {
      // Bare function call — search local parse then pods
      parseResult.nodes.eachWhile |node|
      {
        if (node.name == funcName && (node.kind == AstNodeKind.methodDef || node.kind == AstNodeKind.ctorDef))
          return local = node
        c := node.children.find |child|
        {
          child.name == funcName && (child.kind == AstNodeKind.methodDef || child.kind == AstNodeKind.ctorDef)
        }
        if (c != null) return local = c
        return null
      }
      if (local == null)
      {
        podNames.eachWhile |pn|
        {
          pod := Pod.find(pn, false)
          if (pod == null) return null
          return pod.types.eachWhile |t|
          {
            m := t.method(funcName, false)
            if (m != null) return reflected = m
            return null
          }
        }
      }
    }

    if (reflected == null && local == null) return null

    // Build the signature label and one ParameterInformation per parameter
    sigBuf := StrBuf()
    params := ParameterInformation[,]

    if (reflected != null)
    {
      if (reflected.isStatic) sigBuf.add("static ")
      sigBuf.add(reflected.returns.name).add(" ").add(reflected.name).add("(")
      reflected.params.each |p, idx|
      {
        if (idx > 0) sigBuf.add(", ")
        label := "${p.type.name} ${p.name}"
        sigBuf.add(label)
        params.add(ParameterInformation(label))
      }
      sigBuf.add(")")
    }
    else
    {
      node := local
      if (node.kind == AstNodeKind.ctorDef) sigBuf.add("new ")
      else if (node.returnType != null) sigBuf.add(node.returnType).add(" ")
      sigBuf.add(node.name).add("(")
      node.params?.each |p, idx|
      {
        if (idx > 0) sigBuf.add(", ")
        sigBuf.add(p)
        params.add(ParameterInformation(p))
      }
      sigBuf.add(")")
    }

    if (params.isEmpty) return null

    Str? docStr := reflected?.doc ?: local?.doc
    sigInfo := SignatureInformation(sigBuf.toStr, docStr, params)
    return [
      "signatures": [sigInfo.toMap],
      "activeSignature": 0,
      "activeParameter": activeParam.min(params.size - 1).max(0),
    ]
  }
}
