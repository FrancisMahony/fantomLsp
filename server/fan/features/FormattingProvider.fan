class FormattingProvider
{
  TextEdit[] onTypeCloseBrace(DocumentState doc, Int lineNum)
  {
    formatLine(doc, lineNum, [Str:Obj?][:])
  }

  TextEdit[] formatLine(DocumentState doc, Int lineNum, [Str:Obj?] opts)
  {
    lines := doc.text.splitLines
    if (lineNum < 0 || lineNum >= lines.size) return TextEdit[,]
    tabSize := ((Num?)opts["tabSize"])?.toInt ?: 2
    indent := (opts["insertSpaces"] as Bool ?: true) ? Str.spaces(tabSize) : "\t"
    stack := Int[,]
    lines[0..<lineNum].each |line| { applyDelimiters(line.trim, stack) }
    trimmed := lines[lineNum].trim
    depth := indentDepth(trimmed, stack)
    buf := StrBuf(); depth.times { buf.add(indent) }; buf.add(trimmed)
    text := buf.toStr
    if (text == lines[lineNum]) return TextEdit[,]
    return [TextEdit(LspRange(Position(lineNum, 0), Position(lineNum, lines[lineNum].size)), text)]
  }

  TextEdit[] format(DocumentState doc, [Str:Obj?] opts)
  {
    tabSize := ((Num?)opts["tabSize"])?.toInt ?: 2
    insertSpaces := opts["insertSpaces"] as Bool ?: true
    indent := insertSpaces ? Str.spaces(tabSize) : "\t"
    bracketStyle := opts["bracketStyle"] as Str ?: "allman"

    lines := doc.text.splitLines
    processedLines := normalizeBrackets(lines, bracketStyle)
    result := Str[,]
    stack := Int[,]

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

      depth := indentDepth(trimmed, stack)
      buf := StrBuf()
      depth.times { buf.add(indent) }
      buf.add(trimmed)
      formatted := buf.toStr
      result.add(formatted)
      applyDelimiters(trimmed, stack)

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

  ** Format the full document, then return a single TextEdit covering only
  ** the requested line range so range format does not rewrite the file.
  TextEdit[] formatRange(DocumentState doc, LspRange range, [Str:Obj?] opts)
  {
    full := format(doc, opts)
    if (full.isEmpty) return [,]
    formattedLines := full[0].newText.splitLines
    origLines := doc.text.splitLines
    start := range.start.line.max(0)
    end := range.end.line.max(start)
    if (start >= origLines.size) return [,]
    end = end.min(origLines.size - 1)
    sliceEnd := end.min(formattedLines.size - 1)
    if (start > sliceEnd) return [,]
    slice := formattedLines[start..sliceEnd].join("\n")
    editRange := LspRange(
      Position(start, 0),
      Position(end, origLines[end].size))
    return [TextEdit(editRange, slice)]
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
          if (!beforeBrace.isEmpty && beforeBrace[-1] != ',' && !isItBlock(beforeBrace))
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

  private Bool isItBlock(Str beforeBrace)
  {
    if (beforeBrace.isEmpty) return false
    if (beforeBrace[-1] == '|') return true
    pipe := beforeBrace.indexr("|")
    if (pipe == null) return false
    afterParen := beforeBrace.indexr(")")
    return afterParen != null && afterParen < pipe
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

  private Int indentDepth(Str trimmed, Int[] stack)
  {
    copy := stack.dup
    i := 0
    while (i < trimmed.size)
    {
      ch := trimmed[i]
      opener := matchingOpener(ch)
      if (opener == null) break
      if (!copy.isEmpty && copy.last == opener) copy.pop
      else break
      i++
    }
    n := 0
    copy.each |ch| { if (ch == '{') n++ }
    if (copy.any |ch| { ch == '(' }) n++
    if (copy.any |ch| { ch == '[' }) n++
    return n
  }

  private Void applyDelimiters(Str line, Int[] stack)
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
      if (!inStr && ch == '/' && i + 1 < line.size && line[i+1] == '/') break
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
        if (ch == '{' || ch == '[' || ch == '(') stack.push(ch)
        else
        {
          opener := matchingOpener(ch)
          if (opener != null && !stack.isEmpty && stack.last == opener) stack.pop
        }
      }
      i++
    }
  }

  private static Int? matchingOpener(Int closer)
  {
    if (closer == '}') return '{'
    if (closer == ']') return '['
    if (closer == ')') return '('
    return null
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
