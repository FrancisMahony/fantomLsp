class Serialization
{
  static [Str:Obj?] textDocumentPositionParams([Str:Obj?] params)
  {
    params
  }

  static Str extractUri([Str:Obj?] params)
  {
    td := params["textDocument"] as [Str:Obj?]
    return td["uri"]
  }

  static Position extractPosition([Str:Obj?] params)
  {
    Position.fromMap(params["position"])
  }

  static TextDocumentIdentifier extractTextDocument([Str:Obj?] params)
  {
    TextDocumentIdentifier.fromMap(params["textDocument"])
  }

  static [Str:Obj?] publishDiagnostics(Str uri, Diagnostic[] diagnostics)
  {
    LspDispatcher.makeNotification("textDocument/publishDiagnostics",
      ["uri": uri, "diagnostics": diagnostics.map |d| { d.toMap }])
  }

  static [Str:Obj?] serverCapabilities(
    Bool hoverProvider,
    Bool definitionProvider,
    Bool referencesProvider,
    Bool completionProvider,
    Bool signatureHelpProvider,
    Bool documentSymbolProvider,
    Bool formattingProvider,
    Bool renameProvider,
    Bool codeActionProvider,
    Bool workspaceSymbolProvider,
    Bool semanticTokensProvider,
    Bool callHierarchyProvider)
  {
    caps := Str:Obj?[
      "textDocumentSync": [
        "openClose": true,
        "change": 2,
        "save": ["includeText": true],
      ],
    ]

    if (hoverProvider) caps["hoverProvider"] = true
    if (definitionProvider) caps["definitionProvider"] = true
    if (referencesProvider) caps["referencesProvider"] = true
    if (documentSymbolProvider) caps["documentSymbolProvider"] = true
    if (formattingProvider) caps["documentFormattingProvider"] = true
    if (renameProvider) caps["renameProvider"] = ["prepareProvider": true]
    if (codeActionProvider) caps["codeActionProvider"] = true
    if (workspaceSymbolProvider) caps["workspaceSymbolProvider"] = true

    if (completionProvider)
    {
      caps["completionProvider"] = [
        "triggerCharacters": [".", ":", " "],
        "resolveProvider": false,
      ]
    }

    if (signatureHelpProvider)
    {
      caps["signatureHelpProvider"] = [
        "triggerCharacters": ["(", ","],
      ]
    }

    if (semanticTokensProvider)
    {
      caps["semanticTokensProvider"] = [
        "legend": [
          "tokenTypes": SemanticTokensProvider.tokenTypes,
          "tokenModifiers": SemanticTokensProvider.tokenModifiers,
        ],
        "full": true,
      ]
    }

    if (callHierarchyProvider) caps["callHierarchyProvider"] = true

    return caps
  }
}
