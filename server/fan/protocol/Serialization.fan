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
    // Declaration uses the same lookup and location shape as definition.
    caps["declarationProvider"] = true
    // Fantom types are their own type definitions; implementation currently
    // uses the same bounded definition lookup.
    caps["typeDefinitionProvider"] = true
    caps["typeHierarchyProvider"] = true
    caps["implementationProvider"] = true
    if (referencesProvider) caps["referencesProvider"] = true
    if (documentSymbolProvider) caps["documentSymbolProvider"] = true
    if (formattingProvider) caps["documentFormattingProvider"] = true
    caps["documentRangeFormattingProvider"] = true
    caps["documentOnTypeFormattingProvider"] = ["firstTriggerCharacter": "}"]
    caps["documentLinkProvider"] = true
    if (renameProvider) caps["renameProvider"] = ["prepareProvider": true]
    if (codeActionProvider) caps["codeActionProvider"] = true
    if (workspaceSymbolProvider) caps["workspaceSymbolProvider"] = true

    if (completionProvider)
    {
      caps["completionProvider"] = [
        "triggerCharacters": [".", ":"],
        "resolveProvider": true,
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
         "range": true,
       ]
    }

    if (callHierarchyProvider) caps["callHierarchyProvider"] = true

    caps["documentHighlightProvider"] = true
    caps["foldingRangeProvider"] = true
    caps["inlayHintProvider"] = true
    caps["selectionRangeProvider"] = true
    caps["linkedEditingRangeProvider"] = true
    caps["codeLensProvider"] = ["resolveProvider": true]

    // Client watches **/*.fan and **/*.fwt via synchronize.fileEvents
    // and sends workspace/didChangeWatchedFiles.
    caps["workspace"] = [
      "fileOperations": [
        "didCreate": false,
        "didRename": false,
        "didDelete": false,
      ],
    ]

    return caps
  }
}
