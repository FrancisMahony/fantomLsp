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

  [Str:Obj?]? dispatch([Str:Obj?] msg)
  {
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
      result := handleRequest(method, params)
      return makeResponse(id, result)
    }
    catch (Err e)
    {
      Env.cur.err.printLine("[fantomLsp] Error handling $method: $e.msg")
      e.trace(Env.cur.err)
      return makeErrorResponse(id, -32603, e.msg)
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

  private Obj? handleRequest(Str method, [Str:Obj?] params)
  {
    switch (method)
    {
      case "initialize":
        return server.initialize(params)
      case "shutdown":
        server.shutdown
        return null
      case "textDocument/hover":
        return server.hover(params)
      case "textDocument/completion":
        return server.completion(params)
      case "textDocument/signatureHelp":
        return server.signatureHelp(params)
      case "textDocument/definition":
        return server.definition(params)
      case "textDocument/references":
        return server.references(params)
      case "textDocument/documentSymbol":
        return server.documentSymbol(params)
      case "textDocument/formatting":
        return server.formatting(params)
      case "textDocument/rename":
        return server.rename(params)
      case "textDocument/prepareRename":
        return server.prepareRename(params)
      case "textDocument/codeAction":
        return server.codeAction(params)
      case "textDocument/semanticTokens/full":
        return server.semanticTokensFull(params)
      case "textDocument/prepareCallHierarchy":
        return server.prepareCallHierarchy(params)
      case "callHierarchy/incomingCalls":
        return server.callHierarchyIncoming(params)
      case "callHierarchy/outgoingCalls":
        return server.callHierarchyOutgoing(params)
      case "workspace/symbol":
        return server.workspaceSymbol(params)
      default:
        Env.cur.err.printLine("[fantomLsp] Unhandled request: $method")
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
        server.didSave(params).each |n| { notifications.add(n) }
      case "exit":
        shouldExit = true
        exitCode = server.isShutdown ? 0 : 1
      default:
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
