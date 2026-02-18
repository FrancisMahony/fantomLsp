class CodeActionProvider
{
  Obj? codeActions(DocumentState doc, LspRange range, [Str:Obj?] context, SymbolTable symbolTable, TypeResolver typeResolver)
  {
    actions := [Str:Obj?][,]

    diagnostics := context["diagnostics"] as List
    if (diagnostics != null)
    {
      diagnostics.each |[Str:Obj?] diag|
      {
        msg := diag["message"] as Str ?: ""
        if (msg.contains("using"))
        {
          actions.add([
            "title": "Add missing using statement",
            "kind": "quickfix",
          ])
        }
      }
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
}
