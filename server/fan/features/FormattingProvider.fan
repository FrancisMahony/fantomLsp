class FormattingProvider
{
  TextEdit[] format(DocumentState doc, [Str:Obj?] opts)
  {
    tabSize := ((Num?)opts["tabSize"])?.toInt ?: 2
    insertSpaces := opts["insertSpaces"] as Bool ?: true
    indent := insertSpaces ? Str.spaces(tabSize) : "\t"
    bracketStyle := opts["bracketStyle"] as Str ?: "allman"

    lines := doc.text.splitLines
    processedLines := normalizeBrackets(lines, bracketStyle)
    result := Str[,]
    depth := 0

    inTripleQuote := false
    tripleQuoteCol := 0

    processedLines.each |line|
    {
      trimmed := line.trim
      if (trimmed.isEmpty)
      {
        result.add("")
        return
      }

      // Lines inside a triple-quoted string
      if (inTripleQuote)
      {
        buf := StrBuf()
        tripleQuoteCol.times { buf.addChar(' ') }
        buf.add(trimmed)
        result.add(buf.toStr)
        closeIdx := findTripleQuote(trimmed, 0)
        if (closeIdx != null)
          inTripleQuote = false
        return
      }

      if (trimmed.startsWith("}") || trimmed.startsWith("]"))
        depth = (depth - 1).max(0)

      buf := StrBuf()
      depth.times { buf.add(indent) }
      buf.add(trimmed)
      formatted := buf.toStr
      result.add(formatted)

      braces := countBracesOutsideStrings(trimmed)
      closesAdj := braces["closes"]
      if (trimmed.startsWith("}") || trimmed.startsWith("]"))
        closesAdj = (closesAdj - 1).max(0)
      depth = (depth + braces["opens"] - closesAdj).max(0)

      // Check if this line opens a triple-quoted string
      openIdx := findTripleQuote(formatted, 0)
      if (openIdx != null)
      {
        // Check for closing triple-quote on the same line
        closeIdx := findTripleQuote(formatted, openIdx + 3)
        if (closeIdx == null)
        {
          inTripleQuote = true
          tripleQuoteCol = openIdx + 3
        }
      }
    }

    formatted := result.join("\n")
    fullRange := LspRange(Position(0, 0), Position(lines.size, 0))
    return [TextEdit(fullRange, formatted)]
  }

  private Str[] normalizeBrackets(Str[] lines, Str style)
  {
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
    inTriple := false
    escaped := false
    i := 0
    while (i < line.size)
    {
      ch := line[i]
      if (inTriple)
      {
        if (i + 2 < line.size && ch == '"' && line[i+1] == '"' && line[i+2] == '"')
        {
          inTriple = false
          i += 3
          continue
        }
        i++
        continue
      }
      if (escaped) { escaped = false; i++; continue }
      if (ch == '\\') { escaped = true; i++; continue }
      if (ch == '"')
      {
        if (i + 2 < line.size && line[i+1] == '"' && line[i+2] == '"')
        {
          inTriple = true
          i += 3
          continue
        }
        inStr = !inStr
      }
      i++
    }
    return inStr || inTriple
  }

  private [Str:Int] countBracesOutsideStrings(Str line)
  {
    opens := 0
    closes := 0
    inStr := false
    inTriple := false
    escaped := false
    i := 0
    while (i < line.size)
    {
      ch := line[i]
      if (inTriple)
      {
        if (i + 2 < line.size && ch == '"' && line[i+1] == '"' && line[i+2] == '"')
        {
          inTriple = false
          i += 3
          continue
        }
        i++
        continue
      }
      if (escaped) { escaped = false; i++; continue }
      if (ch == '\\') { escaped = true; i++; continue }
      if (ch == '"')
      {
        if (i + 2 < line.size && line[i+1] == '"' && line[i+2] == '"')
        {
          inTriple = true
          i += 3
          continue
        }
        inStr = !inStr
        i++
        continue
      }
      if (!inStr)
      {
        if (ch == '{' || ch == '[') opens++
        else if (ch == '}' || ch == ']') closes++
      }
      i++
    }
    return ["opens": opens, "closes": closes]
  }

  ** Find the index of the first triple-quote starting at or after 'from'.
  ** Returns null if not found.
  private Int? findTripleQuote(Str line, Int from)
  {
    i := from
    while (i + 2 < line.size)
    {
      if (line[i] == '"' && line[i+1] == '"' && line[i+2] == '"')
        return i
      i++
    }
    return null
  }
}
