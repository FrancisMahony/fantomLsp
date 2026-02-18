class FantomLanguageServer
{
  TextDocumentManager docManager := TextDocumentManager()
  WorkspaceManager workspaceManager := WorkspaceManager()
  DiagnosticsProvider diagnosticsProvider := DiagnosticsProvider()
  HoverProvider hoverProvider := HoverProvider()
  DefinitionProvider definitionProvider := DefinitionProvider()
  ReferencesProvider referencesProvider := ReferencesProvider()
  CompletionProvider completionProvider := CompletionProvider()
  SignatureHelpProvider signatureHelpProvider := SignatureHelpProvider()
  FormattingProvider formattingProvider := FormattingProvider()
  RenameProvider renameProvider := RenameProvider()
  CodeActionProvider codeActionProvider := CodeActionProvider()
  SemanticTokensProvider semanticTokensProvider := SemanticTokensProvider()
  CallHierarchyProvider callHierarchyProvider := CallHierarchyProvider()
  WorkspaceSymbolProvider workspaceSymbolProvider := WorkspaceSymbolProvider()
  SymbolTable symbolTable := SymbolTable()
  TypeResolver typeResolver := TypeResolver()
  ReferenceIndex referenceIndex := ReferenceIndex()

  Bool isShutdown := false
  Str[]? workspaceFolders

  [Str:Obj?] initialize([Str:Obj?] params)
  {
    Env.cur.err.printLine("[fantomLsp] Initialize request received")

    rootUri := params["rootUri"] as Str
    if (rootUri != null)
    {
      workspaceFolders = [rootUri]
      workspaceManager.addFolder(rootUri)
    }

    folders := params["workspaceFolders"] as List
    if (folders != null)
    {
      folders.each |[Str:Obj?] f|
      {
        uri := f["uri"] as Str
        if (uri != null)
        {
          workspaceManager.addFolder(uri)
          if (workspaceFolders == null) workspaceFolders = Str[,]
          workspaceFolders.add(uri)
        }
      }
    }

    caps := Serialization.serverCapabilities(
      true,  // hover
      true,  // definition
      true,  // references
      true,  // completion
      true,  // signatureHelp
      true,  // documentSymbol
      true,  // formatting
      true,  // rename
      true,  // codeAction
      true,  // workspaceSymbol
      true,  // semanticTokens
      true   // callHierarchy
    )

    return [
      "capabilities": caps,
      "serverInfo": [
        "name": "Fantom Language Server",
        "version": "0.1.0",
      ],
    ]
  }

  Void initialized([Str:Obj?] params)
  {
    Env.cur.err.printLine("[fantomLsp] Server initialized")
    workspaceManager.indexWorkspace(symbolTable, typeResolver, referenceIndex)
  }

  Void shutdown()
  {
    Env.cur.err.printLine("[fantomLsp] Shutdown requested")
    isShutdown = true
  }

  [Str:Obj?]? didOpen([Str:Obj?] params)
  {
    td := params["textDocument"] as [Str:Obj?]
    item := TextDocumentItem.fromMap(td)
    docManager.open(item)

    parseResult := docManager.parseDocument(item.uri)
    symbolTable.update(item.uri, parseResult)
    referenceIndex.update(item.uri, parseResult)

    diags := diagnosticsProvider.computeDiagnostics(item.uri, parseResult)
    return Serialization.publishDiagnostics(item.uri, diags)
  }

  [Str:Obj?]? didChange([Str:Obj?] params)
  {
    td := params["textDocument"] as [Str:Obj?]
    uri := td["uri"] as Str
    version := ((Num)td["version"]).toInt
    changes := params["contentChanges"] as List

    changes.each |[Str:Obj?] change|
    {
      evt := TextDocumentContentChangeEvent.fromMap(change)
      docManager.change(uri, version, evt)
    }

    parseResult := docManager.parseDocument(uri)
    symbolTable.update(uri, parseResult)
    referenceIndex.update(uri, parseResult)

    diags := diagnosticsProvider.computeDiagnostics(uri, parseResult)
    return Serialization.publishDiagnostics(uri, diags)
  }

  [Str:Obj?]? didClose([Str:Obj?] params)
  {
    uri := Serialization.extractUri(params)
    docManager.close(uri)
    symbolTable.remove(uri)
    referenceIndex.remove(uri)
    return Serialization.publishDiagnostics(uri, Diagnostic[,])
  }

  [Str:Obj?]? didSave([Str:Obj?] params)
  {
    uri := Serialization.extractUri(params)
    text := params["text"] as Str
    if (text != null) docManager.updateText(uri, text)

    parseResult := docManager.parseDocument(uri)
    symbolTable.update(uri, parseResult)
    referenceIndex.update(uri, parseResult)

    diags := diagnosticsProvider.computeDiagnostics(uri, parseResult)
    return Serialization.publishDiagnostics(uri, diags)
  }

  Obj? hover([Str:Obj?] params)
  {
    uri := Serialization.extractUri(params)
    pos := Serialization.extractPosition(params)
    doc := docManager.getDocument(uri)
    if (doc == null) return null
    return hoverProvider.hover(doc, pos, symbolTable, typeResolver)
  }

  Obj? definition([Str:Obj?] params)
  {
    uri := Serialization.extractUri(params)
    pos := Serialization.extractPosition(params)
    doc := docManager.getDocument(uri)
    if (doc == null) return null
    return definitionProvider.definition(doc, pos, symbolTable, typeResolver)
  }

  Obj? references([Str:Obj?] params)
  {
    uri := Serialization.extractUri(params)
    pos := Serialization.extractPosition(params)
    doc := docManager.getDocument(uri)
    if (doc == null) return null
    return referencesProvider.references(doc, pos, symbolTable, referenceIndex)
  }

  Obj? completion([Str:Obj?] params)
  {
    uri := Serialization.extractUri(params)
    pos := Serialization.extractPosition(params)
    doc := docManager.getDocument(uri)
    if (doc == null) return null
    return completionProvider.complete(doc, pos, symbolTable, typeResolver)
  }

  Obj? signatureHelp([Str:Obj?] params)
  {
    uri := Serialization.extractUri(params)
    pos := Serialization.extractPosition(params)
    doc := docManager.getDocument(uri)
    if (doc == null) return null
    return signatureHelpProvider.signatureHelp(doc, pos, symbolTable, typeResolver)
  }

  Obj? documentSymbol([Str:Obj?] params)
  {
    uri := Serialization.extractUri(params)
    doc := docManager.getDocument(uri)
    if (doc == null) return null
    symbols := symbolTable.getDocumentSymbols(uri)
    return symbols.map |s| { s.toMap }
  }

  Obj? formatting([Str:Obj?] params)
  {
    uri := Serialization.extractUri(params)
    doc := docManager.getDocument(uri)
    if (doc == null) return null
    opts := params["options"] as [Str:Obj?] ?: [Str:Obj?][:]
    edits := formattingProvider.format(doc, opts)
    return edits.map |e| { e.toMap }
  }

  Obj? rename([Str:Obj?] params)
  {
    uri := Serialization.extractUri(params)
    pos := Serialization.extractPosition(params)
    newName := params["newName"] as Str
    doc := docManager.getDocument(uri)
    if (doc == null) return null
    edit := renameProvider.rename(doc, pos, newName, symbolTable, referenceIndex)
    return edit?.toMap
  }

  Obj? codeAction([Str:Obj?] params)
  {
    uri := Serialization.extractUri(params)
    range := LspRange.fromMap(params["range"])
    context := params["context"] as [Str:Obj?] ?: [Str:Obj?][:]
    doc := docManager.getDocument(uri)
    if (doc == null) return null
    return codeActionProvider.codeActions(doc, range, context, symbolTable, typeResolver)
  }

  Obj? semanticTokensFull([Str:Obj?] params)
  {
    uri := Serialization.extractUri(params)
    doc := docManager.getDocument(uri)
    if (doc == null) return null
    return semanticTokensProvider.provideTokens(doc, symbolTable, typeResolver)
  }

  Obj? prepareCallHierarchy([Str:Obj?] params)
  {
    uri := Serialization.extractUri(params)
    pos := Serialization.extractPosition(params)
    doc := docManager.getDocument(uri)
    if (doc == null) return null
    return callHierarchyProvider.prepare(doc, pos, symbolTable)
  }

  Obj? callHierarchyIncoming([Str:Obj?] params)
  {
    item := params["item"] as [Str:Obj?] ?: [Str:Obj?][:]
    return callHierarchyProvider.incomingCalls(item, symbolTable, referenceIndex)
  }

  Obj? callHierarchyOutgoing([Str:Obj?] params)
  {
    item := params["item"] as [Str:Obj?] ?: [Str:Obj?][:]
    return callHierarchyProvider.outgoingCalls(item, symbolTable, referenceIndex)
  }

  Obj? workspaceSymbol([Str:Obj?] params)
  {
    query := params["query"] as Str ?: ""
    return workspaceSymbolProvider.search(query, symbolTable)
  }
}
