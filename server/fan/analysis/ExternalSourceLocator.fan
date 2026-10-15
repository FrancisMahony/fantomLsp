** Installed-source navigation. The file resolver also permits callers to use
** their current pod lookup without loading/caching a pod in JVM reflection.
class ExternalSourceLocator
{
  private |Str->File?| podFile
  private File tempRoot
  private File home
  private |Uri->File?| envFile

  new make(|Str->File?|? podFile := null, File? tempRoot := null,
           File? home := null, |Uri->File?|? envFile := null)
  {
    this.podFile = podFile ?: |Str name->File?| { Env.cur.findPodFile(name) }
    this.tempRoot = tempRoot ?: Env.cur.tempDir + `fantomLsp-src/`
    this.home = home ?: Env.cur.homeDir
    this.envFile = envFile ?: |Uri uri->File?| { Env.cur.findFile(uri, false) }
  }

  ** Returns [File, LspRange], or null; coordinates are zero-based.
  Obj[]? locateInstalled(Str key)
  {
    pod := SymbolKey.podOf(key)
    typeKey := SymbolKey.typeKeyOf(key)
    if (pod == null || typeKey == null) return null
    type := SymbolKey.simpleName(typeKey)
    slot := key == typeKey ? null : SymbolKey.simpleName(key)
    if (!identifier(pod) || !identifier(type) || (slot != null && !identifier(slot)))
      return null
    if (key != "${pod}::${type}" && key != "${pod}::${type}.${slot}") return null

    Zip? zip := null
    try
    {
      file := podFile(pod)
      if (file == null || !file.exists) return null
      zip = Zip.open(file)
      entries := (Uri:File)zip.contents
      version := entries[`/meta.props`]?.readProps?.get("pod.version") ?: "unknown"
      if (!version.all |c| { c.isAlphaNum || c == '.' || c == '-' || c == '_' }) return null
      doc := entries[Uri.fromStr("/doc/${type}.apidoc")]
      if (doc != null)
      {
        loc := parseApiDoc(doc.readAllStr, type, slot)
        if (loc == null) return null
        src := sourceFile(entries, pod, version, loc.file)
        if (src == null) return null
        range := identifierRange(src.readAllStr, slot ?: type, loc.line - 1)
        return range == null ? null : Obj[src, range]
      }
      return fallback(entries, pod, version, type, slot)
    }
    catch (Err e) { return null }
    finally { zip?.close }
  }

  ** Read only attributes before each block's doc text. Older writers prefix
  ** slot line numbers with ':'; accept both that and the documented form.
  internal static ExternalSourceLoc? parseApiDoc(Str text, Str type, Str? slot := null)
  {
    Str? file := null
    Int? typeLine := null
    Int? slotLine := null
    Str? block := null
    inType := false
    attrs := false
    text.splitLines.each |raw|
    {
      line := raw.trim
      if (line.startsWith("== "))
      {
        inType = line[3..-1].trim == type
        block = inType ? type : null
        attrs = inType
      }
      else if (line.startsWith("-- "))
      {
        name := StrBuf()
        rest := line[3..-1]
        for (i := 0; i < rest.size && identChar(rest[i]); i++) name.addChar(rest[i])
        block = name.toStr
        attrs = inType
      }
      else if (line.isEmpty) attrs = false
      else if (attrs && line.startsWith("loc="))
      {
        value := line[4..-1].split('/')[0]
        if (block == type && file == null)
        {
          colon := value.indexr(":")
          if (colon != null && colon > 0)
          {
            file = value[0..<colon]
            typeLine = positiveLine(value[colon+1..-1])
          }
        }
        else if (slot != null && block == slot)
          slotLine = positiveLine(value.startsWith(":") ? value[1..-1] : value)
      }
    }
    line := slot == null ? typeLine : slotLine
    if (file == null || line == null || !sourceName(file)) return null
    return ExternalSourceLoc(file, line)
  }

  private static Int? positiveLine(Str s)
  {
    n := s.toInt(10, false)
    return n != null && n > 0 ? n : null
  }

  private File? sourceFile(Uri:File entries, Str pod, Str version, Str name)
  {
    if (!sourceName(name)) return null
    packed := entries[Uri.fromStr("/src/${name}")]
    if (packed != null) return extract(packed, pod, version, name)
    rel := Uri.fromStr("src/${pod}/")
    found := namedFiles(home + rel, name)
    if (!found.isEmpty) return found.size == 1 ? found.first : null
    root := envFile(rel)
    found = root == null ? File[,] : namedFiles(root, name)
    return found.size == 1 ? found.first : null
  }

  private File extract(File packed, Str pod, Str version, Str name)
  {
    dir := tempRoot + Uri.fromStr("${pod}-${version}/")
    dir.create
    dest := dir + Uri.fromStr(name)
    if (!dest.exists) packed.copyTo(dest)
    return dest
  }

  private static File[] namedFiles(File root, Str name)
  {
    files := sourceFiles(root)
    return files.findAll |f| { f.name == name }
  }

