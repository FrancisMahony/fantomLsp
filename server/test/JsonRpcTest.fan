using util

class JsonRpcTest : Test
{
  // ── Helpers ───────────────────────────────────────────────────────────────────

  ** Build an InStream containing a complete JSON-RPC message with proper headers.
  private InStream makeInput(Str body)
  {
    bodyBuf := Buf().print(body)
    header  := "Content-Length: ${bodyBuf.size}\r\n\r\n"
    full    := Buf().print(header).print(body)
    return full.flip.in
  }

  private JsonRpc makeRpc(Str body, Buf outBuf)
  {
    JsonRpc(makeInput(body), outBuf.out)
  }

  // ── readMessage ───────────────────────────────────────────────────────────────

  Void testReadMessageBasic()
  {
    body := "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}"
    outBuf := Buf()
    rpc := makeRpc(body, outBuf)
    msg := rpc.readMessage
    verifyNotNull(msg)
    verifyEq(msg["jsonrpc"], "2.0")
    verifyEq(msg["method"], "initialize")
    verifyNotNull(msg["id"])
  }

  Void testReadMessageWithParams()
  {
    body := "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"a\":1}}"
    outBuf := Buf()
    rpc := makeRpc(body, outBuf)
    msg := rpc.readMessage
    verifyNotNull(msg)
    verifyEq(msg["method"], "textDocument/hover")
    params := msg["params"] as [Str:Obj?]
    verifyNotNull(params)
  }

  Void testReadMessageNotification()
  {
    body := "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}"
    outBuf := Buf()
    rpc := makeRpc(body, outBuf)
    msg := rpc.readMessage
    verifyNotNull(msg)
    verifyEq(msg["method"], "initialized")
    verifyNull(msg["id"])
  }

  Void testReadMessageEofReturnsNull()
  {
    // Empty stream → headers missing → null
    inStream := Buf().flip.in
    outBuf := Buf()
    rpc := JsonRpc(inStream, outBuf.out)
    msg := rpc.readMessage
    verifyNull(msg)
  }

  Void testReadMessageMissingContentLengthReturnsNull()
  {
    // Header present but no Content-Length key
    input := "X-Custom: foo\r\n\r\n{}"
    inStream := Buf().print(input).flip.in
    outBuf := Buf()
    rpc := JsonRpc(inStream, outBuf.out)
    msg := rpc.readMessage
    verifyNull(msg)
  }

  // ── writeMessage ──────────────────────────────────────────────────────────────

  ** Write a message then read it back — verifies the framing is valid.
  Void testWriteMessageRoundTrip()
  {
    pipe := Buf()
    JsonRpc(Buf().flip.in, pipe.out).writeMessage(
      ["jsonrpc": "2.0", "id": 7, "method": "ping"])
    pipe.seek(0)
    msg := JsonRpc(pipe.in, Buf().out).readMessage
    verifyNotNull(msg)
    verifyEq(msg["jsonrpc"], "2.0")
    verifyEq(msg["method"], "ping")
  }

  ** Round-trip with a result payload also verifies id survives the cycle.
  Void testWriteMessageRoundTripWithResult()
  {
    pipe := Buf()
    JsonRpc(Buf().flip.in, pipe.out).writeMessage(
      ["jsonrpc": "2.0", "id": 99, "result": "ok"])
    pipe.seek(0)
    msg := JsonRpc(pipe.in, Buf().out).readMessage
    verifyNotNull(msg)
    verifyEq(msg["result"], "ok")
  }

  // ── makeResponse / makeErrorResponse (via LspDispatcher static helpers) ───────

  Void testMakeResponse()
  {
    r := LspDispatcher.makeResponse(1, "hello")
    verifyEq(r["jsonrpc"], "2.0")
    verifyEq(r["id"], 1)
    verifyEq(r["result"], "hello")
  }

  Void testMakeResponseNullResult()
  {
    r := LspDispatcher.makeResponse(42, null)
    verifyEq(r["id"], 42)
    verifyNull(r["result"])
  }

  Void testMakeErrorResponse()
  {
    r := LspDispatcher.makeErrorResponse(3, -32603, "Internal error")
    verifyEq(r["jsonrpc"], "2.0")
    verifyEq(r["id"], 3)
    err := r["error"] as [Str:Obj?]
    verifyNotNull(err)
    verifyEq(err["code"], -32603)
    verifyEq(err["message"], "Internal error")
  }

  Void testMakeNotification()
  {
    n := LspDispatcher.makeNotification("textDocument/publishDiagnostics", ["uri": "file:///x.fan"])
    verifyEq(n["jsonrpc"], "2.0")
    verifyEq(n["method"], "textDocument/publishDiagnostics")
    verifyNotNull(n["params"])
  }
}
