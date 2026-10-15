using concurrent

**
** THREADING INVARIANT (plan 7.3, T02)
** ===================================
** `SymbolTable`, `ReferenceIndex`, `TypeResolver`, `TextDocumentManager` /
** `DocumentState`, the compiler-diagnostics cache in `DiagnosticsProvider`,
** `WorkspaceManager` folders and every other mutable field of this class are
** read and written ONLY on the main (dispatch) thread: inside
** `LspDispatcher.dispatch` or the `LspMainLoop` idle tick.
**
** Background actors are pure producers. They receive immutable inputs
** (`IndexRequest`, `CompileRequest`), never hold a reference to this server,
** and hand results to the main thread only through `mailbox`:
**   - `IndexActor` posts `IndexBatch`es (about 50 parsed files, wrapped in
**     `Unsafe` and never touched again by the producer) tagged with an index
**     generation; batches from a superseded generation are dropped.
**   - `SemanticCompileActor` posts immutable per-build results. Diagnostics
**     are content-stamp guarded here, not published by the producer.
** `applyBackgroundResults` (first step of every dispatch and of every 200 ms
** idle tick) drains the mailbox and applies results on the main thread. Only
** the main thread publishes, and every outgoing message leaves through the
** single path `enqueueOutgoing` (StdioWriteActor, or the test outbox).
** Exception: the stdin reader may mark `cancelTokens` before handing a frame
** to the main thread. It holds only that concurrent map, never this server.
**
class FantomLanguageServer
{
  TextDocumentManager docManager := TextDocumentManager()
  WorkspaceManager workspaceManager := WorkspaceManager()
  DiagnosticsProvider diagnosticsProvider
  HoverProvider hoverProvider := HoverProvider()
  DefinitionProvider definitionProvider := DefinitionProvider()
  TypeHierarchyProvider typeHierarchyProvider := TypeHierarchyProvider()
  ReferencesProvider referencesProvider := ReferencesProvider()
  CompletionProvider completionProvider := CompletionProvider()
  SignatureHelpProvider signatureHelpProvider := SignatureHelpProvider()
  WorkspaceSymbolProvider workspaceSymbolProvider := WorkspaceSymbolProvider()
  FormattingProvider formattingProvider := FormattingProvider()
  DocumentLinkProvider documentLinkProvider := DocumentLinkProvider()
  RenameProvider renameProvider := RenameProvider()
  CodeActionProvider codeActionProvider := CodeActionProvider()
  SemanticTokensProvider semanticTokensProvider := SemanticTokensProvider()
  CallHierarchyProvider callHierarchyProvider := CallHierarchyProvider()
  DocumentHighlightProvider documentHighlightProvider := DocumentHighlightProvider()
  FoldingRangeProvider foldingRangeProvider := FoldingRangeProvider()
  InlayHintProvider inlayHintProvider := InlayHintProvider()
  SelectionRangeProvider selectionRangeProvider := SelectionRangeProvider()
  LinkedEditingRangeProvider linkedEditingRangeProvider := LinkedEditingRangeProvider()
  private [Str:Obj?] codeLensOptions := ["codeLens": ["enabled": true]]
  private CodeLensProvider? lazyCodeLensProvider
  CodeLensProvider codeLensProvider()
  {
    if (lazyCodeLensProvider == null)
      lazyCodeLensProvider = CodeLensProvider(resolver, |Str key->Str| { clientUri(key) }, codeLensOptions)
    return lazyCodeLensProvider
  }
  SymbolTable symbolTable
  TypeResolver typeResolver := TypeResolver()
  PodRegistry podRegistry := PodRegistry()
  PodLookup podLookup := PodLookup()
  private Str[] configuredEnvPath := Str[,]
  ReferenceIndex referenceIndex := ReferenceIndex()

  Bool isShutdown := false
  Bool clientWorkDone := false
  Str[]? workspaceFolders
  Str bracketStyle := "allman"
  internal const ConcurrentMap cancelTokens := ConcurrentMap()
  private ActorPool indexPool := ActorPool()
  private ActorPool compilePool := ActorPool()
  StdioWriteActor? stdioWriter

  ** Thread-safe: canonical key -> content stamp of the open document. The
  ** stamp is a server-local counter bumped on every open/change/save-text, so
  ** a re-open with a reused client version can never match an old compile.
  ** Written only by the main thread; guards results on the main thread.
  const ConcurrentMap docVersions := ConcurrentMap()

  ** The only channel from background producers to the main thread.
  const Mailbox mailbox

  ** Shared with `IndexActor` so a superseded producer stops early. The main
  ** thread still drops every batch whose generation is not current.
  private const AtomicInt currentIndexGen := AtomicInt(0)

  ** Legacy completion counter; freshness uses per-build completedGen.
  const AtomicInt compileCompleted := AtomicInt(0)

  private const IndexActor indexActor
  private const SemanticCompileActor compileActor
  const ConcurrentMap completedGen := ConcurrentMap()
  ** Main-thread semantic store; duplicate pod names remain independent.
  Str:SemanticSnapshot semanticSnapshots := [:] { private set }
  private Str:Int requestedGen := [:]
  private Str:Int appliedSemanticGen := [:]
  ** Lifecycle tombstones reject in-flight results after deletion/removal.
  private Str:Int invalidSemanticGen := [:]
  private Int scheduledPriority := 1
  private const AtomicInt warmRefreshGeneration := AtomicInt(0)
  private Str:Int warmRefreshWanted := [:]
  Bool backgroundCompile := true { private set }
  Bool clientCodeLensRefresh := false { private set }
  Int semanticCompileCount() { compileActor.compileCount.val }

  // ---- main-thread state (see header invariant) ----
  ** Generation of the most recently started index.
  Int indexGeneration := 0 { private set }
  ** Generation whose final batch has been applied.
  Int indexedGeneration := 0 { private set }
  ** Last compile request sequence sent.
  Int compileRequested := 0 { private set }
  private Int drainedCount := 0
  private Int stampCounter := 0
  private Str:Bool indexedKeys := [:]
  ** key -> `Duration.now.ticks` of the newest main-thread disk observation.
  private Str:Int diskEventTicks := [:]
  private Str:Bool pendingPublish := [:]
  ** Outgoing messages when no `stdioWriter` is attached (tests).
  private [Str:Obj?][] outbox := [,]

  new make()
  {
    symbolTable = SymbolTable(workspaceManager)
    typeResolver.podRegistry = podRegistry
    diagnosticsProvider = DiagnosticsProvider(docManager)
    mailbox = Mailbox(indexPool)
    indexActor = IndexActor(indexPool, mailbox, currentIndexGen)
    compileActor = SemanticCompileActor(compilePool, mailbox, completedGen, compileCompleted)
  }

  ** True when the latest started index generation has been fully applied.
  Bool indexComplete() { indexedGeneration == indexGeneration }

