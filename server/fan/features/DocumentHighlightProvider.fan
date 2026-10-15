class DocumentHighlightProvider
{
  ** Same-file occurrences only: the reference audit is scoped to this file,
  ** never the dependent workspace (a sys key would otherwise scan every pod).
  [Str:Obj?][] highlight(DocumentState doc, Position pos, FantomLanguageServer server)
  {
    result := [Str:Obj?][,]
    res := server.resolver.resolveAt(doc.uri, pos)
    if ((res.certainty != Certainty.proven && res.certainty != Certainty.unique) || res.targets.size != 1)
      return result
    file := UriKey.canonical(doc.uri)
    server.resolver.references(res.targets.first.key, true, false, file).occurrences.each |o|
    {
      if (o.fileKey == file) result.add(["range": o.range.toMap, "kind": 1])
    }
    return result
  }
}
