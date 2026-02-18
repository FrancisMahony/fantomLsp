using util

class JsonRpc
{
  private InStream inStream
  private OutStream outStream

  new make(InStream inStream, OutStream outStream)
  {
    this.inStream = inStream
    this.outStream = outStream
  }

  [Str:Obj?]? readMessage()
  {
    headers := readHeaders
    if (headers == null) return null

    contentLen := headers["Content-Length"]
    if (contentLen == null)
    {
      Env.cur.err.printLine("[fantomLsp] Missing Content-Length header")
      return null
    }

    len := Int.fromStr(contentLen)
    buf := Buf(len)
    total := 0
    while (total < len)
    {
      read := inStream.readBuf(buf, len - total)
      if (read == null) return null
      total += read
    }
    buf.flip

    json := buf.readAllStr
    Env.cur.err.printLine("[fantomLsp] << $json")

    return JsonInStream(json.in).readJson as [Str:Obj?]
  }

  Void writeMessage([Str:Obj?] msg)
  {
    buf := Buf()
    JsonOutStream(buf.out).writeJson(msg)
    body := buf.flip.readAllStr

    Env.cur.err.printLine("[fantomLsp] >> $body")

    bodyBytes := Buf().print(body)
    header := "Content-Length: ${bodyBytes.size}\r\n\r\n"
    outStream.print(header)
    outStream.writeBuf(bodyBytes.flip)
    outStream.flush
  }

  private [Str:Str]? readHeaders()
  {
    headers := Str:Str[:]
    while (true)
    {
      line := readLine
      if (line == null) return null
      if (line.isEmpty) break
      colon := line.index(":")
      if (colon != null)
      {
        key := line[0..<colon].trim
        val := line[colon+1..-1].trim
        headers[key] = val
      }
    }
    if (headers.isEmpty) return null
    return headers
  }

  private Str? readLine()
  {
    buf := StrBuf()
    while (true)
    {
      ch := inStream.read
      if (ch == null) return null
      if (ch == '\r')
      {
        next := inStream.read
        if (next == '\n') return buf.toStr
        buf.addChar(ch)
        if (next != null) buf.addChar(next)
      }
      else if (ch == '\n')
      {
        return buf.toStr
      }
      else
      {
        buf.addChar(ch)
      }
    }
    return buf.toStr
  }
}
