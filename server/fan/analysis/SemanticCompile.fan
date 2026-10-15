using compiler
using concurrent

** Frontend-only compiler. Texts are captured exactly once, at Tokenize, and
** extracted before ClosureVars mutates captured locals. No backend is invoked.
class LspCompiler : Compiler
{
  new make(CompilerInput input, Str:Str overlays := Str:Str[:]) : super(input)
  {
    this.overlays = overlays
  }

  private Str:Str overlays
  Str:Str compiledTexts := [:] { private set }
  SemanticSnapshot? snapshot { private set }
  Bool resolveExprComplete := false { private set }

  override Void frontend()
  {
    try
    {
      step("InitInput")
      // LspNamespace composes ReflectNamespace. Installed CType instances keep
      // that namespace (rather than the outer namespace) for FFI resolution.
      // Associate it with this compile just as InitInput associates input.ns.
      // This is the installed compiler's internal c field, feature-detected.
      reflectedNs := ns?.objType?.ns
      if (reflectedNs != null && reflectedNs !== ns)
        CNamespace#.field("c", false)?.set(reflectedNs, this)
      tokenizer := Tokenize(this)
      if (input.mode == CompilerInputMode.str)
      {
        text := input.srcStr ?: ""
        tokenizer.tokenize(input.srcStrLoc, text)
        compiledTexts[WorkspaceManager.fileToUri(File.os(input.srcStrLoc.file))] = text
      }
      else
      {
        srcFiles.each |file|
        {
          key := WorkspaceManager.fileToUri(file)
          text := overlays[key] ?: file.readAllStr
          compiledTexts[key] = text
          tokenizer.tokenize(Loc.makeFile(file), text)
        }
      }
      preResolve.each |name| { step(name) }
      try
      {
        step("ResolveExpr")
        resolveExprComplete = true
      }
      catch (CompilerErr e)
      {
        resolveExprComplete = true
        extract
        throw e
      }
      extract
      postResolve.each |name| { step(name) }
    }
    catch (CompilerErr e)
    {
      if (errs.isEmpty) errs.add(e)
    }
    finally
    {
      ns?.objType?.ns?.cleanup
      ns?.cleanup
    }
  }

  private Void extract()
  {
    if (types != null && resolveExprComplete)
      snapshot = SemanticIndexer().extract(this, compiledTexts, true)
  }

  private Void step(Str name)
  {
    t := Type.find("compiler::$name", false)
    if (t == null)
    {
      // These later additions are optional on older compiler releases.
      if (name == "ClosureToImmutable" || name == "ConstChecks") return
      throw UnsupportedErr("Missing compiler frontend step: $name")
    }
    ((CompilerStep)t.make([this])).run
  }

  private static const Str[] preResolve := ["ResolveDepends", "ScanForUsingsAndTypes",
    "ResolveImports", "Parse", "OrderByInheritance", "CheckInheritance", "Inherit",
    "DefaultCtor", "InitEnum", "InitFacet", "InitClosures", "Normalize"]
  private static const Str[] postResolve := ["CheckErrors", "CheckParamDefs", "LocaleProps",
    "ClosureVars", "ClosureToImmutable", "ConstChecks"]
}

** Immutable, per-build inputs. Disk files are read by the worker; buffers and
** namespace roots are frozen by the main thread, never obtained from a manager.
const class SemanticCompileRequest
{
  const Int generation
  const Str buildKey
  const Str podName
  const File? buildFan
  const Str[] files
  const Str:Str texts
  const Str:Int stamps
  const File[] roots
  ** Smaller values win: ensureFresh, open pod, warm-up.
  const Int priority
  const StdioWriteActor? writer
  ** Capability-gated refresh intent, not a consequence of queue priority.
  const Bool refreshSupport
  const File[] sourceDirs

  new make(Int generation, Str buildKey, Str podName, File? buildFan,
           Str[] files, Str:Str texts, Str:Int stamps, File[] roots := File[,],
           Int priority := 1, StdioWriteActor? writer := null, Bool refreshSupport := false,
           File[] sourceDirs := File[,])
  {
    this.generation = generation; this.buildKey = buildKey; this.podName = podName
    this.buildFan = buildFan; this.files = files.toImmutable
    this.texts = texts.toImmutable; this.stamps = stamps.toImmutable
    this.roots = roots.toImmutable; this.priority = priority
    this.writer = writer; this.refreshSupport = refreshSupport
    this.sourceDirs = sourceDirs.toImmutable
  }
}

const class SemanticCompileResult
{
  const Str buildKey
  const Int generation
  const SemanticSnapshot? snapshot
  const Str[] failedFiles
  const Str:Diagnostic[] diagnostics
  const Str:Int stamps
  new make(SemanticCompileRequest req, SemanticSnapshot? snapshot, Str[] failedFiles,
           Str:Diagnostic[] diagnostics)
  {
    buildKey = req.buildKey; generation = req.generation; this.snapshot = snapshot
    this.failedFiles = failedFiles.toImmutable
    this.diagnostics = diagnostics.toImmutable; stamps = req.stamps
  }
}

