class FoldingRangeProvider
{
  [Str:Obj?][] ranges(ParseResult result)
  {
    out := [Str:Obj?][,]
    result.nodes.each |node| { add(node, out) }
    return out
  }

  private static Void add(AstNode node, [Str:Obj?][] out)
  {
    if ((node.isType || node.kind == AstNodeKind.methodDef || node.kind == AstNodeKind.ctorDef) &&
        node.range.end.line > node.range.start.line)
      out.add(["startLine": node.range.start.line, "endLine": node.range.end.line])
    node.children.each |child| { add(child, out) }
  }
}
