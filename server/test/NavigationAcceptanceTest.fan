using concurrent

** Protocol acceptance through JSON-RPC, not provider or snapshot fixtures.
** Dependency pods are built only in TestWorkspace's private lib/fan.
class NavigationAcceptanceTest : Test
{
  private TestWorkspace? ws
  private FantomLanguageServer? server
  private LspDispatcher? dispatcher
  private Int nextId := 0
  private Str alpha := ""
  private Str beta := ""
  private File? alphaFile
  private File? betaFile
  private Str alphaText := ""
  private Str betaText := ""
  private Str alphaUri := ""
  private Str betaUri := ""
  private Int version := 1

  override Void teardown()
  {
    if (server != null)
    {
      // Quiesce real producers before deleting their inputs, even on failure.
      verify(server.awaitBackground(60sec), "acceptance teardown timed out")
      request("shutdown", Str:Obj?[:])
    }
    ws?.cleanup
  }

  private Void start(Bool lenses := true)
  {
    ws = TestWorkspace()
    alpha = ws.podName("alpha")
    beta = ws.podName("beta")
    alphaText =
      "class Base\n{\n  virtual Void close() {}\n  Void run() {}\n}\n" +
      "class Child : Base\n{\n  override Void close() {}\n  Void check()\n  {\n" +
      "    this.close()\n    super.close()\n    run()\n  }\n}\n" +
      "class Foo\n{\n  new make() {}\n  Void close() {}\n  Foo next() { this }\n  Void unrelated(Int x) { echo(x) }\n}\n" +
      "class Util\n{\n  private new create() {}\n  static Int make() { 1 }\n}\n" +
      "class Conn\n{\n  Void close(Int code) {}\n}\n" +
      "mixin Family\n{\n  abstract Void close()\n}\n"
    betaText =
      "using ${alpha}::Foo as AFoo\nusing ${alpha}::Util as AUtil\n" +
      "using ${alpha}::Conn\nusing ${alpha}::Child\n" +
      "class Foo\n{\n  new make() {}\n  Void close() {}\n}\n" +
      "class Util\n{\n  private new create() {}\n  static Str make() { \"other\" }\n}\n" +
      "class Other\n{\n  Void close(Str reason) {}\n}\n" +
      "class Main\n{\n  Int x := 9\n" +
      "  Void matrix(AFoo declared, AFoo[] list, Child child)\n  {\n" +
      "    declared.close()\n    inferred := AFoo()\n    inferred.close()\n" +
      "    declared.next().close()\n    list.each |v| { v.close() }\n" +
      "    block := AFoo() { it.close() }\n    child.run()\n" +
      "    AUtil.make()\n    ${alpha}::Util.make()\n    Util.make()\n" +
      "    local := Foo()\n    local.close()\n  }\n" +
      "  Void exact(Conn conn, Other other)\n  {\n" +
      "    conn.close(1)\n    conn.close(2)\n" +
      "    other.close(\"one\")\n    other.close(\"two\")\n    other.close(\"three\")\n  }\n" +
      "  Void m1()\n  {\n    x := 1\n    echo(x)\n    [1].each |n| { echo(x) }\n  }\n" +
      "  Void m2(Int x)\n  {\n    echo(x)\n    echo(this.x)\n  }\n" +
      "  Void scoped()\n  {\n    [1].each |Int x| { echo(x) }\n    echo(this.x)\n  }\n" +
      "  Int installed(Str s)\n  {\n    return s.size\n  }\n}\n"
    ws.buildPod(alpha, ["Types.fan": alphaText])
    ws.buildPod(beta, ["Main.fan": betaText], ["sys 1.0", "$alpha 1.0"])
    alphaFile = ws.root + `${alpha}/fan/Types.fan`
    betaFile = ws.root + `${beta}/fan/Main.fan`
    alphaUri = UriKey.toClientUri(WorkspaceManager.fileToUri(alphaFile))
    betaUri = UriKey.toClientUri(WorkspaceManager.fileToUri(betaFile))
    server = FantomLanguageServer()
    dispatcher = LspDispatcher(server)
    init := request("initialize", ["rootUri": UriKey.toClientUri(WorkspaceManager.fileToUri(ws.root)),
      "capabilities": Str:Obj?[:], "initializationOptions":
        ["envPath": [ws.root.osPath], "codeLens": ["enabled": lenses]]]) as [Str:Obj?]
    caps := init["capabilities"] as [Str:Obj?]
    verifyEq((caps["codeLensProvider"] as [Str:Obj?])["resolveProvider"], true)
    note("initialized", Str:Obj?[:])
    open(alphaUri, alphaText)
    open(betaUri, betaText)
    note("textDocument/didSave", ["textDocument": ["uri": alphaUri]])
    note("textDocument/didSave", ["textDocument": ["uri": betaUri]])
    waitFresh
  }

