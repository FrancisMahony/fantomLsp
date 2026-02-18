class DiagnosticsProvider
{
  Diagnostic[] computeDiagnostics(Str uri, ParseResult result)
  {
    diags := Diagnostic[,]
    result.errors.each |err|
    {
      diags.add(Diagnostic(err.range, Diagnostic.error, err.message, "fantomLsp"))
    }
    return diags
  }
}
