class HoverProvider : LspUtils
{
  [Str:Obj?]? hover(DocumentState doc, ParseResult parsed, Position pos, FantomLanguageServer server)
  {
    res := server.resolver.resolveAt(doc.uri, pos)
    t := res.targets.first
    if (t == null) return null
    sig := server.resolver.signatureOf(t.key) ?: t.signature
    if (sig == null) return null
    if (SymbolKey.isLocal(t.key))
    {
      // Semantic metadata is just the CType; heuristic metadata has the name.
      if (sig != t.name && !sig.endsWith(" " + t.name)) sig += " " + t.name
      local := findEnclosingLocal(parsed, t.name, pos)
      // A bare name has no type metadata. Never replace a resolver-provided
      // type (especially the compiler's inferred CType) with RHS heuristics.
      if (sig == t.name && local != null && local.typeName == null)
      {
        line := doc.getLine(local.selectionRange.start.line) ?: ""
        idx := line.index(":=")
        inferred := idx == null ? null : extractTypeFromRhs(line[idx+2..-1].trim, parsed, extractUsings(parsed))
        if (inferred != null) sig = "${inferred} ${t.name}"
      }
    }
    md := StrBuf().add("```fantom\n").add(sig).add("\n```")
    parent := SymbolKey.typeKeyOf(t.key)
    if (!SymbolKey.isLocal(t.key) && parent != null && parent != t.key)
      md.add("\n\n*").add(parent).add("*")
    if (res.certainty == Certainty.ambiguous)
      md.add("\n\n(+").add((res.targets.size-1).max(0)).add(" other candidates)")
    text := server.resolver.docOf(t.key) ?: t.doc
    if (text != null) md.add("\n\n---\n\n").add(text)
    return ["contents": ["kind": "markdown", "value": md.toStr]]
  }
}
