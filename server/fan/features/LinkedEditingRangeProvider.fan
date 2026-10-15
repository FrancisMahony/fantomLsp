class LinkedEditingRangeProvider
{
  [Str:Obj?]? ranges(DocumentState doc, Position pos, FantomLanguageServer server)
  {
    res := server.resolver.resolveAt(doc.uri, pos)
    if (res.certainty != Certainty.proven || res.targets.size != 1) return null
    target := res.targets.first
    file := UriKey.canonical(doc.uri)
    // Same-file audit only (see DocumentHighlightProvider).
    occurrences := server.resolver.references(target.key, true, false, file).occurrences.findAll |o| { o.fileKey == file }
    // Linked editing replaces identifier text, not semantic aliases such as
    // A() -> A.make. Refuse the set rather than corrupting a type spelling.
    if (occurrences.isEmpty || occurrences.any |o| { RenameProvider.textAt(doc, o.range) != target.name }) return null
    return ["ranges": occurrences.map |o->[Str:Obj?]| { o.range.toMap }]
  }
}
