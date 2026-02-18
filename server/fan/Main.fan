using concurrent

class Main
{
  static Void main(Str[] args)
  {
    log := Log.get("fantomLsp")
    log.level = LogLevel.debug

    Env.cur.err.printLine("[fantomLsp] Starting Fantom Language Server...")

    jsonRpc := JsonRpc(Env.cur.in, Env.cur.out)
    server := FantomLanguageServer()
    dispatcher := LspDispatcher(server)

    while (true)
    {
      try
      {
        msg := jsonRpc.readMessage
        if (msg == null) break

        method := msg["method"]
        Env.cur.err.printLine("[fantomLsp] Received: $method")

        response := dispatcher.dispatch(msg)
        if (response != null)
        {
          jsonRpc.writeMessage(response)
        }

        notifications := dispatcher.pendingNotifications
        notifications.each |n| { jsonRpc.writeMessage(n) }

        if (dispatcher.shouldExit) break
      }
      catch (Err e)
      {
        Env.cur.err.printLine("[fantomLsp] Error: $e.msg")
        e.trace(Env.cur.err)
      }
    }

    Env.cur.err.printLine("[fantomLsp] Server exiting.")
    Env.cur.exit(dispatcher.exitCode)
  }
}
