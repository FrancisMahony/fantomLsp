class DocumentLinkProvider
{
  [Str:Obj?][] links(DocumentState doc, ParseResult result, |Str->Str| clientUri := |Str key->Str| { UriKey.toClientUri(key) })
  {
    out := [Str:Obj?][,]
    result.nodes.each |node|
    {
      if (node.kind != AstNodeKind.usingDef) return
      colon := node.name.index("::")
      pod := colon == null ? node.name : node.name[0..<colon]
      type := colon == null ? null : node.name[colon + 2..-1]
      if (Pod.find(pod, false) == null) return
      f := type == null ? Env.cur.findFile(`src/${pod}/`, false) : Env.cur.findFile(`src/${pod}/fan/${type}.fan`, false)
      if (f == null || !f.exists) return
      out.add(["range": node.selectionRange.toMap, "target": clientUri(WorkspaceManager.fileToUri(f))])
    }
    return out
  }
}
