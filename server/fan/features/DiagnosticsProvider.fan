using compiler

**
** Parser and compiler diagnostics.
**
** Thread affinity (plan 7.3 / 7.12.9):
**   - `computeParserDiagnosticsFor` and the static `compilerDiagnosticsFor` are pure:
**     they read only their arguments and may run on any thread.
**   - Everything that reads `docManager` or the compiler-diagnostics cache is
**     main (dispatch) thread only.
**
class DiagnosticsProvider
{
  TextDocumentManager? docManager

  ** Main thread only: canonical key -> latest accepted compiler diagnostics, kept in
  ** the coordinates of the current buffer by `adjustCompilerDiagnostics`.
  private Str:Diagnostic[] compilerCache := [:]

  new make(TextDocumentManager? docManager := null)
  {
    this.docManager = docManager
  }

  private CodeActionProvider codeActions := CodeActionProvider()

  ** Main thread: resolves the document through `docManager`.
  Diagnostic[] computeParserDiagnostics(Str uri, ParseResult result)
  {
    doc := docManager?.getDocument(uri)
    if (doc == null) return syntaxDiagnostics(result)
    return computeParserDiagnosticsFor(doc, result)
  }

  ** Pure: parser errors plus unused-using/unused-local warnings for `doc`.
  Diagnostic[] computeParserDiagnosticsFor(DocumentState doc, ParseResult result)
  {
    diags := syntaxDiagnostics(result)
    codeActions.findUnusedUsings(doc, result).each |node|
    {
      diags.add(Diagnostic(node.range, Diagnostic.warning, "Unused using '${node.name}'", "fantomLsp"))
    }
    addUnusedLocals(diags, doc, result)
    return diags
  }

  private static Diagnostic[] syntaxDiagnostics(ParseResult result)
  {
    result.errors.map |err->Diagnostic|
    {
      Diagnostic(err.range, Diagnostic.error, err.message, "fantomLsp")
    }
  }

  private Void addUnusedLocals(Diagnostic[] diags, DocumentState doc, ParseResult result)
  {
    result.nodes.each |n| { walkUnused(diags, doc, n) }
  }

  private Void walkUnused(Diagnostic[] diags, DocumentState doc, AstNode node)
  {
    if (node.kind === AstNodeKind.methodDef || node.kind === AstNodeKind.ctorDef)
      flagUnusedInMethod(diags, doc, node)
    node.children.each |c| { walkUnused(diags, doc, c) }
  }

  private Void flagUnusedInMethod(Diagnostic[] diags, DocumentState doc, AstNode method)
  {
    if (method.range.start.line == method.range.end.line) return
    lines := doc.text.splitLines
    start := method.range.start.line
    end := method.range.end.line.min(lines.size - 1)
    method.children.each |child|
    {
      if (child.kind !== AstNodeKind.localDef) return
      name := child.name
      if (name.isEmpty || !name[0].isLower) return
      if (name == "it" || name == "super" || name == "this") return
      defLine := child.range.start.line
      used := false
      i := start
      while (i <= end)
      {
        if (identUsed(lines[i], name, i == defLine))
        {
          used = true
          break
        }
        i++
      }
      if (!used)
        diags.add(Diagnostic(child.range, Diagnostic.warning, "Unused local '${name}'", "fantomLsp"))
    }
  }

  private static Bool identUsed(Str line, Str name, Bool skipFirst)
  {
    from := 0
    first := true
    while (true)
    {
      idx := line.index(name, from)
      if (idx == null) return false
      beforeOk := idx == 0 || !isIdentChar(line[idx - 1])
      after := idx + name.size
      afterOk := after >= line.size || !isIdentChar(line[after])
      if (beforeOk && afterOk)
      {
        if (!(skipFirst && first)) return true
        first = false
      }
      from = idx + 1
    }
    return false
  }

  private static Bool isIdentChar(Int ch)
  {
    ch.isAlphaNum || ch == '_'
  }

  Diagnostic[] computeDiagnostics(Str uri, ParseResult result)
  {
    computeParserDiagnostics(uri, result)
  }