  ** Preserve an open document's exact client spelling at protocol boundaries.
  Str clientUri(Str key)
  {
    return docManager.getDocument(key)?.originalUri ?: UriKey.toClientUri(key)
  }

  ** Dispatch-thread facade; retain it so the bounded fallback LRU is reused.
  private SymbolResolver? symbolResolver
  SymbolResolver resolver()
  {
    if (symbolResolver == null) symbolResolver = SymbolResolver(this)
    return symbolResolver
  }

  [Str:Obj?] initialize([Str:Obj?] params)
  {
    Env.cur.err.printLine("[fantomLsp] Initialize request received")

    initOpts := params["initializationOptions"] as [Str:Obj?]
    lensOpts := initOpts?.get("codeLens") as [Str:Obj?]
    if (lensOpts?.get("enabled") is Bool)
      codeLensOptions["codeLens"] = ["enabled": lensOpts["enabled"]]
    semanticOpts := initOpts?.get("semanticIndex") as [Str:Obj?]
    if (semanticOpts?.get("backgroundCompile") is Bool)
      backgroundCompile = semanticOpts["backgroundCompile"]
    max := initOpts?.get("maxFiles")
    if (max is Num) workspaceManager.maxFiles = ((Num)max).toInt.max(0)
    dirs := initOpts?.get("excludeDirs")
    if (dirs is List)
    {
      names := Str[,]
      ((List)dirs).each |d|
      {
        if (d is Str && !((Str)d).isEmpty) names.add((Str)d)
      }
      if (!names.isEmpty) workspaceManager.excludeDirs = names
    }

    capsIn := params["capabilities"] as [Str:Obj?]
    workspaceCaps := capsIn?.get("workspace") as [Str:Obj?]
    lensCaps := workspaceCaps?.get("codeLens") as [Str:Obj?]
    clientCodeLensRefresh = lensCaps?.get("refreshSupport") == true
    windowCaps := capsIn?.get("window") as [Str:Obj?]
    wp := windowCaps?.get("workDoneProgress")
    clientWorkDone = wp == true

    rootUri := params["rootUri"] as Str
    if (rootUri != null)
    {
      rootUri = UriKey.canonical(rootUri)
      workspaceFolders = Str[rootUri]
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
          uri = UriKey.canonical(uri)
          workspaceManager.addFolder(uri)
          if (workspaceFolders == null) workspaceFolders = Str[,]
          if (!workspaceFolders.contains(uri)) workspaceFolders.add(uri)
        }
      }
    }

    envPaths := initOpts?.get("envPath") as List
    if (envPaths != null)
      configuredEnvPath = envPaths.findAll |p| { p is Str }.map |p->Str| { (Str)p }
    configureNamespace

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
      true,   // semanticTokens
      true    // callHierarchy
    )

    return [
      "capabilities": caps,
      "serverInfo": [
        "name": "Fantom Language Server",
        "version": Pod.of(this).version.toStr,
      ],
    ]
  }

  Void initialized([Str:Obj?] params)
  {
    Env.cur.err.printLine("[fantomLsp] Server initialized")
    startIndex
  }

  ** Main-thread service; future compiler actors receive envPath as immutable
  ** input and construct a fresh LspNamespace for each CompilerInput.ns (T04b).
  private Void configureNamespace()
  {
    // D6: launch/runtime roots never become workspace overrides. In particular,
    // removing a configured root must not resurrect it from the process env.
    roots := LspNamespace.pathRoots(configuredEnvPath)
    folders := File[,]
    workspaceManager.getFolders.each |uri|
    {
      f := WorkspaceManager.uriToFile(uri)
      if (f != null) folders.add(f)
    }
    LspNamespace.detectRoots(folders).each |r| { if (!roots.contains(r)) roots.add(r) }
    // Extension server and installed runtime belong only to JVM resolution.
    runtimeRoots := Env.cur.path.map |r->File| { r.normalize }
    roots = roots.exclude |r| { runtimeRoots.contains(r.normalize) }
    podLookup.configure(roots)
    podLookup.install
    podLookup.logEnvironment
  }

  **
  ** Start a new background index generation over the current folders. Any
  ** in-flight generation is superseded: its remaining batches are dropped.
  **
  Int startIndex()
  {
    warmRefreshGeneration.increment
    warmRefreshWanted.clear
    gen := ++indexGeneration
    currentIndexGen.val = gen
    indexActor.send(IndexRequest(gen, workspaceManager.getFolders,
      workspaceManager.excludeDirs, workspaceManager.maxFiles))
    return gen
  }

  ** Synchronous main-thread index (tests and synchronous paths). Supersedes
  ** any in-flight background generation.
  Void indexWorkspaceNow()
  {
    warmRefreshGeneration.increment
    warmRefreshWanted.clear
    gen := ++indexGeneration
    currentIndexGen.val = gen
    Env.cur.err.printLine("[fantomLsp] Indexing workspace folders: ${workspaceManager.getFolders}")
    workspaceManager.collectFiles.each |file|
    {
      if (docManager.getDocument(file.key) != null) return
      entry := WorkspaceManager.parseIndexFile(file)
      if (entry != null) applyIndexEntry(entry)
    }
    indexedGeneration = gen
    podRegistry.rebuild(workspaceManager)
    warmSemanticIndex
    Env.cur.err.printLine("[fantomLsp] Indexing complete. Symbols indexed for ${symbolTable.allEntries.size} entries")
  }

  **
  ** The single outgoing path for every server-originated message (responses,
  ** notifications, server requests). Main thread only. The message is encoded
  ** here, so the writer thread only ever sees an immutable `Str`.
  ** Without a `stdioWriter` (tests) messages are kept in an outbox.
  **
  Void enqueueOutgoing([Str:Obj?] msg)
  {
    writer := stdioWriter
    if (writer != null) writer.send(JsonRpc.encode(msg))
    else outbox.add(msg)
  }

  ** Test/legacy accessor: take and clear the outbox (main thread only).
  [Str:Obj?][] drainOutgoing()
  {
    result := outbox.dup
    outbox.clear
    return result
  }

  **
  ** Request background compiler diagnostics for every open document. Main
  ** thread: builds an immutable snapshot of all open buffers and their stamps.
  **
  virtual Void scheduleCompilerDiagnostics(Str triggerUri)
  {
    requestSemanticCompile(triggerUri, scheduledPriority)
  }

  ** Keep the established virtual scheduling hook for embedders/tests, while
  ** carrying low priority on main-owned state only during this synchronous call.
  private Void scheduleLowPriorityCompile(Str uri)
  {
    scheduledPriority = 2
    try { scheduleCompilerDiagnostics(uri) }
    finally { scheduledPriority = 1 }
  }

  ** Request one pod, freezing every open overlay belonging to that build.
  ** Refresh intent is independent of queue priority: explicit/open/save work
  ** keeps refreshes, while unrelated warm-up builds only populate the index.
  Int requestSemanticCompile(Str key, Int priority := 1, Bool refreshCodeLens := true)
  {
    if (isShutdown) return 0
    key = UriKey.canonical(key)
    parser := CompilerDiagnostics()
    pod := podRegistry.byBuildKey(key) ?: podRegistry.podForFile(key)
    build := pod?.buildFan ?: parser.findBuildFan(key)
    if (build != null && !build.exists) return 0
    if (build == null && docManager.getDocument(key) == null)
    {
      source := WorkspaceManager.uriToFile(key)
      if (source == null || !source.exists) return 0
    }
    buildKey := build == null ? key : WorkspaceManager.fileToUri(build)
    name := pod?.podName ?: (build == null ? "lspStandalone" : parser.parsePodName(build))
    if (name == null) return 0
    files := build == null ? Str[key] : Str[,]
    dirs := pod?.srcDirs ?: (build == null ? File[,] : parser.parseSrcDirs(build))
    texts := Str:Str[:]
    stamps := Str:Int[:]
    docManager.openUris.each |docKey|
    {
      if (build == null)
      {
        if (docKey != key) return
      }
      else
      {
        owner := podRegistry.podForFile(docKey)
        if (owner != null)
        {
          if (owner.buildKey != buildKey) return
        }
        else
        {
          ownerFile := parser.findBuildFan(docKey)
          if (ownerFile == null || WorkspaceManager.fileToUri(ownerFile) != buildKey) return
        }
        if (!dirs.any |dir|
        {
          file := WorkspaceManager.uriToFile(docKey)
          return file != null && file.ext == "fan" && file.parent.normalize == dir.normalize
        }) return
      }
      doc := docManager.getDocument(docKey)
      stamp := docVersions.get(docKey) as Int
      if (doc == null || stamp == null) return
      texts[docKey] = doc.text; stamps[docKey] = stamp
    }
    gen := ++compileRequested
    requestedGen[buildKey] = gen
    compileActor.request(SemanticCompileRequest(gen, buildKey, name, build,
      files, texts, stamps, podLookup.envPath, priority, stdioWriter,
      clientCodeLensRefresh && refreshCodeLens, dirs))
    return gen
  }

  private Void warmSemanticIndex()
  {
    warmRefreshGeneration.increment
    warmRefreshWanted.clear
    if (!backgroundCompile) return
    pods := podRegistry.allPods
    openBuilds := docManager.openUris.map |key->Str| { semanticBuildKey(key) }.unique
    pods.sort |a, b|
    {
      ar := openBuilds.contains(a.buildKey) ? 0 : 1
      br := openBuilds.contains(b.buildKey) ? 0 : 1
      return ar == br ? a.buildKey <=> b.buildKey : ar <=> br
    }.each |pod|
    {
      relevant := openBuilds.contains(pod.buildKey)
      gen := requestSemanticCompile(pod.buildKey, relevant ? 1 : 2, relevant)
      if (gen > 0) warmRefreshWanted[pod.buildKey] = gen
    }
  }

  ** Main-thread completion barrier includes failed jobs, not just snapshots.
  ** Drain all posted results before notifying so lazy counts see the final store.
  private Void refreshCompletedWarmup()
  {
    // Closing the last document also invalidates a delayed final notification.
    if (docManager.openUris.isEmpty) warmRefreshGeneration.increment
    if (warmRefreshWanted.isEmpty) return
    if (!warmRefreshWanted.all |gen, key| { ((completedGen.get(key) as Int) ?: 0) >= gen }) return
    // Workers post before setting completedGen; check the mailbox AFTER the
    // completion barrier so the last result cannot race this drain check.
    if (mailbox.hasPending) return
    warmRefreshWanted.clear
    if (isShutdown || !clientCodeLensRefresh || docManager.openUris.isEmpty || stdioWriter == null) return
    compileActor.refresh(SemanticRefreshRequest(stdioWriter, warmRefreshGeneration,
      warmRefreshGeneration.val))
  }

  ** Build identities, not pod names. Completion is checked per build because
  ** priority can finish later sequence numbers before earlier warm-up work.
  Bool ensureFresh(Str[] buildKeys, Duration timeout := 10sec, Obj? requestId := null)
  {
    wanted := Str:Int[:]
    keys := buildKeys.unique
    for (i := 0; i < keys.size; i++)
    {
      key := UriKey.canonical(keys[i])
      key = semanticBuildKey(key)
      gen := requestSemanticCompile(key, 0)
      if (gen == 0) return false
      wanted[key] = gen
    }
    deadline := Duration.now + timeout.min(10sec)
    while (true)
    {
      if (isCancelled(requestId)) return false
      if (wanted.all |gen, key| { ((completedGen.get(key) as Int) ?: 0) >= gen })
      {
        applyBackgroundResults
        return wanted.all |gen, key| { (semanticSnapshots[key]?.generation ?: 0) >= gen }
      }
      if (Duration.now >= deadline) { applyBackgroundResults; return false }
      Actor.sleep(100ms)
    }
    return false
  }

  ** Main thread: immutable snapshot of every open buffer, trigger first.
  ** Pure with respect to server state (does not count as a sent request).
  CompileRequest buildCompileRequest(Str triggerUri)
  {
    trigger := UriKey.canonical(triggerUri)
    texts := Str:Str[:] { ordered = true }
    stamps := Str:Int[:]
    keys := docManager.openUris.sort
    if (keys.contains(trigger)) { keys.remove(trigger); keys.insert(0, trigger) }
    keys.each |key|
    {
      doc := docManager.getDocument(key)
      stamp := docVersions.get(key) as Int
      if (doc == null || stamp == null) return
      texts[key] = doc.text
      stamps[key] = stamp
    }
    return CompileRequest(compileRequested + 1, trigger, texts, stamps)
  }

  ** Synchronous main-thread compile of every open document (legacy/test path).
  Void publishCompilerDiagnostics(Str triggerUri)
  {
    triggerUri = UriKey.canonical(triggerUri)
    uris := Str[,]
    if (docManager.getDocument(triggerUri) != null) uris.add(triggerUri)
    docManager.openUris.each |otherUri|
    {
      if (otherUri != triggerUri) uris.add(otherUri)
    }
    uris.each |uri|
    {
      diagnosticsProvider.setCompilerDiagnostics(uri, diagnosticsProvider.computeCompilerDiagnostics(uri))
      publishMerged(uri)
    }
  }

  //////////////////////////////////////////////////////////////////////////
  // Background results (main thread only)
  //////////////////////////////////////////////////////////////////////////

  ** `Duration.now.ticks` of the last time a background result was applied.
  Int lastBackgroundApplyTicks := 0 { private set }

  **
  ** Drain the mailbox and apply every background result, then publish any
  ** pending merged diagnostics. Called first in every `LspDispatcher.dispatch`
  ** and on every idle tick of the main loop. Returns the number of messages
  ** applied. Main thread only.
  **
  Int applyBackgroundResults()
  {
    applied := 0
    if (mailbox.hasPending)
    {
      mailbox.drain.each |msg|
      {
        try
        {
          if (applyBackgroundMessage(msg)) applied++
        }
        catch (Err e)
        {
          Env.cur.err.printLine("[fantomLsp] Failed to apply background result: $e")
          e.trace(Env.cur.err)
        }
      }
      if (applied > 0) lastBackgroundApplyTicks = Duration.now.ticks
    }
    flushPendingPublishes
    refreshCompletedWarmup
    return applied
  }

  **
  ** Test helper (main thread): apply background results until the latest index
  ** generation and every requested compile have completed, or until timeout.
  **
  Bool awaitBackground(Duration timeout := 30sec)
  {
    deadline := Duration.now + timeout
    while (true)
    {
      applyBackgroundResults
      if (indexComplete && requestedGen.all |gen, key| { ((completedGen.get(key) as Int) ?: 0) >= gen } && !mailbox.hasPending)
        return true
      if (Duration.now > deadline) return false
      Actor.sleep(10ms)
    }
    return false
  }

  private Bool applyBackgroundMessage(Obj? msg)
  {
    if (msg is IndexBatch) return applyIndexBatch(msg)
    if (msg is CompileResult) return applyCompileResult(msg)
    if (msg is SemanticCompileResult) return applySemanticCompileResult(msg)
    Env.cur.err.printLine("[fantomLsp] Unknown mailbox message: $msg")
    return false
  }

  private Bool applyIndexBatch(IndexBatch batch)
  {
    if (batch.generation != indexGeneration) return false  // superseded generation
    entries := batch.entries.val as IndexEntry[] ?: IndexEntry[,]
    entries.each |entry|
    {
      if (docManager.getDocument(entry.key) != null) return    // open buffer is authoritative
      if (workspaceManager.folderFor(entry.key) == null) return // folder was removed
      seen := diskEventTicks[entry.key]
      if (seen != null && seen >= entry.readTicks) return       // a fresher disk read won
      applyIndexEntry(entry)
    }
    if (batch.isFinal)
    {
      indexedGeneration = batch.generation
      podRegistry.rebuild(workspaceManager)
      warmSemanticIndex
      Env.cur.err.printLine("[fantomLsp] Workspace index complete (generation ${batch.generation}); ${symbolTable.allEntries.size} symbol entries")
    }
    return true
  }

  private Bool applyCompileResult(CompileResult result)
  {
    result.diagnostics.each |diags, key|
    {
      // Only a result compiled from the document's current content is accepted.
      if (docManager.getDocument(key) == null) return
      if (docVersions.get(key) != result.stamps[key]) return
      diagnosticsProvider.setCompilerDiagnostics(key, diags)
      pendingPublish[key] = true
    }
    return true
  }

  private Bool applySemanticCompileResult(SemanticCompileResult result)
  {
    if (isShutdown || result.generation <= (invalidSemanticGen[result.buildKey] ?: 0)) return false
    old := semanticSnapshots[result.buildKey]
    if ((appliedSemanticGen[result.buildKey] ?: 0) <= result.generation)
    {
      appliedSemanticGen[result.buildKey] = result.generation
      if (result.snapshot != null) semanticSnapshots[result.buildKey] = result.snapshot
      else if (old != null)
        semanticSnapshots[result.buildKey] = SemanticSnapshot(old.podName, old.generation,
          old.fileHash, old.openText, old.occByFile, old.decls, old.occByKey,
          (old.parseFailedFiles.dup.addAll(result.failedFiles)).unique, old.resolved)
    }
    // The compatibility cache/publish path is main-owned and content-stamp
    // guarded, including close/reopen with a reused client document version.
    return applyCompileResult(CompileResult(result.generation, result.diagnostics, result.stamps))
  }

  private Void flushPendingPublishes()
  {
    if (pendingPublish.isEmpty) return
    keys := pendingPublish.keys.sort
    pendingPublish.clear
    keys.each |key| { if (docManager.getDocument(key) != null) publishMerged(key) }
  }

  ** Publish parser diagnostics merged with cached compiler diagnostics.
  private Void publishMerged(Str key)
  {
    enqueueOutgoing(mergedDiagnostics(key))
  }

  private [Str:Obj?] mergedDiagnostics(Str key)
  {
    parseResult := docManager.parseDocument(key)
    diags := diagnosticsProvider.merge(key, diagnosticsProvider.computeParserDiagnostics(key, parseResult))
    return Serialization.publishDiagnostics(clientUri(key), diags)
  }

  private Void applyIndexEntry(IndexEntry entry)
  {
    WorkspaceManager.applyIndexEntry(entry, symbolTable, typeResolver, referenceIndex)
    indexedKeys[entry.key] = true
  }

  private Void updateIndex(Str key, ParseResult result)
  {
    typeResolver.updateUsings(key, result)
    symbolTable.update(key, result)
    referenceIndex.update(key, result)
    indexedKeys[key] = true
  }

  private Void removeFromIndex(Str key)
  {
    symbolTable.remove(key)
    referenceIndex.remove(key)
    typeResolver.updateUsings(key, ParseResult.empty)
    indexedKeys.remove(key)
  }

  ** Record a new content stamp for an open document.
  private Void stampDocument(Str key)
  {
    docVersions.set(key, ++stampCounter)
  }

  ** Main-thread disk re-read of a non-open file into the index.
  private Void reindexFromDisk(Str key)
  {
    diskEventTicks[key] = Duration.now.ticks
    file := WorkspaceManager.uriToFile(key)
    if (file == null || !file.exists)
    {
      removeFromIndex(key)
      return
    }
    entry := WorkspaceManager.parseIndexFile(IndexFile(key, file, workspaceManager.folderFor(key) ?: ""))
    if (entry != null) applyIndexEntry(entry)
  }

  Void shutdown()
  {
    Env.cur.err.printLine("[fantomLsp] Shutdown requested")
    isShutdown = true
    compileActor.stopRefresh
  }

  private Str semanticBuildKey(Str key)
  {
    key = UriKey.canonical(key)
    pod := podRegistry.byBuildKey(key) ?: podRegistry.podForFile(key)
    if (pod != null) return pod.buildKey
    build := CompilerDiagnostics().findBuildFan(key)
    return build == null ? key : WorkspaceManager.fileToUri(build)
  }

  private Void invalidateSemanticBuild(Str buildKey)
  {
    semanticSnapshots.remove(buildKey)
    invalidSemanticGen[buildKey] = compileRequested
  }

  Void didChangeConfiguration([Str:Obj?] params)
  {
    settings := params["settings"] as [Str:Obj?]
    if (settings != null)
    {
      fantom := settings["fantom"] as [Str:Obj?]
      if (fantom != null)
      {
        paths := fantom["envPath"] as List
        if (paths != null)
        {
          configuredEnvPath = paths.findAll |p| { p is Str }.map |p->Str| { (Str)p }
          configureNamespace
        }
        lens := fantom["codeLens"] as [Str:Obj?]
        if (lens?.get("enabled") is Bool)
          codeLensOptions["codeLens"] = ["enabled": lens["enabled"]]
        semantic := fantom["semanticIndex"] as [Str:Obj?]
        enabled := semantic?.get("backgroundCompile")
        if (enabled is Bool)
        {
          wasEnabled := backgroundCompile
          backgroundCompile = enabled
          if (!wasEnabled && backgroundCompile && indexComplete) warmSemanticIndex
        }
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

  Void didChangeWorkspaceFolders([Str:Obj?] params)
  {
    evt := params["event"] as [Str:Obj?]
    if (evt == null) return

    added := evt["added"] as List
    if (added != null)
    {
      added.each |Obj? raw|
      {
        folder := raw as [Str:Obj?]
        uri := folder == null ? null : folder["uri"] as Str
        if (uri != null)
        {
          uri = UriKey.canonical(uri)
          workspaceManager.addFolder(uri)
          if (workspaceFolders == null) workspaceFolders = Str[,]
          if (!workspaceFolders.contains(uri)) workspaceFolders.add(uri)
        }
      }
    }

    removed := evt["removed"] as List
    if (removed != null)
    {
      removed.each |Obj? raw|
      {
        folder := raw as [Str:Obj?]
        uri := folder == null ? null : folder["uri"] as Str
        if (uri != null)
        {
          uri = UriKey.canonical(uri)
          workspaceManager.removeFolder(uri)
          if (workspaceFolders != null) workspaceFolders.remove(uri)
          dropFolderEntries(uri)
        }
      }
    }

    // Supersede any in-flight generation and re-index the current folder set.
    configureNamespace
    startIndex
  }

  **
  ** Main thread: drop index entries under a removed folder unless another
  ** workspace folder still covers them. Open buffers stay authoritative.
  **
  private Void dropFolderEntries(Str folderKey)
  {
    prefix := folderKey.endsWith("/") ? folderKey : folderKey + "/"
    indexedKeys.keys.each |key|
    {
      if (key != folderKey && !key.startsWith(prefix)) return
      if (docManager.getDocument(key) != null) return
      if (workspaceManager.folderFor(key) != null) return
      removeFromIndex(key)
      diskEventTicks.remove(key)
    }
    requestedGen.keys.each |key|
    {
      if ((key == folderKey || key.startsWith(prefix)) && workspaceManager.folderFor(key) == null)
        invalidateSemanticBuild(key)
    }
  }

  [Str:Obj?]? didOpen([Str:Obj?] params)
  {
    td := params["textDocument"] as [Str:Obj?]
    item := TextDocumentItem.fromMap(td)
    docManager.open(item)
    uri := UriKey.canonical(item.uri)
    stampDocument(uri)
    // A reopened document must not show diagnostics compiled from older text.
    diagnosticsProvider.clearCompilerDiagnostics(uri)
    parseResult := docManager.parseDocument(uri)
    updateIndex(uri, parseResult)
    diags := diagnosticsProvider.computeParserDiagnostics(uri, parseResult)
    // Warm-up snapshots carry no per-document diagnostics. Open/reopen resets
    // the content stamp and cache, so always compile to populate that cache.
    scheduleCompilerDiagnostics(uri)
    return Serialization.publishDiagnostics(clientUri(uri), diags)
  }

  [Str:Obj?]? didChange([Str:Obj?] params)
  {
    td := params["textDocument"] as [Str:Obj?]
    uri := UriKey.canonical((Str)td["uri"])
    version := ((Num)td["version"]).toInt
    changes := params["contentChanges"] as List
    doc := docManager.getDocument(uri)
    if (doc == null) return null
    oldText := doc.text

    changes.each |[Str:Obj?] change|
    {
      evt := TextDocumentContentChangeEvent.fromMap(change)
      docManager.change(uri, version, evt)
    }
    stampDocument(uri)
    // Keep compiler diagnostics outside the edited lines (plan 7.12.9).
    diagnosticsProvider.adjustCompilerDiagnostics(uri, oldText, doc.text)
    pendingPublish.remove(uri)
    parseResult := docManager.parseDocument(uri)
    updateIndex(uri, parseResult)
    return mergedDiagnostics(uri)
  }

  [Str:Obj?]? didClose([Str:Obj?] params)
  {
    uri := UriKey.canonical(Serialization.extractUri(params))
    outgoingUri := clientUri(uri)
    doc := docManager.getDocument(uri)
    wasDirty := doc != null && isDirtyAgainstDisk(uri, doc.text)
    docManager.close(uri)
    docVersions.remove(uri)
    diagnosticsProvider.clearCompilerDiagnostics(uri)
    pendingPublish.remove(uri)
    // Lifecycle (plan 7.12.14): the disk content becomes authoritative again.
    // Buffer entries of non-source documents, and of files outside every current
    // workspace folder (e.g. a removed folder, also after the last folder was
    // removed), are dropped instead.
    if (WorkspaceManager.isFanSourceUri(uri) && workspaceManager.isIndexable(uri))
      reindexFromDisk(uri)
    else
    {
      diskEventTicks[uri] = Duration.now.ticks
      removeFromIndex(uri)
    }
    if (wasDirty) scheduleCompilerDiagnostics(uri)
    return Serialization.publishDiagnostics(outgoingUri, Diagnostic[,])
  }

  private static Bool isDirtyAgainstDisk(Str key, Str text)
  {
    try
    {
      file := WorkspaceManager.uriToFile(key)
      if (file == null || !file.exists) return true
      return file.readAllStr != text
    }
    catch (Err e) return true
  }

  private static Bool snapshotOlderThanDisk(SemanticSnapshot snap)
  {
    return snap.fileHash.any |hash, key|
    {
      try
      {
        f := WorkspaceManager.uriToFile(key)
        return f == null || !f.exists || f.readAllStr.toBuf.toDigest("SHA-1").toHex != hash
      }
      catch (Err e) return true
    }
  }

  [Str:Obj?]? didSave([Str:Obj?] params)
  {
    uri := UriKey.canonical(Serialization.extractUri(params))
    doc := docManager.getDocument(uri)
    text := params["text"] as Str
    if (doc != null && text != null && text != doc.text)
    {
      oldText := doc.text
      docManager.updateText(uri, text)
      stampDocument(uri)
      diagnosticsProvider.adjustCompilerDiagnostics(uri, oldText, text)
    }
    parseResult := docManager.parseDocument(uri)
    if (doc != null) updateIndex(uri, parseResult)
    diags := diagnosticsProvider.merge(uri, diagnosticsProvider.computeParserDiagnostics(uri, parseResult))
    if (doc != null) scheduleCompilerDiagnostics(uri)
    return Serialization.publishDiagnostics(clientUri(uri), diags)
  }

  Void didChangeWatchedFiles([Str:Obj?] params)
  {
    changes := params["changes"] as List
    if (changes == null) return
    changes.each |Obj? raw|
    {
      change := raw as [Str:Obj?]
      if (change == null) return
      uri := change["uri"] as Str
      if (uri == null) return
      uri = UriKey.canonical(uri)
      typeNum := change["type"]
      kind := typeNum is Num ? ((Num)typeNum).toInt : 0
      if (kind == 3) invalidateSemanticBuild(semanticBuildKey(uri))
      if (WorkspaceManager.uriToFile(uri)?.name == "build.fan" && workspaceManager.isIndexable(uri))
      {
        // Main-thread lifecycle refresh, also for open build scripts and deletes.
        podRegistry.rebuild(workspaceManager)
        scheduleLowPriorityCompile(uri)
      }
      if (!WorkspaceManager.isFanSourceUri(uri)) return
      if (docManager.getDocument(uri) != null) return

      if (kind == 3)
      {
        // Lifecycle (plan 7.12.14): later background batches must not resurrect it.
        diskEventTicks[uri] = Duration.now.ticks
        removeFromIndex(uri)
        if (!docManager.openUris.isEmpty && podRegistry.podForFile(uri) == null)
          scheduleCompilerDiagnostics(docManager.openUris.sort.first)
        else scheduleLowPriorityCompile(uri)
        return
      }
      if (kind != 1 && kind != 2) return
      // Never index disk content outside the current workspace folders.
      if (!workspaceManager.isIndexable(uri)) return
      try
      {
        reindexFromDisk(uri)
        scheduleLowPriorityCompile(uri)
      }
      catch (Err e)
      {
        Env.cur.err.printLine("[fantomLsp] Error watching $uri: $e.msg")
      }
    }
  }

  Void cancelRequest(Obj? id)
  {
    key := cancelKey(id)
    if (key != null) cancelTokens[key] = true
  }

  ** Keep the established numeric/string ID string-key compatibility.
  internal static Str? cancelKey(Obj? id) { id?.toStr }

  internal Void retireCancel(Obj? id)
  {
    key := cancelKey(id)
    if (key != null) cancelTokens.remove(key)
  }

  Bool isCancelled(Obj? id)
  {
    if (id == null) return false
    key := cancelKey(id)
    hit := cancelTokens[key] != null
    if (hit) cancelTokens.remove(key)
    return hit
  }

  Obj? hover([Str:Obj?] params, Obj? requestId := null)
  {
    podLookup.install
    if (isCancelled(requestId)) return null
    uri := Serialization.extractUri(params)
    pos := Serialization.extractPosition(params)
    doc := docManager.getDocument(uri)
    if (doc == null) return null
    parseResult := docManager.parseDocument(uri)
    return cancellable(requestId, null) |->Obj?| { hoverProvider.hover(doc, parseResult, pos, this) }
  }

  Obj? completion([Str:Obj?] params, Obj? requestId := null)
  {
    podLookup.install
    if (isCancelled(requestId)) return null
    uri := Serialization.extractUri(params)
    pos := Serialization.extractPosition(params)
    doc := docManager.getDocument(uri)
    if (doc == null) return null
    parseResult := docManager.parseDocument(uri)
    return completionProvider.complete(doc, parseResult, pos, symbolTable)
  }

  Obj? signatureHelp([Str:Obj?] params, Obj? requestId := null)
  {
    podLookup.install
    uri := Serialization.extractUri(params)
    pos := Serialization.extractPosition(params)
    doc := docManager.getDocument(uri)
    if (doc == null) return null
    parseResult := docManager.parseDocument(uri)
    return cancellable(requestId, null) |->Obj?| { signatureHelpProvider.signatureHelp(doc, parseResult, pos, this) }
  }

  Obj? definition([Str:Obj?] params, Obj? requestId := null)
  {
    if (isCancelled(requestId)) return null
    uri := Serialization.extractUri(params)
    pos := Serialization.extractPosition(params)
    doc := docManager.getDocument(uri)
    if (doc == null) return null
    return cancellable(requestId, null) |->Obj?| { definitionProvider.definition(doc, pos, this) }
  }

  Obj? typeDefinition([Str:Obj?] params, Obj? requestId := null)
  {
    uri := Serialization.extractUri(params)
    pos := Serialization.extractPosition(params)
    doc := docManager.getDocument(uri)
    if (doc == null) return null
    return cancellable(requestId, null) |->Obj?| { definitionProvider.typeDefinition(doc, pos, this) }
  }

  Obj? declaration([Str:Obj?] params, Obj? requestId := null)
  {
    if (isCancelled(requestId)) return null
    uri := Serialization.extractUri(params)
    pos := Serialization.extractPosition(params)
    doc := docManager.getDocument(uri)
    if (doc == null) return null
    return cancellable(requestId, null) |->Obj?| { definitionProvider.declaration(doc, pos, this) }
  }

  Obj? implementation([Str:Obj?] params, Obj? requestId := null)
  {
    uri := Serialization.extractUri(params)
    pos := Serialization.extractPosition(params)
    doc := docManager.getDocument(uri)
    if (doc == null) return null
    return cancellable(requestId, null) |->Obj?| { definitionProvider.implementation(doc, pos, this) }
  }

  Obj? references([Str:Obj?] params, Obj? requestId := null)
  {
    uri := Serialization.extractUri(params)
    pos := Serialization.extractPosition(params)
    doc := docManager.getDocument(uri)
    if (doc == null) return null
    context := params["context"] as [Str:Obj?]
    includeDecl := context?.get("includeDeclaration") == true
    return cancellable(requestId, null) |->Obj?| { referencesProvider.references(doc, pos, this, includeDecl) }
  }

  Obj? documentSymbol([Str:Obj?] params)
  {
    uri := UriKey.canonical(Serialization.extractUri(params))
    doc := docManager.getDocument(uri)
    if (doc == null) return null
    symbols := symbolTable.getDocumentSymbols(uri)
    return symbols.map |s| { s.toMap }
  }

  Obj? documentHighlight([Str:Obj?] params, Obj? requestId := null)
  {
    uri := Serialization.extractUri(params)
    doc := docManager.getDocument(uri)
    if (doc == null) return null
    pos := Serialization.extractPosition(params)
    return cancellable(requestId, null) |->Obj?| { documentHighlightProvider.highlight(doc, pos, this) }
  }

  Obj? foldingRange([Str:Obj?] params)
  {
    uri := Serialization.extractUri(params)
    if (docManager.getDocument(uri) == null) return null
    return foldingRangeProvider.ranges(docManager.parseDocument(uri))
  }

  Obj? inlayHint([Str:Obj?] params)
  {
    uri := Serialization.extractUri(params)
    doc := docManager.getDocument(uri)
    if (doc == null) return null
    rangeMap := params["range"] as [Str:Obj?]
    range := rangeMap == null ? null : LspRange.fromMap(rangeMap)
    return inlayHintProvider.hints(doc, docManager.parseDocument(uri), range)
  }

  Obj? selectionRange([Str:Obj?] params)
  {
    uri := Serialization.extractUri(params)
    doc := docManager.getDocument(uri)
    if (doc == null) return null
    raw := params["positions"] as List
    positions := Position[,]
    if (raw != null) raw.each |Obj? p|
    {
      m := p as [Str:Obj?]
      if (m != null) positions.add(Position.fromMap(m))
    }
    return selectionRangeProvider.selectionRanges(doc, docManager.parseDocument(uri), positions)
  }

  Obj? completionResolve([Str:Obj?] params)
  {
    if (params["documentation"] != null) return params
    label := params["label"] as Str
    if (label == null || label.isEmpty) return params
    Type? t := null
    Pod.list.find |pod|
    {
      t = pod.type(label, false)
      return t != null
    }
    if (t != null && t.doc != null && !t.doc.isEmpty)
      params["documentation"] = ["kind": "markdown", "value": t.doc]
    return params
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

  Obj? rangeFormatting([Str:Obj?] params)
  {
    uri := Serialization.extractUri(params)
    doc := docManager.getDocument(uri)
    if (doc == null) return null
    rangeMap := params["range"] as [Str:Obj?]
    if (rangeMap == null) return formatting(params)
    range := LspRange.fromMap(rangeMap)
    opts := params["options"] as [Str:Obj?] ?: [Str:Obj?][:]
    opts["bracketStyle"] = bracketStyle
    edits := formattingProvider.formatRange(doc, range, opts)
    return edits.map |e| { e.toMap }
  }

  Obj? onTypeFormatting([Str:Obj?] params)
  {
    if (params["ch"] as Str != "}") return TextEdit[,]
    uri := Serialization.extractUri(params)
    doc := docManager.getDocument(uri)
    if (doc == null) return null
    opts := params["options"] as [Str:Obj?] ?: [Str:Obj?][:]
    opts["bracketStyle"] = bracketStyle
    return formattingProvider.formatLine(doc, Serialization.extractPosition(params).line, opts).map |e| { e.toMap }
  }

  Obj? documentLink([Str:Obj?] params)
  {
    uri := Serialization.extractUri(params)
    doc := docManager.getDocument(uri)
    if (doc == null) return null
    return documentLinkProvider.links(doc, docManager.parseDocument(uri), |Str key->Str| { clientUri(key) })
  }

  Obj? rename([Str:Obj?] params, Obj requestId)
  {
    if (isCancelled(requestId)) return null
    uri := Serialization.extractUri(params)
    pos := Serialization.extractPosition(params)
    newName := params["newName"] as Str
    doc := docManager.getDocument(uri)
    if (doc == null) return null
    edit := renameProvider.rename(doc, pos, newName, this, requestId)
    return edit.toMap
  }

  ** A cancelled preparation returns null (no rename range), never a range.
  Obj? prepareRename([Str:Obj?] params, Obj? requestId := null)
  {
    uri := Serialization.extractUri(params)
    pos := Serialization.extractPosition(params)
    doc := docManager.getDocument(uri)
    if (doc == null) return null
    return cancellable(requestId, null) |->Obj?| { renameProvider.prepareRename(doc, pos, this) }
  }

  Obj? linkedEditingRange([Str:Obj?] params, Obj? requestId := null)
  {
    uri := Serialization.extractUri(params)
    pos := Serialization.extractPosition(params)
    doc := docManager.getDocument(uri)
    if (doc == null) return null
    return cancellable(requestId, null) |->Obj?| { linkedEditingRangeProvider.ranges(doc, pos, this) }
  }

  Obj? codeLens([Str:Obj?] params, Obj? requestId := null)
  {
    uri := Serialization.extractUri(params)
    doc := docManager.getDocument(uri)
    if (doc == null) return null
    return cancellable(requestId, null) |->Obj?| { codeLensProvider.lenses(docManager.parseDocument(uri)) }
  }

  ** Resolve reference counts lazily using the provider's snapshot-only path.
  ** A cancelled resolve returns the lens unchanged (no command), never an error.
  Obj? codeLensResolve([Str:Obj?] params, Obj? requestId := null)
  { cancellable(requestId, params) |->Obj?| { codeLensProvider.resolve(params) } }

  ** Run a long resolver request polling the client's cancel token between
  ** files and fallback attempts. Cancellation yields `cancelled` as a normal
  ** result, so the dispatcher never reports -32603 for it.
  private Obj? cancellable(Obj? requestId, Obj? cancelled, |->Obj?| f)
  {
    if (isCancelled(requestId)) return cancelled
    check := requestId == null ? null : |->Bool| { isCancelled(requestId) }
    try return resolver.cancellable(check, f)
    catch (ResolverCancelledErr e) return cancelled
  }

  Obj? codeAction([Str:Obj?] params)
  {
    uri := Serialization.extractUri(params)
    range := LspRange.fromMap(params["range"])
    context := params["context"] as [Str:Obj?] ?: [Str:Obj?][:]
    doc := docManager.getDocument(uri)
    if (doc == null) return null
    parseResult := docManager.parseDocument(uri)
    return codeActionProvider.codeActions(doc, parseResult, range, context, |Str key->Str| { clientUri(key) })
  }

  Obj? semanticTokensFull([Str:Obj?] params)
  {
    uri := Serialization.extractUri(params)
    doc := docManager.getDocument(uri)
    if (doc == null) return null
    parseResult := docManager.parseDocument(uri)
    return semanticTokensProvider.provideTokens(doc, symbolTable, typeResolver, parseResult)
  }

  Obj? semanticTokensRange([Str:Obj?] params)
  {
    uri := Serialization.extractUri(params)
    doc := docManager.getDocument(uri)
    if (doc == null) return null
    parseResult := docManager.parseDocument(uri)
    rangeMap := params["range"] as [Str:Obj?]
    range := rangeMap == null ? LspRange(Position(0, 0), Position(0x7fffffff, 0)) : LspRange.fromMap(rangeMap)
    return semanticTokensProvider.provideTokensRange(doc, symbolTable, parseResult, range)
  }

  Obj? prepareCallHierarchy([Str:Obj?] params, Obj? requestId := null)
  {
    uri := Serialization.extractUri(params)
    pos := Serialization.extractPosition(params)
    doc := docManager.getDocument(uri)
    if (doc == null) return null
    return cancellable(requestId, null) |->Obj?| { callHierarchyProvider.prepare(doc, pos, this) }
  }

  Obj? callHierarchyIncoming([Str:Obj?] params, Obj? requestId := null)
  {
    item := hierarchyItem(params)
    return cancellable(requestId, null) |->Obj?| { callHierarchyProvider.incomingCalls(item, this) }
  }

  Obj? callHierarchyOutgoing([Str:Obj?] params, Obj? requestId := null)
  {
    item := hierarchyItem(params)
    return cancellable(requestId, null) |->Obj?| { callHierarchyProvider.outgoingCalls(item, this) }
  }

  Obj? prepareTypeHierarchy([Str:Obj?] params, Obj? requestId := null)
  {
    uri := Serialization.extractUri(params)
    doc := docManager.getDocument(uri)
    if (doc == null) return null
    pos := Serialization.extractPosition(params)
    return cancellable(requestId, null) |->Obj?| { typeHierarchyProvider.prepare(doc, pos, this) }
  }

  Obj? typeHierarchySupertypes([Str:Obj?] params)
  {
    item := hierarchyItem(params)
    return typeHierarchyProvider.supertypes(item, this)
  }

  Obj? typeHierarchySubtypes([Str:Obj?] params)
  {
    item := hierarchyItem(params)
    return typeHierarchyProvider.subtypes(item, this)
  }

  private [Str:Obj?] hierarchyItem([Str:Obj?] params)
  {
    item := (params["item"] as [Str:Obj?] ?: [Str:Obj?][:]).dup
    uri := item["uri"] as Str
    if (uri != null) item["uri"] = UriKey.canonical(uri)
    return item
  }

  Obj? workspaceSymbol([Str:Obj?] params)
  {
    query := params["query"] as Str ?: ""
    return workspaceSymbolProvider.search(query, symbolTable, |Str key->Str| { clientUri(key) })
  }
}

**************************************************************************
** Mailbox: background producers -> main thread
**************************************************************************

**
** Thread-safe FIFO from background producers to the main thread, following
** the actor enqueue/drain pattern. Producers `post`; only the main thread
** `drain`s. `hasPending` is a lock-free hint so idle ticks avoid actor hops.
**
const class Mailbox : Actor
{
  private const AtomicInt pending := AtomicInt(0)

  new make(ActorPool pool) : super(pool) {}

  ** Any thread: enqueue an immutable message or an `Unsafe`-wrapped hand-over.
  Void post(Obj msg)
  {
    pending.increment
    send(MailboxOp("post", msg))
  }

  Bool hasPending() { pending.val > 0 }

  ** Main thread: take every message posted so far, in order.
  Obj[] drain()
  {
    taken := (send(MailboxOp("drain", null)).get(30sec) as Unsafe)?.val as Obj[] ?: Obj[,]
    pending.add(-taken.size)
    return taken
  }

  override Obj? receive(Obj? msg)
  {
    op := msg as MailboxOp
    queue := locals["fantomLsp.mailbox"] as Obj[]
    if (queue == null) locals["fantomLsp.mailbox"] = queue = Obj[,]
    if (op?.op == "post")
    {
      queue.add(op.payload)
      return null
    }
    result := queue.dup
    queue.clear
    return Unsafe(result)
  }
}

internal const class MailboxOp
{
  const Str op
  const Obj? payload
  new make(Str op, Obj? payload) { this.op = op; this.payload = payload }
}

**************************************************************************
** Background inputs and outputs (immutable unless wrapped in Unsafe)
**************************************************************************

** Immutable index request: a frozen copy of the main-thread folder settings.
const class IndexRequest
{
  const Int generation
  const Str[] folders
  const Str[] excludeDirs
  const Int maxFiles

  new make(Int generation, Str[] folders, Str[] excludeDirs, Int maxFiles)
  {
    this.generation = generation
    this.folders = folders.toImmutable
    this.excludeDirs = excludeDirs.toImmutable
    this.maxFiles = maxFiles
  }
}

**
** A batch of parsed files for one index generation. `entries` wraps an
** `IndexEntry[]` that the producer never touches after posting.
**
const class IndexBatch
{
  const Int generation
  const Unsafe entries
  ** True for the last batch of a generation.
  const Bool isFinal

  new make(Int generation, IndexEntry[] entries, Bool isFinal)
  {
    this.generation = generation
    this.entries = Unsafe(entries)
    this.isFinal = isFinal
  }
}

**
** Immutable compile input (plan 7.3): open-buffer overlay `key -> text` and
** `key -> stamp`. The actor never touches main-thread state.
**
const class CompileRequest
{
  const Int seq
  const Str triggerKey
  const Str:Str texts
  const Str:Int stamps

  new make(Int seq, Str triggerKey, Str:Str texts, Str:Int stamps)
  {
    this.seq = seq
    this.triggerKey = triggerKey
    this.texts = texts.toImmutable
    this.stamps = stamps.toImmutable
  }
}

** Immutable compile output: compiler diagnostics per key with the stamp compiled.
const class CompileResult
{
  const Int seq
  const Str:Diagnostic[] diagnostics
  const Str:Int stamps

  new make(Int seq, Str:Diagnostic[] diagnostics, Str:Int stamps)
  {
    this.seq = seq
    this.diagnostics = diagnostics.toImmutable
    this.stamps = stamps.toImmutable
  }
}

**************************************************************************
** Pure background producers
**************************************************************************

**
** Pure producer: collects and parses workspace files for one generation and
** posts `IndexBatch`es of about `batchSize` entries. It stops early once the
** shared generation counter moves on.
**
internal const class IndexActor : Actor
{
  static const Int batchSize := 50
  private const Mailbox mailbox
  private const AtomicInt currentGen

  new make(ActorPool pool, Mailbox mailbox, AtomicInt currentGen) : super(pool)
  {
    this.mailbox = mailbox
    this.currentGen = currentGen
  }

  override Obj? receive(Obj? msg)
  {
    req := msg as IndexRequest
    if (req == null) return null
    try
    {
      if (currentGen.val != req.generation) return null
      files := WorkspaceManager.collectWorkspaceFiles(req.folders, req.excludeDirs, req.maxFiles)
      Env.cur.err.printLine("[fantomLsp] Indexing ${files.size} files (generation ${req.generation})")
      batch := IndexEntry[,]
      for (i := 0; i < files.size; i++)
      {
        if (currentGen.val != req.generation) return null
        entry := WorkspaceManager.parseIndexFile(files[i])
        if (entry != null) batch.add(entry)
        if (batch.size >= batchSize)
        {
          mailbox.post(IndexBatch(req.generation, batch, false))
          batch = IndexEntry[,]
        }
      }
      mailbox.post(IndexBatch(req.generation, batch, true))
    }
    catch (Err e)
    {
      Env.cur.err.printLine("[fantomLsp] Workspace index failed: $e.msg")
      e.trace(Env.cur.err)
      // Never leave a generation incomplete.
      mailbox.post(IndexBatch(req.generation, IndexEntry[,], true))
    }
    return null
  }
}
