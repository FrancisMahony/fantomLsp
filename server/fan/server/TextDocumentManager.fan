**
** Open-document buffers keyed by canonical URI.
**
** Main (dispatch) thread only: this class, `DocumentState` and the
** cached `ParseResult`s are not thread-safe and must never be read or written
** by background actors. Background work receives immutable copies of the text
** (`CompileRequest`) instead.
**
class TextDocumentManager
{
  private Str:DocumentState documents := [:]

  Void open(TextDocumentItem item)
  {
    key := UriKey.canonical(item.uri)
    doc := DocumentState(key, item.version, item.text)
    doc.originalUri = item.uri
    documents[key] = doc
  }

  Void change(Str uri, Int version, TextDocumentContentChangeEvent evt)
  {
    doc := documents[UriKey.canonical(uri)]
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
    documents.remove(UriKey.canonical(uri))
  }

  Void updateText(Str uri, Str text)
  {
    doc := documents[UriKey.canonical(uri)]
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
    documents[UriKey.canonical(uri)]
  }

  ParseResult parseDocument(Str uri)
  {
    uri = UriKey.canonical(uri)
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
    eol := lineEnding(text)
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

    return result.join(eol)
  }

  ** Split on \\n / \\r\\n without dropping a trailing empty line after a terminator.
  internal static Str[] toLines(Str text)
  {
    result := Str[,]
    cur := StrBuf()
    i := 0
    while (i < text.size)
    {
      ch := text[i]
      if (ch == '\r')
      {
        result.add(cur.toStr)
        cur = StrBuf()
        i++
        if (i < text.size && text[i] == '\n') i++
      }
      else if (ch == '\n')
      {
        result.add(cur.toStr)
        cur = StrBuf()
        i++
      }
      else
      {
        cur.addChar(ch)
        i++
      }
    }
    result.add(cur.toStr)
    return result
  }

  internal static Str lineEnding(Str text)
  {
    text.contains("\r\n") ? "\r\n" : "\n"
  }
}

class DocumentState
{
  Str uri
  Str originalUri
  Int version
  Str text
  Bool dirty := true
  ParseResult? cachedParse

  new make(Str uri, Int version, Str text)
  {
    this.uri = uri
    this.originalUri = uri
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
    if (pos.character < 0 || pos.character > line.size) return ""
    start := pos.character
    end := pos.character

    while (start > 0 && isIdentChar(line[start - 1])) start--
    while (end < line.size && isIdentChar(line[end])) end++

    if (start >= end) return ""
    if (end + 2 < line.size && line[end..<end+2] == "::" && isIdentChar(line[end+2]))
    {
      end += 2
      while (end < line.size && isIdentChar(line[end])) end++
    }
    if (start >= 3 && line[start-2..<start] == "::" && isIdentChar(line[start-3]))
    {
      start -= 2
      while (start > 0 && isIdentChar(line[start-1])) start--
    }
    return line[start..<end]
  }

  Int offsetAt(Position pos)
  {
    eolLen := TextDocumentManager.lineEnding(text).size
    ls := lines
    offset := 0
    for (i := 0; i < pos.line && i < ls.size; i++)
      offset += ls[i].size + eolLen
    if (pos.line < ls.size)
      offset += pos.character.min(ls[pos.line].size)
    return offset
  }

  private static Bool isIdentChar(Int ch)
  {
    ch.isAlphaNum || ch == '_'
  }
}
