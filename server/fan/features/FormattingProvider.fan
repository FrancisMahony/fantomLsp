class FormattingProvider
{
  TextEdit[] format(DocumentState doc, [Str:Obj?] opts)
  {
    tabSize := ((Num?)opts["tabSize"])?.toInt ?: 2
    insertSpaces := opts["insertSpaces"] as Bool ?: true
    indent := insertSpaces ? Str.spaces(tabSize) : "\t"

    lines := doc.text.splitLines
    result := Str[,]
    depth := 0

    lines.each |line|
    {
      trimmed := line.trim
      if (trimmed.isEmpty) { result.add(""); return }

      if (trimmed.startsWith("}") || trimmed == "}")
        depth = (depth - 1).max(0)

      buf := StrBuf()
      depth.times { buf.add(indent) }
      buf.add(trimmed)
      result.add(buf.toStr)

      opens := 0; closes := 0
      inStr := false; escaped := false
      trimmed.each |ch|
      {
        if (escaped) { escaped = false; return }
        if (ch == '\\') { escaped = true; return }
        if (ch == '"') { inStr = !inStr; return }
        if (inStr) return
        if (ch == '{') opens++
        else if (ch == '}') closes++
      }
      depth = (depth + opens - closes).max(0)
      if (trimmed.startsWith("}")) depth = (depth).max(0)
    }

    formatted := result.join("\n")
    fullRange := LspRange(Position(0, 0), Position(lines.size, 0))
    return [TextEdit(fullRange, formatted)]
  }
}
