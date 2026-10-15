class ReferencesProvider
{
  Obj? references(DocumentState doc, Position pos, FantomLanguageServer server, Bool includeDecl := false)
  {
    res := server.resolver.resolveAt(doc.uri, pos)
    if ((res.certainty != Certainty.proven && res.certainty != Certainty.unique) || res.targets.size != 1)
      return null
    // Incomplete results are useful for navigation; only rename requires coverage.
    refs := server.resolver.references(res.targets.first.key, includeDecl, false)
    locations := [Str:Obj?][,]
    refs.occurrences.each |o|
    {
      locations.add(Location(server.clientUri(o.fileKey), o.range).toMap)
    }
    return locations.isEmpty ? null : locations
  }
}
