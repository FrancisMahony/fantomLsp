using concurrent

class Main
{
  static Void main(Str[] args)
  {
    log := Log.get("fantomLsp")
    log.level = LogLevel.info

    pod := Pod.find("fantomLsp")
    Env.cur.err.printLine("[fantomLsp] Starting Fantom Language Server...")
    Env.cur.err.printLine("[fantomLsp] Version: ${pod.version}")
    Env.cur.err.printLine("[fantomLsp] Homedir: ${Env.cur.homeDir}")
    Env.cur.err.printLine("[fantomLsp] Pod uri: ${pod.uri}")

    pool := ActorPool { it.name = "fantomLsp-io" }
    writeActor := StdioWriteActor(pool, Env.cur.out)
    server := FantomLanguageServer()
    server.stdioWriter = writeActor
    loop := LspMainLoop(server, Env.cur.in)
    exitCode := loop.run

    // Let queued frames reach stdout before the process exits.
    try { writeActor.send(null).get(5sec) } catch (Err e) {}
    Env.cur.err.printLine("[fantomLsp] Server exiting.")
    Env.cur.exit(exitCode)
  }
}

**
** The main (dispatch) thread loop. A `StdinReaderActor` reads
** and parses continuously into a FIFO of completable futures off the main
** thread, marking cancellation tokens before handing over their frames.
** The main thread waits for the head with a `pollInterval` timeout; on timeout it calls
** `server.applyBackgroundResults`, so background results (index batches,
** compiler diagnostics) are applied and published without any further client
** message. All analysis state is touched only by the thread calling `run`/`tick`,
** and every outgoing message goes through `server.enqueueOutgoing`.
**
class LspMainLoop
{
  FantomLanguageServer server { private set }
  LspDispatcher dispatcher { private set }
  Duration pollInterval := 200ms
  ** True after EOF or the `exit` notification.
  Bool done := false { private set }
  Int idleTicks := 0 { private set }
  Int messagesHandled := 0 { private set }

  private const StdinReaderActor reader
  private Future? pendingRead

  new make(FantomLanguageServer server, InStream in, LspDispatcher? dispatcher := null)
  {
    this.server = server
    this.dispatcher = dispatcher ?: LspDispatcher(server)
    pool := ActorPool { it.name = "fantomLsp-stdin"; it.maxThreads = 1 }
    this.reader = StdinReaderActor(pool, in, server.cancelTokens)
  }

  ** Run until EOF or `exit`; returns the process exit code.
  Int run()
  {
    while (!done) tick
    return dispatcher.exitCode
  }

  **
  ** One iteration: handle the next client message if it arrives within
  ** `pollInterval`, otherwise apply pending background results (idle tick).
  **
  Void tick()
  {
    if (done) return
    try
    {
      if (pendingRead == null)
      {
        pendingRead = Future.makeCompletable
        reader.send(pendingRead)
      }
      ReadFrame? result := null
      try
      {
        result = pendingRead.get(pollInterval)
      }
      catch (TimeoutErr e)
      {
        idleTicks++
        server.applyBackgroundResults
        return
      }
      // Advance before dispatch: the reader already owns the next read and
      // can deliver cancellation even while this handler waits for freshness.
      pendingRead = result.next
      if (result.next == null) { done = true; return }   // EOF
      if (result.err != null)
      {
        Env.cur.err.printLine("[fantomLsp] Error reading message: $result.err")
        return
      }
      msg := result.msg?.val as [Str:Obj?]
      if (msg != null)
      {
        try { handle(msg) }
        finally
        {
          if (msg["method"] == "\$/cancelRequest")
            server.retireCancel((msg["params"] as Map)?.get("id"))
        }
      }
    }
    catch (Err e)
    {
      Env.cur.err.printLine("[fantomLsp] Error: $e.msg")
      e.trace(Env.cur.err)
    }
  }

  ** Dispatch one message on the main thread and write its outputs exactly once.
  Void handle([Str:Obj?] msg)
  {
    messagesHandled++
    method := msg["method"]
    Env.cur.err.printLine("[fantomLsp] Received: $method")
    response := dispatcher.dispatch(msg)
    if (response != null) server.enqueueOutgoing(response)
    dispatcher.pendingNotifications.each |n| { server.enqueueOutgoing(n) }
    if (dispatcher.shouldExit) done = true
  }
}

**
** Immutable FIFO link. The reader transfers sole ownership of the parsed map
** to the dispatch thread and completes each head exactly once.
** A null next link denotes EOF; parse errors retain a next link.
**
internal const class ReadFrame
{
  const Unsafe? msg
  const Str? err
  const Future? next
  new make(Unsafe? msg, Str? err, Future? next)
  {
    this.msg = msg; this.err = err; this.next = next
  }
}

** Continuously reads on its own thread. Only cancellation tokens are shared;
** it never holds the server, analysis state, or the output writer.
**
const class StdinReaderActor : Actor
{
  private const Unsafe rpcRef
  private const ConcurrentMap cancelTokens

  new make(ActorPool pool, InStream in, ConcurrentMap cancelTokens) : super(pool)
  {
    // The JsonRpc instance is used only by this actor's thread (read side).
    this.rpcRef = Unsafe(JsonRpc(in, Buf().out))
    this.cancelTokens = cancelTokens
  }

  override Obj? receive(Obj? msg)
  {
    head := (Future)msg
    Unsafe? payload := null
    Str? error := null
    Bool eof := false
    try
    {
      read := ((JsonRpc)rpcRef.val).readMessage
      if (read == null) eof = true
      else
      {
        if (read["method"] == "\$/cancelRequest")
        {
          key := FantomLanguageServer.cancelKey((read["params"] as Map)?.get("id"))
          if (key != null) cancelTokens[key] = true
        }
        payload = Unsafe(read)
      }
    }
    catch (IOErr e)
    {
      eof = true
      Env.cur.err.printLine("[fantomLsp] stdin closed: $e.msg")
    }
    catch (Err e)
    {
      error = "$e"
    }
    next := eof ? null : Future.makeCompletable
    // Queue the successor before publishing this frame. No main-thread read
    // acknowledgement is needed, including during a blocking request handler.
    if (next != null) send(next)
    head.complete(ReadFrame(payload, error, next))
    return null
  }
}
