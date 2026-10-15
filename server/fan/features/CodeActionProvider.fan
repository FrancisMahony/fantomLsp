class CodeActionProvider
{
  Obj? codeActions(DocumentState doc, ParseResult parseResult, LspRange range, [Str:Obj?] context,
    |Str->Str| clientUri := |Str key->Str| { UriKey.toClientUri(key) })
  {
    actions := [Str:Obj?][,]

    diagnostics := context["diagnostics"] as List
    if (diagnostics != null)
    {
      diagnostics.each |[Str:Obj?] diag|
      {
        msg := diag["message"] as Str ?: ""
        typeName := extractUnknownTypeName(msg)
        if (typeName != null)
        {
          Pod? foundPod := null
          Pod.list.eachWhile |p|
          {
            if (p.type(typeName, false) != null) { foundPod = p; return p }
            return null
          }
          if (foundPod != null)
          {
            insertLine := findUsingInsertLine(parseResult)
            insertPos := Position(insertLine, 0)
            insertRange := LspRange(insertPos, insertPos)
            actions.add([
              "title": "Add 'using ${foundPod.name}'",
              "kind": "quickfix",
              "edit": [
                "changes": [
                  clientUri(doc.uri): [
                    ["range": insertRange.toMap, "newText": "using ${foundPod.name}\n"],
                  ],
                ],
              ],
            ])
          }
        }
      }
    }

    findUnusedUsings(doc, parseResult).each |node|
    {
      lineNum := node.range.start.line
      removeRange := LspRange(Position(lineNum, 0), Position(lineNum + 1, 0))
      actions.add([
        "title": "Remove unused 'using ${node.name}'",
        "kind": "quickfix",
        "edit": [
          "changes": [
            clientUri(doc.uri): [
              ["range": removeRange.toMap, "newText": ""],
            ],
          ],
        ],
      ])
    }

    usingNodes := parseResult.nodes.findAll |node| { node.kind == AstNodeKind.usingDef }
    if (!usingNodes.isEmpty)
    {
      unusedUsings := findUnusedUsings(doc, parseResult)
      remainingUsings := usingNodes.findAll |node|
      {
        !unusedUsings.any |unused| { unused === node }
      }
      remainingUsings.sort |a, b| { a.name <=> b.name }

      firstLine := usingNodes.first.range.start.line
      lastLine := usingNodes.last.range.end.line
      replacement := remainingUsings.map |node| { "using ${node.name}\n" }.join
      usingRange := LspRange(Position(firstLine, 0), Position(lastLine + 1, 0))
      actions.add([
        "title": "Organize usings",
        "kind": "source.organizeImports",
        "edit": [
          "changes": [
            clientUri(doc.uri): [
              ["range": usingRange.toMap, "newText": replacement],
            ],
          ],
        ],
      ])
    }

    line := doc.getLine(range.start.line)
    if (line != null)
    {
      trimmed := line.trim
      if (trimmed.startsWith("//"))
      {
        lineNum := range.start.line
        lineLen := line.size
        fullLine := LspRange(Position(lineNum, 0), Position(lineNum, lineLen))
        actions.add([
          "title": "Uncomment line",
          "kind": "refactor",
          "edit": [
            "changes": [
              clientUri(doc.uri): [
                ["range": fullLine.toMap, "newText": trimmed[2..-1].trim],
              ],
            ],
          ],
        ])
      }
    }

    return actions
  }

  Str? extractUnknownTypeName(Str msg)
  {
    marker := "Unknown type '"
    idx := msg.index(marker)
    if (idx == null) return null
    start := idx + marker.size
    end := msg.index("'", start)
    if (end == null) return null
    name := msg[start..<end]
    colonIdx := name.index("::")
    if (colonIdx != null) name = name[colonIdx+2..-1]
    return name
  }

  Int findUsingInsertLine(ParseResult parseResult)
  {
    lastLine := -1
    parseResult.nodes.each |node|
    {
      if (node.kind == AstNodeKind.usingDef)
        lastLine = lastLine.max(node.range.end.line)
    }
    return lastLine + 1
  }

  AstNode[] findUnusedUsings(DocumentState doc, ParseResult parseResult)
  {
    usingNodes := parseResult.nodes.findAll |node| { node.kind == AstNodeKind.usingDef }
    if (usingNodes.isEmpty) return [,]
    lines := doc.text.splitLines
    return usingNodes.findAll |node|
    {
      name := node.name
      skipLine := node.range.start.line
      colonIdx := name.index("::")
      if (colonIdx != null)
      {
        typeName := name[colonIdx+2..-1]
        return !lines.any |line, idx|
        {
          if (idx == skipLine) return false
          t := line.trim
          if (t.startsWith("//")) return false
          return containsIdent(line, typeName)
        }
      }
      else
      {
        if (name == "sys") return false
        pod := Pod.find(name, false)
        if (pod == null) return false
        return pod.types.all |t|
        {
          !lines.any |line, idx|
          {
            if (idx == skipLine) return false
            trimmed := line.trim
            if (trimmed.startsWith("//")) return false
            return containsIdent(line, t.name)
          }
        }
      }
    }
  }

  private Bool containsIdent(Str line, Str ident)
  {
    idx := 0
    while (true)
    {
      found := line.index(ident, idx)
      if (found == null) return false
      beforeOk := found == 0 || !isIdentChar(line[found - 1])
      after := found + ident.size
      afterOk := after >= line.size || !isIdentChar(line[after])
      if (beforeOk && afterOk) return true
      idx = found + 1
    }
    return false
  }

  private Bool isIdentChar(Int ch)
  {
    ch.isAlphaNum || ch == '_'
  }
}