** Pure compile service also used by the legacy synchronous diagnostics API.
class SemanticCompile
{
  SemanticCompileResult compile(SemanticCompileRequest req)
  {
    if (!req.sourceDirs.isEmpty)
    {
      files := Str[,]
      req.sourceDirs.each |dir|
      {
        if (!dir.exists || !dir.isDir) return
        dir.list.each |file|
        {
          if (file.isDir || file.ext != "fan") return
          k := WorkspaceManager.fileToUri(file)
          files.add(k)
        }
      }
      return compile(SemanticCompileRequest(req.generation, req.buildKey, req.podName,
        req.buildFan, files.unique.sort, req.texts, req.stamps, req.roots,
        req.priority, req.writer, req.refreshSupport))
    }
    first := attempt(req, req.texts)
    failed := Str[,]
    parser := CompilerDiagnostics()
    req.files.each |key|
    {
      if (!parser.filterErrorsForFile(first.errs, key).isEmpty) failed.add(key)
    }
    selected := first
    if (first.snapshot == null && failed.any |key| { req.texts.containsKey(key) })
    {
      retryTexts := req.texts.dup
      failed.each |key| { retryTexts.remove(key) }
      retry := attempt(req, retryTexts)
      if (retry.snapshot != null) selected = retry
    }
    snap := selected.snapshot
    if (snap != null)
    {
      openText := Str:Str[:]
      req.texts.each |text, key|
      {
        // A retry's disk text is NOT overlay provenance. The facade reads disk
        // and maps against the current buffer for these files.
        if (selected.compiledTexts[key] == text) openText[key] = text
      }
      snap = SemanticSnapshot(snap.podName, req.generation, snap.fileHash,
        openText, snap.occByFile, snap.decls, snap.occByKey, Str[,], snap.resolved)
    }
    diags := Str:Diagnostic[][:]
    req.texts.each |text, key|
    {
      diags[key] = DiagnosticsProvider.compilerDiagnosticsFor(text,
        parser.filterErrorsForFile(first.errs, key))
    }
    return SemanticCompileResult(req, snap, snap == null ? failed : Str[,], diags)
  }

  internal LspCompiler attempt(SemanticCompileRequest req, Str:Str overlays)
  {
    parser := CompilerDiagnostics()
    input := CompilerInput()
    input.podName = req.podName
    input.summary = "LSP frontend"
    input.version = Version("1.0")
    input.mode = CompilerInputMode.file
    input.output = CompilerOutputMode.podFile // validation only; no output step
    input.baseDir = req.buildFan?.parent ?: Env.cur.tempDir
    input.srcFiles = req.files.map |key->Uri| { WorkspaceManager.uriToFile(key).uri }
    if (req.buildFan == null && !req.files.isEmpty && overlays.containsKey(req.files.first))
    {
      input.mode = CompilerInputMode.str
      input.srcStr = overlays[req.files.first]
      input.srcStrLoc = Loc.makeFile(WorkspaceManager.uriToFile(req.files.first))
    }
    input.depends = req.buildFan == null ?
      parser.extractDependenciesFromSource(req.texts.vals.join("\n")) :
      parser.extractDependenciesFromBuildFan(req.buildFan)
    input.ns = LspNamespace(req.roots)
    input.log = CompilerLog(Buf().out)
    c := LspCompiler(input, overlays)
    c.frontend
    return c
  }
}

** Immutable refresh input. Optional atomic epoch suppresses superseded warm-up
** notifications without giving the actor access to mutable server state.
const class SemanticRefreshRequest
{
  const StdioWriteActor writer
  const AtomicInt? epoch
  const Int generation
  new make(StdioWriteActor writer, AtomicInt? epoch := null, Int generation := 0)
  { this.writer = writer; this.epoch = epoch; this.generation = generation }
  Bool current() { epoch == null || epoch.val == generation }
}

