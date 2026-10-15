using util
using concurrent

class JsonRpc
{
  private InStream inStream
  private OutStream? outStream
  private StdioWriteActor? writeActor

  new make(InStream inStream, Obj out)
  {
    this.inStream = inStream
    if (out is StdioWriteActor)
      this.writeActor = out
    else
      this.outStream = out
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

    return JsonInStream(json.in).readJson as [Str:Obj?]
  }

  Void writeMessage([Str:Obj?] msg)
  {
    if (writeActor != null)
    {
      writeActor.send(msg).get
      return
    }
    writeFrame(outStream, msg)
  }

  ** Pure: encode a message as its JSON body (immutable, safe to send to actors).
  static Str encode([Str:Obj?] msg)
  {
    buf := Buf()
    JsonOutStream(buf.out).writeJson(msg)
    return buf.flip.readAllStr
  }

  static Void writeFrame(OutStream out, [Str:Obj?] msg)
  {
    writeBody(out, encode(msg))
  }

  ** Write one Content-Length framed message whose JSON body is already encoded.
  static Void writeBody(OutStream out, Str body)
  {
    bodyBytes := Buf().print(body)
    header := "Content-Length: ${bodyBytes.size}\r\n\r\n"
    out.print(header)
    out.writeBuf(bodyBytes.flip)
    out.flush
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

const class StdioWriteActor : Actor
{
  private const Unsafe outRef

  new make(ActorPool pool, OutStream out) : super(pool)
  {
    this.outRef = Unsafe(out)
  }

  ** Accepts an encoded JSON body (`Str`, preferred: immutable) or a message map.
  ** Any other message (e.g. null) is a no-op, so `send(null).get` acts as a flush.
  override Obj? receive(Obj? msg)
  {
    try
    {
      if (msg is Str) JsonRpc.writeBody((OutStream)outRef.val, msg)
      else if (msg is Map) JsonRpc.writeFrame((OutStream)outRef.val, msg)
    }
    catch (Err e)
    {
      Env.cur.err.printLine("[fantomLsp] Write failed: $e.msg")
    }
    return null
  }
}
