class FantomLanguageServer
{
  TextDocumentManager docManager := TextDocumentManager()
  WorkspaceManager workspaceManager := WorkspaceManager()
  DiagnosticsProvider diagnosticsProvider
  HoverProvider hoverProvider := HoverProvider()
  DefinitionProvider definitionProvider := DefinitionProvider()
  ReferencesProvider referencesProvider := ReferencesProvider()
  CompletionProvider completionProvider := CompletionProvider()
  SignatureHelpProvider signatureHelpProvider := SignatureHelpProvider()
  WorkspaceSymbolProvider workspaceSymbolProvider := WorkspaceSymbolProvider()
  FormattingProvider formattingProvider := FormattingProvider()
  RenameProvider renameProvider := RenameProvider()
  CodeActionProvider codeActionProvider := CodeActionProvider()
  SymbolTable symbolTable := SymbolTable()
  TypeResolver typeResolver := TypeResolver()
  ReferenceIndex referenceIndex := ReferenceIndex()

  Bool isShutdown := false
  Str[]? workspaceFolders
  Str bracketStyle := "preserve"

  new make()
  {
    diagnosticsProvider = DiagnosticsProvider(docManager)
  }

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
      true,   // hover
      true,   // definition
      true,   // references
      true,   // completion
      true,   // signatureHelp
      true,   // documentSymbol
      true,   // formatting
      true,   // rename
      true,   // codeAction
      true,   // workspaceSymbol
      false,  // semanticTokens
      false   // callHierarchy
    )

    return [
      "capabilities": caps,
      "serverInfo": [
        "name": "Fantom Language Server",
        "version": "0.5.0",
      ],
    ]
  }

  Void initialized([Str:Obj?] params)
  {
    Env.cur.err.printLine("[fantomLsp] Server initialized")
    // workspaceManager.indexWorkspace(symbolTable, typeResolver, referenceIndex)
  }

  Void shutdown()
  {
    Env.cur.err.printLine("[fantomLsp] Shutdown requested")
    isShutdown = true
  }

  Void didChangeConfiguration([Str:Obj?] params)
  {
    settings := params["settings"] as [Str:Obj?]
    if (settings != null)
    {
      fantom := settings["fantom"] as [Str:Obj?]
      if (fantom != null)
      {
        formatting := fantom["formatting"] as [Str:Obj?]
        if (formatting != null)
        {
          style := formatting["bracketStyle"] as Str
          if (style != null)
          {
            bracketStyle = style
          }
        }
      }
    }
  }

  [Str:Obj?]? didOpen([Str:Obj?] params)
  {
    td := params["textDocument"] as [Str:Obj?]
    item := TextDocumentItem.fromMap(td)
    docManager.open(item)
    parseResult := docManager.parseDocument(item.uri)
    diags := diagnosticsProvider.computeDiagnostics(item.uri, parseResult)
    symbolTable.update(item.uri, parseResult)
    referenceIndex.update(item.uri, parseResult)
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
    diags := diagnosticsProvider.computeDiagnostics(uri, parseResult)
    symbolTable.update(uri, parseResult)
    referenceIndex.update(uri, parseResult)
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

  [Str:Obj?][] didSave([Str:Obj?] params)
  {
    uri := Serialization.extractUri(params)
    text := params["text"] as Str
    if (text != null) docManager.updateText(uri, text)
    parseResult := docManager.parseDocument(uri)
    diags := diagnosticsProvider.computeDiagnostics(uri, parseResult)
    symbolTable.update(uri, parseResult)
    referenceIndex.update(uri, parseResult)

    result := [Str:Obj?][,]
    result.add(Serialization.publishDiagnostics(uri, diags))

    // Republish diagnostics for all other open files so cross-file
    // effects (e.g. saving build.fan) are reflected immediately.
    docManager.openUris.each |otherUri|
    {
      if (otherUri == uri) return
      otherParse := docManager.parseDocument(otherUri)
      otherDiags := diagnosticsProvider.computeDiagnostics(otherUri, otherParse)
      result.add(Serialization.publishDiagnostics(otherUri, otherDiags))
    }

    return result
  }

  Obj? hover([Str:Obj?] params)
  {
    uri := Serialization.extractUri(params)
    pos := Serialization.extractPosition(params)
    doc := docManager.getDocument(uri)
    if (doc == null) return null
    parseResult := docManager.parseDocument(uri)
    return hoverProvider.hover(doc, parseResult, pos)
  }

  Obj? completion([Str:Obj?] params)
  {
    uri := Serialization.extractUri(params)
    pos := Serialization.extractPosition(params)
    doc := docManager.getDocument(uri)
    if (doc == null) return null
    parseResult := docManager.parseDocument(uri)
    return completionProvider.complete(doc, parseResult, pos)
  }

  Obj? signatureHelp([Str:Obj?] params)
  {
    uri := Serialization.extractUri(params)
    pos := Serialization.extractPosition(params)
    doc := docManager.getDocument(uri)
    if (doc == null) return null
    parseResult := docManager.parseDocument(uri)
    return signatureHelpProvider.signatureHelp(doc, parseResult, pos)
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

  // Obj? completion([Str:Obj?] params)
  // {
  //   uri := Serialization.extractUri(params)
  //   pos := Serialization.extractPosition(params)
  //   doc := docManager.getDocument(uri)
  //   if (doc == null) return null
  //   return completionProvider.complete(doc, pos, symbolTable, typeResolver)
  // }

  // Obj? signatureHelp([Str:Obj?] params)
  // {
  //   uri := Serialization.extractUri(params)
  //   pos := Serialization.extractPosition(params)
  //   doc := docManager.getDocument(uri)
  //   if (doc == null) return null
  //   return signatureHelpProvider.signatureHelp(doc, pos, symbolTable, typeResolver)
  // }

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
    opts["bracketStyle"] = bracketStyle
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

  Obj? prepareRename([Str:Obj?] params)
  {
    uri := Serialization.extractUri(params)
    pos := Serialization.extractPosition(params)
    doc := docManager.getDocument(uri)
    if (doc == null) return null
    return renameProvider.prepareRename(doc, pos)
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

  // Obj? semanticTokensFull([Str:Obj?] params)
  // {
  //   uri := Serialization.extractUri(params)
  //   doc := docManager.getDocument(uri)
  //   if (doc == null) return null
  //   return semanticTokensProvider.provideTokens(doc, symbolTable, typeResolver)
  // }

  // Obj? prepareCallHierarchy([Str:Obj?] params)
  // {
  //   uri := Serialization.extractUri(params)
  //   pos := Serialization.extractPosition(params)
  //   doc := docManager.getDocument(uri)
  //   if (doc == null) return null
  //   return callHierarchyProvider.prepare(doc, pos, symbolTable)
  // }

  // Obj? callHierarchyIncoming([Str:Obj?] params)
  // {
  //   item := params["item"] as [Str:Obj?] ?: [Str:Obj?][:]
  //   return callHierarchyProvider.incomingCalls(item, symbolTable, referenceIndex)
  // }

  // Obj? callHierarchyOutgoing([Str:Obj?] params)
  // {
  //   item := params["item"] as [Str:Obj?] ?: [Str:Obj?][:]
  //   return callHierarchyProvider.outgoingCalls(item, symbolTable, referenceIndex)
  // }

  Obj? workspaceSymbol([Str:Obj?] params)
  {
    query := params["query"] as Str ?: ""
    return workspaceSymbolProvider.search(query, symbolTable)
  }
}
