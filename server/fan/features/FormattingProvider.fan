class FormattingProvider
{
  TextEdit[] format(DocumentState doc, [Str:Obj?] opts)
  {
    tabSize := ((Num?)opts["tabSize"])?.toInt ?: 2
    insertSpaces := opts["insertSpaces"] as Bool ?: true
    indent := insertSpaces ? Str.spaces(tabSize) : "\t"
    bracketStyle := opts["bracketStyle"] as Str ?: "preserve"

    lines := doc.text.splitLines
    processedLines := normalizeBrackets(lines, bracketStyle)
    result := Str[,]
    depth := 0

    processedLines.each |line|
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

  private Str[] normalizeBrackets(Str[] lines, Str style)
  {
    if (style == "preserve") return lines

    result := Str[,]
    i := 0
    while (i < lines.size)
    {
      line := lines[i]
      trimmed := line.trim

      if (trimmed.isEmpty || trimmed.startsWith("//"))
      {
        result.add(line)
        i++
        continue
      }

      if (isInString(trimmed))
      {
        result.add(line)
        i++
        continue
      }

      if (style == "allman")
      {
        if (trimmed.endsWith("{") && trimmed.size > 1 && !trimmed.endsWith("{{"))
        {
          beforeBrace := trimmed[0..-2].trim
          if (!beforeBrace.isEmpty && beforeBrace[-1] != ',')
          {
            result.add(beforeBrace)
            result.add("{")
            i++
            continue
          }
        }
      }
      else if (style == "k&r" || style == "knr")
      {
        if (trimmed == "{" && i > 0)
        {
          prevIdx := result.size - 1
          if (prevIdx >= 0)
          {
            prev := result[prevIdx].trim
            if (!prev.isEmpty && !prev.startsWith("//") &&
                !prev.endsWith("{") && !prev.endsWith(","))
            {
              result[prevIdx] = prev + " {"
              i++
              continue
            }
          }
        }
      }

      result.add(line)
      i++
    }
    return result
  }

  private Bool isInString(Str line)
  {
    inStr := false
    escaped := false
    line.each |ch|
    {
      if (escaped) { escaped = false; return }
      if (ch == '\\') { escaped = true; return }
      if (ch == '"') inStr = !inStr
    }
    return inStr
  }
}
