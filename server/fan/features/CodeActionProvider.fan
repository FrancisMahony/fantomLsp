class CodeActionProvider
{
  Obj? codeActions(DocumentState doc, ParseResult parseResult, LspRange range, [Str:Obj?] context)
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
                  doc.uri: [
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
            doc.uri: [
              ["range": removeRange.toMap, "newText": ""],
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
        actions.add([
          "title": "Uncomment line",
          "kind": "refactor",
          "edit": [
            "changes": [
              doc.uri: [
                ["range": range.toMap, "newText": trimmed[2..-1].trim],
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
        return !lines.any |line, idx| { idx != skipLine && line.contains(typeName) }
      }
      else
      {
        if (name == "sys") return false
        pod := Pod.find(name, false)
        if (pod == null) return false
        // Build one string from all non-using lines, then check each type name with a
        // single contains() call — O(lines + types) instead of O(types × lines).
        buf := StrBuf()
        lines.each |line, idx| { if (idx != skipLine) buf.add(line).add("\n") }
        docText := buf.toStr
        return pod.types.all |t| { !docText.contains(t.name) }
      }
    }
  }
}
