class LspDispatcher
{
  private FantomLanguageServer server
  private [Str:Obj?][] notifications := [,]
  Bool shouldExit := false
  Int exitCode := 0

  new make(FantomLanguageServer server)
  {
    this.server = server
  }

  [Str:Obj?][] pendingNotifications()
  {
    result := notifications.dup
    notifications.clear
    return result
  }

  ** Main thread only. Background results are applied before every message
  ** (plan 7.3), so handlers always see the latest drained state.
  [Str:Obj?]? dispatch([Str:Obj?] msg)
  {
    try
    {
      server.applyBackgroundResults
    }
    catch (Err e)
    {
      Env.cur.err.printLine("[fantomLsp] Error applying background results: $e.msg")
      e.trace(Env.cur.err)
    }

    method := msg["method"] as Str
    id := msg["id"]
    params := msg["params"] as [Str:Obj?] ?: [Str:Obj?][:]

    if (method == null && id != null)
      return null

    if (id != null)
      return dispatchRequest(id, method, params)
    else
      dispatchNotification(method, params)
    return null
  }

  private [Str:Obj?] dispatchRequest(Obj id, Str method, [Str:Obj?] params)
  {
    try
    {
      if (!isKnownRequest(method))
        return makeErrorResponse(id, -32601, "Method not found: $method")
      result := handleRequest(id, method, params)
      return makeResponse(id, result)
    }
    catch (RequestFailedErr e)
    {
      return makeErrorResponse(id, -32803, e.msg)
    }
    catch (Err e)
    {
      Env.cur.err.printLine("[fantomLsp] Error handling $method: $e.msg")
      e.trace(Env.cur.err)
      return makeErrorResponse(id, -32603, e.msg)
    }
    finally { server.retireCancel(id) }
  }

  private static Bool isKnownRequest(Str method)
  {
    switch (method)
    {
      case "initialize":
      case "shutdown":
      case "textDocument/hover":
      case "textDocument/completion":
      case "completionItem/resolve":
      case "textDocument/documentHighlight":
      case "textDocument/foldingRange":
      case "textDocument/inlayHint":
      case "textDocument/selectionRange":
      case "textDocument/signatureHelp":
      case "textDocument/definition":
      case "textDocument/declaration":
      case "textDocument/typeDefinition":
      case "textDocument/implementation":
      case "textDocument/references":
      case "textDocument/documentSymbol":
      case "textDocument/formatting":
      case "textDocument/rangeFormatting":
      case "textDocument/onTypeFormatting":
      case "textDocument/documentLink":
      case "textDocument/rename":
      case "textDocument/prepareRename":
      case "textDocument/codeAction":
      case "textDocument/codeLens":
      case "codeLens/resolve":
      case "textDocument/linkedEditingRange":
      case "textDocument/semanticTokens/full":
      case "textDocument/semanticTokens/range":
      case "textDocument/prepareCallHierarchy":
      case "textDocument/prepareTypeHierarchy":
      case "callHierarchy/incomingCalls":
      case "callHierarchy/outgoingCalls":
      case "typeHierarchy/supertypes":
      case "typeHierarchy/subtypes":
      case "workspace/symbol":
      case "\$/cancelRequest":
        return true
      default:
        return false
    }
  }

  private Void dispatchNotification(Str method, [Str:Obj?] params)
  {
    try
    {
      handleNotification(method, params)
    }
    catch (Err e)
    {
      Env.cur.err.printLine("[fantomLsp] Error handling notification $method: $e.msg")
      e.trace(Env.cur.err)
    }
  }