  ** Pump the actual dispatcher. State inspection is synchronization only:
  ** every feature assertion below is about its JSON-RPC response.
  private Void waitFresh(Duration timeout := 60sec)
  {
    deadline := Duration.now + timeout
    while (Duration.now < deadline)
    {
      request("textDocument/codeLens", ["textDocument": ["uri": betaUri]])
      fresh := server.indexComplete && [alphaFile, betaFile].all |file|
      {
        key := WorkspaceManager.fileToUri(file)
        build := server.podRegistry.podForFile(key)?.buildKey
        snap := build == null ? null : server.semanticSnapshots[build]
        text := file == alphaFile ? alphaText : betaText
        return snap != null && snap.resolved && !snap.parseFailedFiles.contains(key) &&
          snap.openText[key] == text &&
          ((server.completedGen.get(build) as Int) ?: 0) >= snap.generation
      }
      if (fresh) return
      Actor.sleep(20ms)
    }
    fail("real background lifecycle did not produce fresh two-pod snapshots in $timeout")
  }

  private [Str:Obj?] response(Str method, [Str:Obj?] params)
  {
    id := "acceptance-${++nextId}"
    r := dispatcher.dispatch(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    verifyNotNull(r, method)
    verifyEq(r["jsonrpc"], "2.0")
    verifyEq(r["id"], id)
    return r
  }

  private Obj? request(Str method, [Str:Obj?] params)
  {
    r := response(method, params)
    error := r["error"]
    verifyFalse(r.containsKey("error"), "$method: $error")
    verify(r.containsKey("result"), method)
    return r["result"]
  }

  private Void note(Str method, [Str:Obj?] params)
  {
    verifyNull(dispatcher.dispatch(["jsonrpc": "2.0", "method": method, "params": params]))
  }

  private Void open(Str uri, Str text)
  {
    note("textDocument/didOpen", ["textDocument":
      ["uri": uri, "languageId": "fantom", "version": version, "text": text]])
  }

  private Void change(Str text)
  {
    betaText = text
    note("textDocument/didChange", ["textDocument": ["uri": betaUri, "version": ++version],
      "contentChanges": [["text": text]]])
  }

  private static Position at(Str text, Str anchor, Str token)
  {
    offset := text.index(anchor) ?: throw ArgErr("Missing anchor: $anchor")
    offset += anchor.index(token) ?: throw ArgErr("Missing token $token in $anchor")
    line := 0; col := 0
    offset.times |i| { if (text[i] == '\n') { line++; col = 0 } else col++ }
    return Position(line, col)
  }

  private static [Str:Obj?] rangeAt(Str text, Str anchor, Str token)
  {
    p := at(text, anchor, token)
    return LspRange(p, Position(p.line, p.character + token.size)).toMap
  }

  private [Str:Obj?] params(Str uri, Str text, Str anchor, Str token)
  {
    ["textDocument": ["uri": uri], "position": at(text, anchor, token).toMap]
  }

  private [Str:Obj?] location(Str uri, Str text, Str anchor, Str token)
  {
    ["uri": uri, "range": rangeAt(text, anchor, token)]
  }

  private Void definition(Str uri, Str text, Str anchor, Str token,
                          Str targetUri, Str targetText, Str declaration, Str name)
  {
    actual := request("textDocument/definition", params(uri, text, anchor, token))
    expected := location(targetUri, targetText, declaration, name)
    verifyEq(actual, expected, "$anchor: actual=$actual expected=$expected")
  }

  Void testA1CollisionMatrix()
  {
    start
    ["declared.close()", "inferred.close()", "declared.next().close()",
     "v.close()", "it.close()"].each |anchor|
    {
      definition(betaUri, betaText, anchor, "close", alphaUri, alphaText,
        "Void close() {}\n  Foo next", "close")
    }
    definition(alphaUri, alphaText, "this.close()", "close", alphaUri, alphaText,
      "override Void close()", "close")
    definition(alphaUri, alphaText, "super.close()", "close", alphaUri, alphaText,
      "virtual Void close()", "close")
    definition(alphaUri, alphaText, "    run()", "run", alphaUri, alphaText, "Void run()", "run")
    definition(betaUri, betaText, "child.run()", "run", alphaUri, alphaText, "Void run()", "run")
    ["AUtil.make()", "${alpha}::Util.make()"].each |anchor|
    { definition(betaUri, betaText, anchor, "make", alphaUri, alphaText, "static Int make()", "make") }
    definition(betaUri, betaText, "Util.make()\n    local", "make", betaUri, betaText, "static Str make()", "make")
    definition(betaUri, betaText, "local := Foo()", "Foo", betaUri, betaText, "new make()", "make")
    definition(betaUri, betaText, "local.close()", "close", betaUri, betaText, "Void close()", "close")
    // Aliased constructor shorthand must bind to the declared constructor too.
    aliasParams := params(betaUri, betaText, "inferred := AFoo()", "AFoo")
    aliasResult := request("textDocument/definition", aliasParams)
    // Qualified type navigation must not hit the local Foo collision either.
    changed := betaText.replace("inferred := AFoo()", "inferred := ${alpha}::Foo()")
    change(changed)
    note("textDocument/didSave", ["textDocument": ["uri": betaUri]])
    waitFresh
    definition(betaUri, betaText, "${alpha}::Foo()", "Foo", alphaUri, alphaText, "new make()", "make")
    verifyEq(aliasResult, location(alphaUri, alphaText, "new make()", "make"),
      "aliased constructor shorthand: actual=$aliasResult")
  }

  Void testA2MethodAndClosureLocals()
  {
    start
    definition(betaUri, betaText, "echo(x)\n    [1]", "x", betaUri, betaText, "x := 1", "x")
    definition(betaUri, betaText, "|n| { echo(x)", "x", betaUri, betaText, "x := 1", "x")
    definition(betaUri, betaText, "echo(x)\n    echo(this.x)", "x", betaUri, betaText, "m2(Int x)", "x")
    definition(betaUri, betaText, "{ echo(x) }\n    echo(this.x)", "x", betaUri, betaText, "|Int x|", "x")
    definition(betaUri, betaText, "this.x)", "x", betaUri, betaText, "Int x := 9", "x")
    p := params(betaUri, betaText, "x := 1", "x")
    p["context"] = ["includeDeclaration": true]
    refs := request("textDocument/references", p) as List
    verifyEq(refs, [location(betaUri, betaText, "x := 1", "x"),
      location(betaUri, betaText, "echo(x)\n    [1]", "x"),
      location(betaUri, betaText, "|n| { echo(x)", "x")])
    p["newName"] = "localOnly"
    edits := (request("textDocument/rename", p) as [Str:Obj?])["changes"] as [Str:Obj?]
    verifyEq(edits.keys, [betaUri])
    localEdits := edits[betaUri] as List
    verifyEq(localEdits.size, 3)
    verifyEq(localEdits.map |e->Obj?| { ((Str:Obj?)e)["range"] }.sort |a,b| { a.toStr <=> b.toStr },
      refs.map |r->Obj?| { ((Str:Obj?)r)["range"] }.sort |a,b| { a.toStr <=> b.toStr })
  }

  Void testA3RankedUnknownAndDynamicReceiver()
  {
    start
    change(betaText.replace("local.close()", "missing.close()"))
    p := params(betaUri, betaText, "missing.close()", "close")
    ranked := request("textDocument/definition", p) as List
    verifyNotNull(ranked, "unknown receiver must not silently pick one symbol")
    verify(ranked.size >= 2)
    verifyEq(ranked.first, location(betaUri, betaText, "Void close()", "close"))
    verifyEq(ranked[1], location(betaUri, betaText, "Void close(Str reason)", "close"))
    verifyEq(request("textDocument/definition", p), ranked, "ranking must be stable")
    refused("textDocument/prepareRename", p, "proven")
    p["newName"] = "unsafe"
    refused("textDocument/rename", p, "proven")
    change(betaText.replace("missing.close()", "missing->close()"))
    dynamic := request("textDocument/definition", params(betaUri, betaText, "missing->close()", "close")) as List
    verifyNotNull(dynamic)
    verify(dynamic.size >= 2)
    change(betaText.replace("missing->close()", "local->close()"))
    typedDynamicParams := params(betaUri, betaText, "local->close()", "close")
    typedDynamic := request("textDocument/definition", typedDynamicParams) as List
    verifyNotNull(typedDynamic, "a known receiver type must not prove a dynamic call")
    verify(typedDynamic.size >= 2)
    refused("textDocument/prepareRename", typedDynamicParams, "proven")
    // An unparseable edited region may return a peek or nothing, not a jump.
    change(betaText.replace("local->close()", "missing.close( ???"))
    broken := request("textDocument/definition", params(betaUri, betaText, "missing.close(", "close"))
    verify(broken == null || broken is List, "unparseable unknown receiver returned an arbitrary jump")
  }

  Void testA4WorkspaceAndInstalledSource()
  {
    start
    p := params(betaUri, betaText, "conn.close(1)", "close")
    expected := location(alphaUri, alphaText, "Void close(Int code)", "close")
    verifyEq(request("textDocument/definition", p), expected)
    verifyEq(request("textDocument/declaration", p), expected)
    hover := request("textDocument/hover", p) as [Str:Obj?]
    verify((hover["contents"] as [Str:Obj?])["value"].toStr.contains("Int code"))
    installed := params(betaUri, betaText, "s.size", "size")
    raw := request("textDocument/definition", installed)
    verify(raw == null || raw is [Str:Obj?], "installed proven target must be a location or null")
    result := raw as [Str:Obj?]
    if (result != null)
    {
      file := WorkspaceManager.uriToFile((Str)result["uri"])
      verifyNotNull(file)
      verify(file.exists)
      r := result["range"] as [Str:Obj?]
      begin := r["start"] as [Str:Obj?]; end := r["end"] as [Str:Obj?]
      verifyEq(begin["line"], end["line"])
      verifyEq(file.readAllStr.splitLines[(Int)begin["line"]][(Int)begin["character"]..<(Int)end["character"]], "size")
    }
    installedHover := request("textDocument/hover", installed) as [Str:Obj?]
    verifyNotNull(installedHover, "installed hover remains available even without source")
    verify((installedHover["contents"] as [Str:Obj?])["value"].toStr.contains("size"))
    // Fixture dependency builds must never become JVM-loaded pods.
    verifyFalse(Pod.list.any |pod| { pod.name == alpha || pod.name == beta })
  }

  private Void refused(Str method, [Str:Obj?] p, Str reason)
  {
    r := response(method, p)
    error := r["error"] as [Str:Obj?]
    verifyNotNull(error)
    verifyEq(error["code"], -32803)
    verify(error["message"].toStr.contains(reason), error.toStr)
    verifyFalse(r.containsKey("result"))
  }

  Void testA5PreciseReferencesRenameHighlightAndRefusal()
  {
    start
    p := params(betaUri, betaText, "conn.close(1)", "close")
    expected := [location(betaUri, betaText, "conn.close(1)", "close"),
      location(betaUri, betaText, "conn.close(2)", "close")]
    verifyEq(request("textDocument/references", p), expected)
    highlights := request("textDocument/documentHighlight", p) as List
    verifyEq(highlights.size, 2)
    verifyEq(highlights.map |h->Obj?| { ((Str:Obj?)h)["range"] },
      expected.map |r->Obj?| { r["range"] })
    linked := request("textDocument/linkedEditingRange", p) as [Str:Obj?]
    ranges := linked["ranges"] as List
    verifyEq(ranges.size, expected.size)
    ranges.each |r, i| { verifyEq(r, expected[i]["range"]) }
    prepared := request("textDocument/prepareRename", p) as [Str:Obj?]
    verifyEq(prepared["range"], expected.first["range"])
    verifyEq(prepared["placeholder"], "close")
    p["context"] = ["includeDeclaration": true]
    refs := request("textDocument/references", p) as List
    verifyEq(refs.size, 3)
    verify(refs.contains(location(alphaUri, alphaText, "Void close(Int code)", "close")))
    p["newName"] = "finish"
    changes := (request("textDocument/rename", p) as [Str:Obj?])["changes"] as [Str:Obj?]
    verifyEq(changes.keys.sort, [alphaUri, betaUri].sort)
    verifyEq((changes[alphaUri] as List).size, 1)
    verifyEq((changes[betaUri] as List).size, 2)
    changes.each |value, uri|
    {
      (value as List).each |e|
      {
        edit := e as [Str:Obj?]
        verifyEq(edit["newText"], "finish")
        verify(refs.any |r|
        {
          loc := r as [Str:Obj?]
          return loc["uri"] == uri && loc["range"] == edit["range"]
        }, "rename edit not present in exact references: $uri $edit")
      }
    }
    ["virtual Void close()", "override Void close()", "abstract Void close()"].each |anchor|
    {
      family := params(alphaUri, alphaText, anchor, "close")
      refused("textDocument/prepareRename", family, "famil")
      family["newName"] = "finish"
      refused("textDocument/rename", family, "famil")
    }
    refused("textDocument/prepareRename", params(betaUri, betaText, "s.size", "size"), "external")
    inherited := params(alphaUri, alphaText, "Void run()", "run")
    refused("textDocument/prepareRename", inherited, "workspace subtype")
    inherited["newName"] = "execute"
    refused("textDocument/rename", inherited, "workspace subtype")
  }

  Void testA5IncompleteWholeWorkspaceCoverageRefusesSlotRename()
  {
    start
    // An unrelated source region without the target spelling still blocks the
    // whole-workspace subtype audit. No state/snapshot injection is involved.
    badText := betaText.replace("Int x := 9", "UnknownType x := 9")
    betaFile.out.print(badText).close // disk retry must not restore valid coverage
    change(badText)
    note("textDocument/didSave", ["textDocument": ["uri": betaUri]])
    verify(server.awaitBackground(60sec))
    p := params(alphaUri, alphaText, "Void close(Int code)", "close")
    before := server.semanticCompileCount
    refused("textDocument/prepareRename", p, "coverage")
    verifyEq(server.semanticCompileCount, before, "prepareRename must not compile")
    p["newName"] = "finish"
    refused("textDocument/rename", p, "semantic index unavailable")
  }

  Void testA6LazyClickablePreciseLensesAndConfiguration()
  {
    start
    lenses := request("textDocument/codeLens", ["textDocument": ["uri": alphaUri]]) as List
    verify(!lenses.isEmpty)
    verify(lenses.all |l| { !((Str:Obj?)l).containsKey("command") && ((Str:Obj?)l).containsKey("data") })
    lens := lenses.find |l| { (((Str:Obj?)l)["data"] as [Str:Obj?])["key"] == "$alpha::Conn.close" } as [Str:Obj?]
    verifyNotNull(lens)
    resolved := request("codeLens/resolve", lens) as [Str:Obj?]
    command := resolved["command"] as [Str:Obj?]
    verifyEq(command["title"], "2 references")
    verifyEq(command["command"], "fantom.showReferences")
    args := command["arguments"] as List
    verifyEq(args[0], alphaUri)
    verifyEq(args[1], at(alphaText, "Void close(Int code)", "close").toMap)
    verifyEq(args[2], request("textDocument/references", params(betaUri, betaText, "conn.close(1)", "close")))
    verifyFalse(lens.containsKey("command"), "resolving must not mutate the unresolved input")
    note("workspace/didChangeConfiguration", ["settings": ["fantom": ["codeLens": ["enabled": false]]]])
    verifyEq((request("textDocument/codeLens", ["textDocument": ["uri": alphaUri]]) as List).size, 0)
    note("workspace/didChangeConfiguration", ["settings": ["fantom": ["codeLens": ["enabled": true]]]])
    verifyEq((request("textDocument/codeLens", ["textDocument": ["uri": alphaUri]]) as List).size, lenses.size)
    change(betaText.replace("conn.close(2)", "conn.close(3)"))
    request("codeLens/resolve", lens) // stale coverage must not produce an internal error
    note("textDocument/didSave", ["textDocument": ["uri": betaUri]])
    request("codeLens/resolve", lens) // likewise while the real compile runs
    waitFresh
    verifyEq(((request("codeLens/resolve", lens) as [Str:Obj?])["command"] as [Str:Obj?])["title"], "2 references")
  }

  Void testA6DisabledAtInitialize()
  {
    start(false)
    verifyEq((request("textDocument/codeLens", ["textDocument": ["uri": alphaUri]]) as List).size, 0)
  }

  ** The 300-file/500-message stress scenario extended to every migrated feature plus
  ** completion/tokens. No fabricated lens or hierarchy item, no direct calls.
  Void testA7FullFeatureConcurrencyStress()
  {
    start
    callParams := params(betaUri, betaText, "conn.close(1)", "close")
    localParams := params(betaUri, betaText, "x := 1", "x")
    localParams["newName"] = "safeLocal"
    typeParams := params(alphaUri, alphaText, "class Child", "Child")
    callItem := ((List)request("textDocument/prepareCallHierarchy", callParams)).first as [Str:Obj?]
    typeItem := ((List)request("textDocument/prepareTypeHierarchy", typeParams)).first as [Str:Obj?]
    verifyNotNull(callItem); verifyNotNull(typeItem)
    lenses := request("textDocument/codeLens", ["textDocument": ["uri": alphaUri]]) as List
    lens := lenses.find |l| { (((Str:Obj?)l)["data"] as [Str:Obj?])["key"] == "$alpha::Conn.close" } as [Str:Obj?]
    verifyNotNull(lens)

    generated := Str:Str[:]
    300.times |i|
    {
      generated["Gen${i}.fan"] = "class Gen$i\n{\n  Int value := $i\n" +
        "  Int read() { value }\n  Void go() { x := read(); echo(x) }\n}\n"
    }
    stressDir := ws.writePod(ws.podName("stress"), generated)
    stressBuild := WorkspaceManager.fileToUri(stressDir + `build.fan`)
    note("workspace/didChangeWorkspaceFolders", ["event": ["added": List[,], "removed": List[,]]])
    verifyFalse(server.indexComplete, "background reindex must be active")
    note("textDocument/didSave", ["textDocument": ["uri": betaUri]])
    baseText := betaText
    requests := Str:Int[:]
    responses := 0; expectedRefusals := 0; notifications := 0
    indexApplies := 0; snapshotApplies := 0; activeCompileDispatches := 0
    compileBefore := server.semanticCompileCount
    500.times |n|
    {
      if (n % 50 == 0) Env.cur.err.printLine("[mixed stress] progress=$n")
      // Do not let the initial client pacing consume a whole index generation
      // before the first dispatch. Subsequent pacing permits real producers.
      if (n > 0) Actor.sleep(3ms)
      entriesBefore := server.symbolTable.allEntries.size
      ticksBefore := server.lastBackgroundApplyTicks
      generationsBefore := server.semanticSnapshots.map |s->Int| { s.generation }
      completedBefore := server.compileCompleted.val
      method := ""
      p := callParams
      switch (n % 25)
      {
        case 0: method = "textDocument/codeLens"; p = ["textDocument": ["uri": alphaUri]]
        case 1: method = "codeLens/resolve"; p = lens
        case 2: method = "textDocument/definition"
        case 3: method = "textDocument/declaration"
        case 4: method = "textDocument/typeDefinition"
        case 5: method = "textDocument/implementation"
        case 6: method = "textDocument/hover"
        case 7:
          method = "textDocument/signatureHelp"
          pos := at(betaText, "conn.close(1)", "close")
          p = ["textDocument": ["uri": betaUri], "position": Position(pos.line, pos.character+6).toMap]
        case 8: method = "textDocument/references"
        case 9: method = "textDocument/documentHighlight"
        case 10: method = "textDocument/linkedEditingRange"
        case 11: method = "textDocument/prepareRename"; p = localParams
        case 12: method = "textDocument/rename"; p = localParams
        case 13: method = "textDocument/prepareCallHierarchy"
        case 14: method = "callHierarchy/incomingCalls"; p = ["item": callItem]
        case 15: method = "callHierarchy/outgoingCalls"; p = ["item": callItem]
        case 16: method = "textDocument/prepareTypeHierarchy"; p = typeParams
        case 17: method = "typeHierarchy/supertypes"; p = ["item": typeItem]
        case 18: method = "typeHierarchy/subtypes"; p = ["item": typeItem]
        case 19: method = "workspace/symbol"; p = ["query": "Gen"]
        case 20: method = "textDocument/completion"
        case 21: method = "textDocument/semanticTokens/full"; p = ["textDocument": ["uri": betaUri]]
        case 22:
          method = "textDocument/prepareRename"
          p = params(alphaUri, alphaText, "virtual Void close()", "close")
        case 23:
          change(baseText + "// stress edit $n\n")
          notifications++
        case 24:
          // A bounded burst exercises coalescing; no 300-file compile per key.
          note("textDocument/didSave", ["textDocument": ["uri": betaUri]])
          notifications++
      }
      if (!method.isEmpty)
      {
        began := Duration.now
        requests[method] = (requests[method] ?: 0) + 1
        responses++
        if (n % 25 == 22)
        {
          refused(method, p, "famil")
          expectedRefusals++
        }
        else
        {
          result := request(method, p) // every ordinary response has zero errors
          if (n % 25 == 0)
          {
            available := result as List
            lens = available.find |l| { (((Str:Obj?)l)["data"] as [Str:Obj?])["key"] == "$alpha::Conn.close" } as [Str:Obj?]
            verifyNotNull(lens)
          }
          if (n % 25 == 12)
          {
            edits := (result as [Str:Obj?])["changes"] as [Str:Obj?]
            verifyEq(edits.keys, [betaUri])
            verifyEq((edits[betaUri] as List).size, 3)
          }
        }
        elapsed := Duration.now - began
        if (elapsed > 500ms) Env.cur.err.printLine("[mixed stress] slow n=$n method=$method duration=$elapsed")
        verify(elapsed < 30sec,
          "mixed stress cannot finish its 500 messages: n=$n method=$method duration=$elapsed responses=$responses refusals=$expectedRefusals notifications=$notifications counts=$requests indexApplies=$indexApplies snapshotApplies=$snapshotApplies activeCompileDispatches=$activeCompileDispatches")
      }
      if (!server.indexComplete && server.lastBackgroundApplyTicks != ticksBefore &&
          server.symbolTable.allEntries.size > entriesBefore) indexApplies++
      server.semanticSnapshots.each |s, key|
      { if (s.generation > (generationsBefore[key] ?: 0)) snapshotApplies++ }
      if (server.semanticCompileCount > server.compileCompleted.val ||
          server.compileCompleted.val > completedBefore) activeCompileDispatches++
    }
    verifyEq(responses, 460)
    verifyEq(expectedRefusals, 20)
    verifyEq(notifications, 40)
    verifyEq(requests.size, 22)
    verifyEq(requests["textDocument/prepareRename"], 40)
    verify(requests.vals.all |count| { count == 20 || count == 40 })
    verify(indexApplies > 0, "no partial indexing batch applied mid-loop")
    verify(snapshotApplies > 0, "no real semantic snapshot applied mid-loop")
    verify(activeCompileDispatches > 0, "no dispatch overlapped real compiler work")
    verifyNotNull(server.semanticSnapshots[stressBuild], "generated pod must compile during the mixed loop")
    verify(server.awaitBackground(60sec))
    Env.cur.err.printLine("[mixed stress] messages=500 responses=$responses success=${responses-expectedRefusals} expectedRefusals=$expectedRefusals notifications=$notifications methods=$requests indexApplies=$indexApplies snapshotApplies=$snapshotApplies activeCompileDispatches=$activeCompileDispatches compiles=${server.semanticCompileCount-compileBefore}")
  }

  Void testA8EncodedUriRoundTripWithoutDuplicateIndexing()
  {
    start
    key := WorkspaceManager.fileToUri(betaFile)
    if (Env.cur.os == "win32") verify(betaUri.contains("%3A"), "fixture must exercise an encoded Windows drive")
    // The disk index and client-open buffer refer to exactly one physical file.
    symbols := request("workspace/symbol", ["query": "Main"]) as List
    mains := symbols.findAll |s| { ((Str:Obj?)s)["name"] == "Main" }
    verifyEq(mains.size, 1)
    verifyEq((((Str:Obj?)mains.first)["location"] as [Str:Obj?])["uri"], betaUri)
    p := params(key, betaText, "Void m2(Int x)", "x")
    verifyEq(request("textDocument/definition", p), location(betaUri, betaText, "m2(Int x)", "x"))
    // Re-open under the decoded/upper-drive variant; this must replace, not add.
    variant := key
    if (Env.cur.os == "win32") variant = "file:///" + key[8..8].upper + key[9..-1]
    version++
    open(variant, betaText)
    betaUri = variant
    note("textDocument/didSave", ["textDocument": ["uri": betaUri]])
    waitFresh
    verifyEq(request("textDocument/definition", p), location(betaUri, betaText, "m2(Int x)", "x"))
    symbols = request("workspace/symbol", ["query": "Main"]) as List
    mains = symbols.findAll |s| { ((Str:Obj?)s)["name"] == "Main" }
    verifyEq(mains.size, 1)
    verifyEq((((Str:Obj?)mains.first)["location"] as [Str:Obj?])["uri"], betaUri)
    p = params(key, betaText, "conn.close(1)", "close")
    verifyEq((request("textDocument/references", p) as List).size, 2)
    p["newName"] = "finish"
    edits := (request("textDocument/rename", p) as [Str:Obj?])["changes"] as [Str:Obj?]
    verify(edits.containsKey(betaUri))
    verifyEq(edits.size, 2)
    verifyEq((edits[betaUri] as List).size, 2)
  }
}