  ** Main thread, synchronous compile of the open buffer (legacy/test path).
  Diagnostic[] computeCompilerDiagnostics(Str uri)
  {
    doc := docManager?.getDocument(uri)
    if (doc == null) return Diagnostic[,]
    errs := CompilerDiagnostics().compileAndGetErrors(uri, doc.text)
    return compilerDiagnosticsFor(doc.text, errs)
  }

  Diagnostic[] computeAllDiagnostics(Str uri, ParseResult result)
  {
    diags := computeParserDiagnostics(uri, result)
    diags.addAll(computeCompilerDiagnostics(uri))
    return diags
  }

  ** Pure: convert compiler errors into diagnostics in the coordinates of `text`.
  static Diagnostic[] compilerDiagnosticsFor(Str text, CompilerErr[] errs)
  {
    lines := TextDocumentManager.toLines(text)
    return errs.map |err->Diagnostic|
    {
      line := ((err.line ?: 1) - 1).max(0)
      // Compiler Loc columns, like lines, are one-based.
      col := ((err.col ?: 1) - 1).max(0)
      lineText := line < lines.size ? lines[line] : ""
      range := LspRange(Position(line, col), Position(line, wordEnd(lineText, col)))
      return Diagnostic(range, Diagnostic.error, err.msg, "fantomCompiler")
    }
  }

  private static Int wordEnd(Str text, Int col)
  {
    i := col.min(text.size)
    while (i < text.size && (text[i].isAlphaNum || text[i] == '_')) i++
    if (i == col) return (col + 1).min(text.size.max(col + 1))
    return i
  }

  //////////////////////////////////////////////////////////////////////////
  // Compiler-diagnostics cache (main thread only, plan 7.12.9)
  //////////////////////////////////////////////////////////////////////////

  ** Replace the cached compiler diagnostics for `key` (accepted compile result).
  Void setCompilerDiagnostics(Str key, Diagnostic[] diags)
  {
    compilerCache[key] = diags.dup
  }

  Void clearCompilerDiagnostics(Str key) { compilerCache.remove(key) }

  Diagnostic[] compilerDiagnostics(Str key) { compilerCache[key]?.dup ?: Diagnostic[,] }

  ** Parser diagnostics computed now, followed by the cached compiler diagnostics.
  Diagnostic[] merge(Str key, Diagnostic[] parserDiags)
  {
    result := parserDiags.dup
    cached := compilerCache[key]
    if (cached != null) result.addAll(cached)
    return result
  }

  **
  ** Keep cached compiler diagnostics aligned with an edit from `oldText` to
  ** `newText`. The changed old-line span is the region outside the common
  ** prefix/suffix lines. A diagnostic is dropped only if its line range touches
  ** that span (or an insertion point lies inside it); diagnostics after the span
  ** shift by the line delta and earlier ones are kept unchanged.
  **
  Void adjustCompilerDiagnostics(Str key, Str oldText, Str newText)
  {
    cached := compilerCache[key]
    if (cached == null || cached.isEmpty || oldText == newText) return
    oldLines := TextDocumentManager.toLines(oldText)
    newLines := TextDocumentManager.toLines(newText)
    maxCommon := oldLines.size.min(newLines.size)
    prefix := 0
    while (prefix < maxCommon && oldLines[prefix] == newLines[prefix]) prefix++
    suffix := 0
    while (suffix < maxCommon - prefix &&
           oldLines[oldLines.size - 1 - suffix] == newLines[newLines.size - 1 - suffix]) suffix++
    lastChanged := oldLines.size - 1 - suffix   // may be prefix - 1 for pure insertions
    delta := newLines.size - oldLines.size
    kept := Diagnostic[,]
    cached.each |d|
    {
      s := d.range.start.line
      e := d.range.end.line
      if (e < prefix) kept.add(d)
      else if (s > lastChanged && s >= prefix)
      {
        if (delta == 0) kept.add(d)
        else kept.add(Diagnostic(LspRange(Position(s + delta, d.range.start.character),
          Position(e + delta, d.range.end.character)), d.severity, d.message, d.source))
      }
    }
    compilerCache[key] = kept
  }
}
