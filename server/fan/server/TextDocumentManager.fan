class TextDocumentManager
{
  private Str:DocumentState documents := [:]

  Void open(TextDocumentItem item)
  {
    documents[item.uri] = DocumentState(item.uri, item.version, item.text)
  }

  Void change(Str uri, Int version, TextDocumentContentChangeEvent evt)
  {
    doc := documents[uri]
    if (doc == null) return

    if (evt.range == null)
    {
      doc.text = evt.text
    }
    else
    {
      doc.text = applyEdit(doc.text, evt.range, evt.text)
    }
    doc.version = version
    doc.dirty = true
  }

  Void close(Str uri)
  {
    documents.remove(uri)
  }

  Void updateText(Str uri, Str text)
  {
    doc := documents[uri]
    if (doc != null)
    {
      doc.text = text
      doc.dirty = true
    }
  }

  Str[] openUris()
  {
    documents.keys.dup
  }

  DocumentState? getDocument(Str uri)
  {
    documents[uri]
  }

  ParseResult parseDocument(Str uri)
  {
    doc := documents[uri]
    if (doc == null) return ParseResult.empty

    if (!doc.dirty && doc.cachedParse != null)
      return doc.cachedParse

    parser := RecoveringParser()
    result := parser.parse(uri, doc.text)
    doc.cachedParse = result
    doc.dirty = false
    return result
  }

  private Str applyEdit(Str text, LspRange range, Str newText)
  {
    lines := toLines(text)

    startLine := range.start.line
    startChar := range.start.character
    endLine := range.end.line
    endChar := range.end.character

    if (startLine >= lines.size) return text

    prefix := ""
    if (startLine < lines.size)
      prefix = lines[startLine][0..<startChar.min(lines[startLine].size)]

    suffix := ""
    if (endLine < lines.size)
      suffix = lines[endLine][endChar.min(lines[endLine].size)..-1]

    before := lines[0..<startLine]
    after := endLine + 1 < lines.size ? lines[endLine+1..-1] : Str[,]

    middle := prefix + newText + suffix
    middleLines := toLines(middle)

    result := Str[,]
    result.addAll(before)
    result.addAll(middleLines)
    result.addAll(after)

    return joinLines(result)
  }

  private Str[] toLines(Str text)
  {
    result := Str[,]
    cur := StrBuf()
    text.each |ch|
    {
      if (ch == '\n')
      {
        result.add(cur.toStr)
        cur = StrBuf()
      }
      else if (ch != '\r')
      {
        cur.addChar(ch)
      }
    }
    result.add(cur.toStr)
    return result
  }

  private Str joinLines(Str[] lines)
  {
    lines.join("\n")
  }
}

class DocumentState
{
  Str uri
  Int version
  Str text
  Bool dirty := true
  ParseResult? cachedParse

  new make(Str uri, Int version, Str text)
  {
    this.uri = uri
    this.version = version
    this.text = text
  }

  Str[] lines() { text.splitLines }

  Str? getLine(Int line)
  {
    ls := lines
    if (line < 0 || line >= ls.size) return null
    return ls[line]
  }

  Str getWordAt(Position pos)
  {
    line := getLine(pos.line) ?: ""
    start := pos.character
    end := pos.character

    while (start > 0 && isIdentChar(line[start - 1])) start--
    while (end < line.size && isIdentChar(line[end])) end++

    if (start >= end) return ""
    return line[start..<end]
  }

  Int offsetAt(Position pos)
  {
    ls := lines
    offset := 0
    for (i := 0; i < pos.line && i < ls.size; i++)
      offset += ls[i].size + 1
    if (pos.line < ls.size)
      offset += pos.character.min(ls[pos.line].size)
    return offset
  }

  private static Bool isIdentChar(Int ch)
  {
    ch.isAlphaNum || ch == '_'
  }
}
