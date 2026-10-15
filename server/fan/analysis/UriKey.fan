** Internal file identity, independent of the client's URI encoding.
class UriKey
{
  ** File paths are decoded except literal percent signs, which stay %25
  ** to distinguish a filename containing "%20" from one containing a space.
  static Str canonical(Str uri)
  {
    if (!uri.lower.startsWith("file:")) return uri
    path := decodePath(uri[5..-1].replace("\\", "/"))
    // A network authority must not become a local /server/share path.
    network := path.startsWith("//") && !path.startsWith("///")
    while (path.startsWith("/")) path = path[1..-1]
    if (network && !(path.size > 1 && path[0].isAlpha && path[1] == ':'))
      return "file://" + path.replace("%", "%25")
    if (path.size > 1 && path[0].isAlpha && path[1] == ':')
      path = path[0].lower.toChar + path[1..-1]
    return "file:///" + path.replace("%", "%25")
  }

  static Str toClientUri(Str key)
  {
    key = canonical(key)
    if (!key.startsWith("file:")) return key
    local := key.startsWith("file:///")
    offset := local ? 8 : 7
    path := decodePath(key[offset..-1])
    out := StrBuf().add(local ? "file:///" : "file://")
    bytes := path.toBuf
    while (bytes.remaining > 0)
    {
      ch := bytes.readU1
      if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
          (ch >= '0' && ch <= '9') || ch == '-' || ch == '.' ||
          ch == '_' || ch == '~' || ch == '/')
        out.addChar(ch)
      else
        out.add("%").add(ch.toHex(2).upper)
    }
    return out.toStr
  }

  ** Decode octets, not a URI: decoded spaces, Unicode, # and ? are legal.
  internal static Str decodePath(Str path)
  {
    out := StrBuf()
    i := 0
    while (i < path.size)
    {
      if (path[i] != '%' || i + 2 >= path.size ||
          !path[i+1].isDigit(16) || !path[i+2].isDigit(16))
      {
        out.addChar(path[i++])
        continue
      }
      bytes := Buf()
      start := i
      while (i + 2 < path.size && path[i] == '%' &&
             path[i+1].isDigit(16) && path[i+2].isDigit(16))
      {
        bytes.write(path[i+1..<i+3].toInt(16))
        i += 3
      }
      try { out.add(bytes.flip.readAllStr) }
      catch (Err e) { out.add(path[start..<i]) }
    }
    return out.toStr.replace("\\", "/")
  }
}
