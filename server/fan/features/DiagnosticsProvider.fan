using compiler

class DiagnosticsProvider
{
  TextDocumentManager docManager
  CompilerDiagnostics compilerDiag := CompilerDiagnostics()

  new make(TextDocumentManager docManager)
  {
    this.docManager = docManager
  }

  Diagnostic[] computeDiagnostics(Str uri, ParseResult result)
  {
    diags := Diagnostic[,]

    // Add parser errors
    result.errors.each |err|
    {
      diags.add(Diagnostic(err.range, Diagnostic.error, err.message, "fantomLsp"))
    }

    // Add compiler errors
    doc := docManager.getDocument(uri)
    if (doc != null)
    {
      compilerErrs := compilerDiag.compileAndGetErrors(uri, doc.text)
      compilerErrs.each |err|
      {
        line := (err.line ?: 1) - 1
        col := (err.col ?: 0)
        range := LspRange(Position(line, col), Position(line, col + 10))
        diags.add(Diagnostic(range, Diagnostic.error, err.msg, "fantomCompiler"))
      }
    }

    return diags
  }
}