  private static File[] sourceFiles(File root)
  {
    files := File[,]
    if (root.exists && root.isDir)
      root.walk |f| { if (!f.isDir && f.ext == "fan") files.add(f) }
    return files.sort |a, b->Int| { a.uri.toStr <=> b.uri.toStr }
  }

  ** Parse only src/ in this archive and src/<this pod>/ in installed roots.
  ** Duplicate declarations are not evidence for a single arbitrary jump.
  private Obj[]? fallback(Uri:File entries, Str pod, Str version, Str type, Str? slot)
  {
    files := File[,]
    names := Str[,]
    entries.each |f, uri|
    {
      s := uri.toStr
      if (s.startsWith("/src/") && sourceName(s[5..-1])) names.add(s[5..-1])
    }
    names.sort.each |name| { files.add(extract(entries[Uri.fromStr("/src/${name}")], pod, version, name)) }
    rel := Uri.fromStr("src/${pod}/")
    // Archive copies shadow installed copies of the same source file.
    sourceFiles(home + rel).each |f| { if (!names.contains(f.name)) files.add(f) }
    envRoot := envFile(rel)
    if (envRoot != null)
      sourceFiles(envRoot).each |f|
      {
        fileKey := UriKey.canonical(f.normalize.uri.toStr)
        if (!names.contains(f.name) && !files.any |other|
          { UriKey.canonical(other.normalize.uri.toStr) == fileKey }) files.add(f)
      }
    Obj[]? result := null
    matches := 0
    files.each |f|
    {
      text := f.readAllStr
      parsed := RecoveringParser().parse(UriKey.canonical(f.uri.toStr), text)
      parsed.nodes.findAll |n| { n.isType && n.name == type }.each |n|
      {
        target := slot == null ? n : n.children.find |c| { c.isSlotOrEnumVal && c.name == slot }
        if (target == null) return
        pos := target.selectionRange.start
        range := identifierRange(text, slot ?: type, pos.line, pos.character)
        if (range == null) return
        matches++
        result = Obj[f, range]
      }
    }
    return matches == 1 ? result : null
  }

  ** Exactly 20 lines including the starting line. Lex from the start of the
  ** file so a comment/string opened before the location stays masked.
  internal static LspRange? identifierRange(Str text, Str name, Int startLine, Int startCol := 0)
  {
    if (startLine < 0 || !identifier(name)) return null
    lines := text.splitLines
    blockDepth := 0
    quote := 0
    triple := false
    for (lineNo := 0; lineNo < lines.size && lineNo < startLine + 20; lineNo++)
    {
      line := lines[lineNo]
      if (blockDepth == 0 && quote == 0 && line.trimStart.startsWith("**")) continue
      i := 0
      while (i < line.size)
      {
        ch := line[i]
        next := i + 1 < line.size ? line[i+1] : 0
        if (blockDepth > 0)
        {
          if (ch == '/' && next == '*') { blockDepth++; i += 2 }
          else if (ch == '*' && next == '/') { blockDepth--; i += 2 }
          else i++
          continue
        }
        if (quote != 0)
        {
          if (ch == '\\') { i += 2; continue }
          if (triple)
          {
            if (ch == '"' && next == '"' && i + 2 < line.size && line[i+2] == '"')
            { quote = 0; triple = false; i += 3 }
            else i++
          }
          else { if (ch == quote) quote = 0; i++ }
          continue
        }
        if (ch == '/' && next == '/') break
        if (ch == '/' && next == '*') { blockDepth = 1; i += 2; continue }
        if (ch == '"' || ch == '\'' || ch == '`')
        {
          quote = ch
          triple = ch == '"' && next == '"' && i + 2 < line.size && line[i+2] == '"'
          i += triple ? 3 : 1
          continue
        }
        if (identChar(ch))
        {
          begin := i++
          while (i < line.size && identChar(line[i])) i++
          if (lineNo >= startLine && (lineNo != startLine || begin >= startCol) && line[begin..<i] == name)
            return LspRange(Position(lineNo, begin), Position(lineNo, i))
        }
        else i++
      }
    }
    return null
  }

  private static Bool identChar(Int c) { c.isAlphaNum || c == '_' || c == '$' }
  private static Bool identifier(Str s)
  {
    !s.isEmpty && (s[0].isAlpha || s[0] == '_') && s.all |c| { c.isAlphaNum || c == '_' }
  }
  private static Bool sourceName(Str s)
  {
    // Upstream embeds file.name, not paths. Reject traversal/absolute paths.
    !s.isEmpty && s.endsWith(".fan") && !s.contains("/") && !s.contains("\\") &&
      !s.contains(":") && !s.contains("..") && !s.contains("?") && !s.contains("#") && !s.contains("%")
  }
}

internal const class ExternalSourceLoc
{
  const Str file
  const Int line
  new make(Str file, Int line) { this.file = file; this.line = line }
}