  protected virtual Obj? handleRequest(Obj id, Str method, [Str:Obj?] params)
  {
    switch (method)
    {
      case "initialize":
        return server.initialize(params)
      case "shutdown":
        server.shutdown
        return null
      case "textDocument/hover":
        return server.hover(params, id)
      case "textDocument/completion":
        return server.completion(params, id)
      case "completionItem/resolve":
        return server.completionResolve(params)
      case "textDocument/documentHighlight":
        return server.documentHighlight(params, id)
      case "textDocument/foldingRange":
        return server.foldingRange(params)
      case "textDocument/inlayHint":
        return server.inlayHint(params)
      case "textDocument/selectionRange":
        return server.selectionRange(params)
      case "textDocument/signatureHelp":
        return server.signatureHelp(params, id)
      case "textDocument/definition":
        return server.definition(params, id)
      case "textDocument/declaration":
        return server.declaration(params, id)
      case "textDocument/typeDefinition":
        return server.typeDefinition(params, id)
      case "textDocument/implementation":
        return server.implementation(params, id)
      case "textDocument/references":
        return server.references(params, id)
      case "textDocument/documentSymbol":
        return server.documentSymbol(params)
      case "textDocument/formatting":
        return server.formatting(params)
      case "textDocument/rangeFormatting":
        return server.rangeFormatting(params)
      case "textDocument/onTypeFormatting":
        return server.onTypeFormatting(params)
      case "textDocument/documentLink":
        return server.documentLink(params)
      case "textDocument/rename":
        return server.rename(params, id)
      case "textDocument/prepareRename":
        return server.prepareRename(params, id)
      case "textDocument/linkedEditingRange":
        return server.linkedEditingRange(params, id)
      case "textDocument/codeLens":
        return server.codeLens(params, id)
      case "codeLens/resolve":
        return server.codeLensResolve(params, id)
      case "textDocument/codeAction":
        return server.codeAction(params)
      case "textDocument/semanticTokens/full":
        return server.semanticTokensFull(params)
      case "textDocument/semanticTokens/range":
        return server.semanticTokensRange(params)
      case "textDocument/prepareCallHierarchy":
        return server.prepareCallHierarchy(params, id)
      case "callHierarchy/incomingCalls":
        return server.callHierarchyIncoming(params, id)
      case "callHierarchy/outgoingCalls":
        return server.callHierarchyOutgoing(params, id)
      case "textDocument/prepareTypeHierarchy":
        return server.prepareTypeHierarchy(params, id)
      case "typeHierarchy/supertypes":
        return server.typeHierarchySupertypes(params)
      case "typeHierarchy/subtypes":
        return server.typeHierarchySubtypes(params)
      case "workspace/symbol":
        return server.workspaceSymbol(params)
      case "\$/cancelRequest":
        server.cancelRequest(params["id"])
        return null
      default:
        return null
    }
  }

  private Void handleNotification(Str method, [Str:Obj?] params)
  {
    switch (method)
    {
      case "initialized":
        server.initialized(params)
      case "workspace/didChangeConfiguration":
        server.didChangeConfiguration(params)
      case "workspace/didChangeWorkspaceFolders":
        server.didChangeWorkspaceFolders(params)
      case "textDocument/didOpen":
        diags := server.didOpen(params)
        if (diags != null) notifications.add(diags)
      case "textDocument/didChange":
        diags := server.didChange(params)
        if (diags != null) notifications.add(diags)
      case "textDocument/didClose":
        diags := server.didClose(params)
        if (diags != null) notifications.add(diags)
      case "textDocument/didSave":
        saved := server.didSave(params)
        if (saved != null) notifications.add(saved)
      case "workspace/didChangeWatchedFiles":
        server.didChangeWatchedFiles(params)
      case "exit":
        shouldExit = true
        exitCode = server.isShutdown ? 0 : 1
      case "\$/cancelRequest":
        server.cancelRequest(params["id"])
      default:
        if (method == "\$/progress" || method == "\$/setTrace" || method == "\$/logTrace")
          return
        Env.cur.err.printLine("[fantomLsp] Unhandled notification: $method")
    }
  }

  static [Str:Obj?] makeResponse(Obj id, Obj? result)
  {
    ["jsonrpc": "2.0", "id": id, "result": result]
  }

  static [Str:Obj?] makeErrorResponse(Obj id, Int code, Str message)
  {
    ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
  }

  static [Str:Obj?] makeNotification(Str method, Obj? params)
  {
    ["jsonrpc": "2.0", "method": method, "params": params]
  }
}

** An expected request failure (e.g. unsafe rename), not an internal error.
const class RequestFailedErr : Err
{
  new make(Str msg, Err? cause := null) : super(msg, cause) {}
}
