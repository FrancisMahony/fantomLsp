class InlayHintProvider : LspUtils
{
  [Str:Obj?][] hints(DocumentState doc, ParseResult parseResult, LspRange? range := null)
  {
    out := [Str:Obj?][,]
    podNames := extractUsings(parseResult)

    doc.lines.each |line, lineNo|
    {
      if (range != null && (lineNo < range.start.line || lineNo > range.end.line)) return
      assignment := line.index(":=")
      if (assignment == null) return

      lhs := line[0..<assignment].trim
      tokens := lhs.split
      if (tokens.size != 1) return
      name := tokens[0]
      if (name.isEmpty || !name[0].isLower) return

      rhs := line[assignment + 2..-1].trim
      typeName := extractTypeFromRhs(rhs, parseResult, podNames)
      if (typeName == null) return
      out.add([
        "position": ["line": lineNo, "character": assignment],
        "label": ": $typeName",
        "kind": 1,
        "paddingLeft": false,
        "paddingRight": true,
      ])
    }
    return out
  }
}
