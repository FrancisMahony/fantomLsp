** Symbol keys are strings, not wrapper objects. File keys are supplied by the
** caller; these helpers do not normalize URIs.
const class SymbolKey
{
  static Str typeKey(Str pod, Str name) { "${pod}::${name}" }
  static Str slotKey(Str typeKey, Str name) { "${typeKey}.${name}" }
  static Str localKey(Str fileKey, Position pos)
  {
    "local:${fileKey}#${pos.line}:${pos.character}"
  }
  static Str dynKey(Str name) { "dyn:${name}" }

  static Bool isLocal(Str key) { key.startsWith("local:") }
  static Bool isDyn(Str key) { key.startsWith("dyn:") }

  ** Locals and dynamic keys have no declaring pod or type.
  static Str? podOf(Str key)
  {
    if (isLocal(key) || isDyn(key)) return null
    sep := key.index("::")
    return sep == null ? null : key[0..<sep]
  }

  static Str? typeKeyOf(Str key)
  {
    if (podOf(key) == null) return null
    dot := key.index(".", key.index("::") + 2)
    return dot == null ? key : key[0..<dot]
  }

  ** A local key carries no identifier name, so return the key unchanged.
  ** Consumers must validate local identifier text through its declaration.
  static Str simpleName(Str key)
  {
    if (isLocal(key)) return key
    if (isDyn(key)) return key[4..-1]
    dot := key.indexr(".")
    if (dot != null) return key[dot+1..-1]
    sep := key.index("::")
    return sep == null ? key : key[sep+2..-1]
  }

  ** Parse the final position suffix; file keys themselves may contain '#'.
  ** Non-local or malformed keys return null.
  static Str? localFile(Str key)
  {
    if (localPosition(key) == null) return null
    return key[6..<key.indexr("#")]
  }

  static Position? localPosition(Str key)
  {
    if (!isLocal(key)) return null
    hash := key.indexr("#")
    if (hash == null || hash <= 6 || hash == key.size-1) return null
    parts := key[hash+1..-1].split(':', false)
    if (parts.size != 2 || parts.any |s| { s.isEmpty || !s.all |c| { c.isDigit } })
      return null
    line := parts[0].toInt(10, false)
    col := parts[1].toInt(10, false)
    if (line == null || col == null || line < 0 || col < 0) return null
    return Position(line, col)
  }
}

enum class OccKind
{
  call, field, type, local, ctorShorthand, slotLiteral, decl
}

const class Occurrence
{
  const Str fileKey
  const LspRange range
  const Str key
  const Str? altKey
  const OccKind kind
  const Str? enclosingSlotKey

  new make(Str fileKey, LspRange range, Str key, OccKind kind,
           Str? altKey := null, Str? enclosingSlotKey := null)
  {
    this.fileKey = fileKey; this.range = range; this.key = key
    this.kind = kind; this.altKey = altKey; this.enclosingSlotKey = enclosingSlotKey
  }
}

const class SymbolDecl
{
  const Str key
  const Str fileKey
  const LspRange nameRange
  const LspRange fullRange
  ** LSP SymbolKind, using DocumentSymbol constants.
  const Int kind
  const Str? signature
  const Str? doc
  const Str? parentTypeKey
  const Str[] superTypeKeys

  new make(Str key, Str fileKey, LspRange nameRange, LspRange fullRange, Int kind,
           Str? signature := null, Str? doc := null, Str? parentTypeKey := null,
           Str[] superTypeKeys := Str[,])
  {
    this.key = key; this.fileKey = fileKey
    this.nameRange = nameRange; this.fullRange = fullRange; this.kind = kind
    this.signature = signature; this.doc = doc; this.parentTypeKey = parentTypeKey
    this.superTypeKeys = superTypeKeys.toImmutable
  }
}

** Compact, deeply immutable compile output suitable for actor messages.
const class SemanticSnapshot
{
  const Str podName
  const Int generation
  const Str:Str fileHash
  const Str:Str openText
  const Str:Occurrence[] occByFile
  const Str:SymbolDecl decls
  const Str:Occurrence[] occByKey
  const Str[] parseFailedFiles
  const Bool resolved

  new make(Str podName, Int generation, Str:Str fileHash := Str:Str[:],
           Str:Str openText := Str:Str[:], Str:Occurrence[] occByFile := Str:Occurrence[][:],
           Str:SymbolDecl decls := Str:SymbolDecl[:],
           Str:Occurrence[] occByKey := Str:Occurrence[][:],
           Str[] parseFailedFiles := Str[,], Bool resolved := false)
  {
    this.podName = podName; this.generation = generation
    this.fileHash = fileHash.toImmutable; this.openText = openText.toImmutable
    // Sort copies, never the producer's lists, before freezing the whole map.
    sorted := Str:Occurrence[][:]
    occByFile.each |occs, file|
    {
      sorted[file] = occs.dup.sort |a, b -> Int|
      {
        n := a.range.start.line <=> b.range.start.line
        if (n != 0) return n
        return a.range.start.character <=> b.range.start.character
      }
    }
    this.occByFile = sorted.toImmutable
    this.decls = decls.toImmutable; this.occByKey = occByKey.toImmutable
    this.parseFailedFiles = parseFailedFiles.toImmutable; this.resolved = resolved
  }
}

** Unique is a single heuristic candidate, not sufficient proof for rename.
enum class Certainty
{
  proven, unique, ambiguous, none
}

const class SymbolTarget
{
  const Str key
  const Str name
  ** LSP SymbolKind, using DocumentSymbol constants.
  const Int kind
  const Str? fileKey
  const LspRange? range
  const Str? signature
  const Str? doc
  ** Origin: semantic, heuristic, or reflection.
  const Str source

  new make(Str key, Str name, Int kind, Str source,
           Str? fileKey := null, LspRange? range := null,
           Str? signature := null, Str? doc := null)
  {
    this.key = key; this.name = name; this.kind = kind; this.source = source
    this.fileKey = fileKey; this.range = range
    this.signature = signature; this.doc = doc
  }
}

const class Resolution
{
  const SymbolTarget[] targets
  const Certainty certainty
  const LspRange? occurrenceRange

  new make(SymbolTarget[] targets := SymbolTarget[,], Certainty certainty := Certainty.none,
           LspRange? occurrenceRange := null)
  {
    this.targets = targets.toImmutable; this.certainty = certainty
    this.occurrenceRange = occurrenceRange
  }
}

const class RefResult
{
  const Occurrence[] occurrences
  const Bool complete
  const Str[] uncoveredPods

  new make(Occurrence[] occurrences := Occurrence[,], Bool complete := false,
           Str[] uncoveredPods := Str[,])
  {
    this.occurrences = occurrences.toImmutable; this.complete = complete
    this.uncoveredPods = uncoveredPods.toImmutable
  }
}