** Actor-local pending queue, with a short first-run debounce. Request messages
** queued during a compile all precede its next self-sent run: latest wins per
** build, and priority is chosen between compiles, never by parallel workers.
const class SemanticCompileActor : Actor
{
  private const Mailbox mailbox
  private const ConcurrentMap completedGen
  private const AtomicInt completed
  const AtomicInt compileCount := AtomicInt(0)
  private const AtomicInt refreshIds := AtomicInt(0)
  private const AtomicBool stopped := AtomicBool(false)

  new make(ActorPool pool, Mailbox mailbox, ConcurrentMap completedGen,
           AtomicInt completed) : super(pool)
  {
    this.mailbox = mailbox; this.completedGen = completedGen; this.completed = completed
  }

  Future request(SemanticCompileRequest req) { send(req) }
  Future refresh(SemanticRefreshRequest req) { send(req) }

  ** Main-thread shutdown barrier: no worker-originated writes after return.
  Void stopRefresh()
  {
    stopped.val = true
    send("stop").get(30sec)
  }

  override Obj? receive(Obj? msg)
  {
    if (msg == "stop") { locals.remove("refreshPending"); return null }
    if (msg == "refresh")
    {
      locals["refreshScheduled"] = false
      req := locals.remove("refreshPending") as SemanticRefreshRequest
      // A compile can emit immediately before an older timer is delivered.
      // Recheck the rate limit rather than letting that timer write too soon.
      if (req != null && !stopped.val) queueRefresh(req)
      return null
    }
    if (stopped.val) return null
    if (msg is SemanticRefreshRequest)
    {
      queueRefresh(msg)
      return null
    }
    pending := locals["pending"] as Str:SemanticCompileRequest
    if (pending == null) locals["pending"] = pending = Str:SemanticCompileRequest[:]
    if (msg is SemanticCompileRequest)
    {
      req := (SemanticCompileRequest)msg
      old := pending[req.buildKey]
      if (old == null || old.generation < req.generation)
      {
        // Latest inputs win, but quiet warm-up must not erase a pending
        // explicit/open-document refresh for this same build.
        if (old?.refreshSupport == true && !req.refreshSupport)
          req = SemanticCompileRequest(req.generation, req.buildKey, req.podName,
            req.buildFan, req.files, req.texts, req.stamps, req.roots,
            req.priority, req.writer, true, req.sourceDirs)
        pending[req.buildKey] = req
      }
      priorities := locals["priorities"] as Str:Int
      if (priorities == null) locals["priorities"] = priorities = Str:Int[:]
      priorities[req.buildKey] = req.priority.min(priorities[req.buildKey] ?: req.priority)
      locals["lastRequestTicks"] = Duration.now.ticks
      if (locals["scheduled"] != true)
      {
        locals["scheduled"] = true
        locals["batchStartedTicks"] = Duration.now.ticks
        sendLater(100ms, "run")
      }
      return null
    }
    if (pending.isEmpty) { locals["scheduled"] = false; return null }
    quiet := Duration.now.ticks - ((locals["lastRequestTicks"] as Int) ?: 0)
    batchAge := Duration.now.ticks - ((locals["batchStartedTicks"] as Int) ?: 0)
    if (quiet < 100ms.ticks && batchAge < 1sec.ticks)
    {
      sendLater(Duration(100ms.ticks - quiet), "run")
      return null
    }
    priorities := locals["priorities"] as Str:Int
    req := pending.vals.sort |a, b|
    {
      n := priorities[a.buildKey] <=> priorities[b.buildKey]
      return n == 0 ? a.generation <=> b.generation : n
    }.first
    pending.remove(req.buildKey)
    priorities.remove(req.buildKey)
    try
    {
      compileCount.increment
      result := SemanticCompile().compile(req)
      mailbox.post(result)
      if (result.snapshot != null && req.refreshSupport && req.writer != null && !stopped.val)
        queueRefresh(SemanticRefreshRequest(req.writer))
    }
    catch (Err e) { Env.cur.err.printLine("[SemanticCompile] $req.buildKey: $e"); e.trace(Env.cur.err) }
    finally
    {
      completedGen.set(req.buildKey, req.generation)
      if (completed.val < req.generation) completed.val = req.generation
      send("run")
    }
    return null
  }

  private Void queueRefresh(SemanticRefreshRequest req)
  {
    if (stopped.val || !req.current) return
    last := locals["refreshTicks"] as Int ?: 0
    now := Duration.now.ticks
    if (now - last >= 1sec.ticks)
    {
      locals.remove("refreshPending")
      writeRefresh(req)
    }
    else
    {
      // An explicit refresh also covers final visibility; don't replace its
      // unguarded intent with a warm-up intent which might be superseded.
      old := locals["refreshPending"] as SemanticRefreshRequest
      if (old == null || old.epoch != null || req.epoch == null)
        locals["refreshPending"] = req
      if (locals["refreshScheduled"] != true)
      {
        locals["refreshScheduled"] = true
        sendLater(Duration(1sec.ticks - (now - last)), "refresh")
      }
    }
  }

  private Void writeRefresh(SemanticRefreshRequest req)
  {
    if (stopped.val || !req.current) return
    locals["refreshTicks"] = Duration.now.ticks
    req.writer.send(JsonRpc.encode(["jsonrpc": "2.0",
      "id": "semantic-refresh-${refreshIds.incrementAndGet}",
      "method": "workspace/codeLens/refresh", "params": [Str:Obj?][:]]))
  }
}
