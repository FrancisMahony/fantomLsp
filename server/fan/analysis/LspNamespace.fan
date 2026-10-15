using compiler
using concurrent

** API evidence: reflection probe against compiler 1.0.83.4006 (2026-10-13).
** CNamespace.findPod is protected virtual CPod?; resolvePod and resolveType
** are NONVIRTUAL, with private podCache / internal typeCache. FPod.make(ns,
** name, Zip), read and readFully are public. ReflectNamespace.findPod returns
** ReflectPod?, FPodNamespace.findPod returns FPod?: neither covariant hook can
** return BOTH kinds. Therefore extend CNamespace directly, use FPod's file
** loader (the FPodNamespace algorithm), and compose ReflectNamespace fallback.
** PodLookup replaces the WHOLE namespace on file-set/stamp changes. Compilers
** must obtain a fresh namespace per request, never reuse input.ns across builds.
** sys::Type is final: legacy Type?-returning helpers cannot represent CType.
** They intentionally refuse workspace pods; downstream providers must migrate
** to PodLookup.findType/findSlot to display file-backed signatures.
class LspNamespace : CNamespace
{
  new make(File[] roots := File[,], [Str:File]? snapshot := null)
  {
    this.roots = roots.map |r->File| { r.normalize }.unique.toImmutable
    files = snapshot ?: workspaceFiles(this.roots)
    fallback = ReflectNamespace()
    init
  }

  const File[] roots
  private Str:File files
  private ReflectNamespace fallback
  private Str:Str docs := [:]

  ** A namespace is one build snapshot. For the next build use PodLookup or
  ** construct a new instance; CNamespace's caches cannot be overridden.
  protected override CPod? findPod(Str name)
  {
    file := files[name]
    if (file == null)
    {
      try { return fallback.resolvePod(name, null) }
      catch (CompilerErr e) { return null }
    }
    // Do not fall back on corrupt workspace builds: that would silently select
    // precisely the stale installed library this service exists to avoid.
    zip := Zip.open(file)
    try
    {
      p := FPod(this, name, zip)
      p.read
      if (p.name != name) throw IOErr("Pod name mismatch: $file (${p.name}, expected $name)")
      readDocs(zip, name)
      // Materialize slots (including inherited slots) before closing the zip.
      // This releases Windows file handles so a build can overwrite the pod.
      // FType.readFully alone is insufficient: slots() lazily calls reflect/read.
      p.types.each |t| { t.slots }
      return p
    }
    finally { zip.close }
  }

  File? podFile(Str name) { files[name] }
  Str[] workspacePodNames() { files.keys.sort }

  ** FType/FSlot.doc is null in this compiler. Read their packaged apidoc,
  ** rather than consulting a stale reflection pod for documentation.
  Str? documentation(Str qname) { docs[qname] }

  private Void readDocs(Zip zip, Str podName)
  {
    zip.contents.each |f, uri|
    {
      if (!uri.toStr.startsWith("/doc/") || f.ext != "apidoc") return
      typeName := f.basename
      Str? key := null
      lines := Str[,]
      inDoc := false
      f.readAllLines.each |line|
      {
        if (line.startsWith("== ") || line.startsWith("-- "))
        {
          if (key != null && !lines.isEmpty) docs[key] = lines.join("\n").trim
          lines.clear
          inDoc = false
          if (line.startsWith("== ")) key = "$podName::$typeName"
          else
          {
            slotName := line[3..-1].split(' ').first.split('(').first
            key = "$podName::${typeName}.${slotName}"
          }
        }
        else if (line.isEmpty && !inDoc) inDoc = true
        else if (inDoc) lines.add(line)
      }
      if (key != null && !lines.isEmpty) docs[key] = lines.join("\n").trim
    }
  }

  ** Newest mtime wins; equal times retain root order (client launch priority).
  static Str:File workspaceFiles(File[] roots)
  {
    found := Str:File[:]
    roots.each |root|
    {
      // FAN_HOME is the installed fallback, not a workspace override. It can
      // be discovered as an ancestor of sources under Env.cur.tempDir. Keep
      // it in the effective path, but never suppress installed reflection or
      // eagerly file-load the whole distribution merely because it qualifies.
      if (root.normalize == Env.cur.homeDir.normalize) return
      dir := root + `lib/fan/`
      if (!dir.exists || !dir.isDir) return
      dir.list.each |f|
      {
        if (f.isDir || f.ext != "pod") return
        prev := found[f.basename]
        if (prev == null || f.modified > prev.modified) found[f.basename] = f
      }
    }
    return found
  }

  ** Runtime path inspection only. D6 forbids using these as lookup roots.
  static File[] envRoots()
  {
    raw := Env.cur.vars["FAN_ENV_PATH"] ?: ""
    sep := Env.cur.os == "win32" ? ';' : ':'
    return pathRoots(raw.split(sep))
  }

  static File[] pathRoots(Str[] paths)
  {
    roots := File[,]
    paths.each |p|
    {
      if (p.trim.isEmpty) return
      try
      {
        f := File.os(p)
        // Uri.isAbs means a URI SCHEME, not an absolute filesystem path.
        // File.os("C:\\...") is scheme-less until normalize on this runtime.
        absolute := Env.cur.os == "win32" ?
          (p.startsWith("\\\\") || (p.size >= 3 && p[0].isAlpha && p[1] == ':' && (p[2] == '\\' || p[2] == '/'))) :
          p.startsWith("/")
        if (!absolute) throw ArgErr("envPath requires an absolute directory")
        f = f.normalize
        if (!f.uri.isDir) f = File.os(p + File.sep).normalize
        if (!roots.contains(f)) roots.add(f)
      }
      catch (Err e) { Env.cur.err.printLine("[fantomLsp] Invalid env root '$p': $e.msg") }
    }
    return roots
  }

  static File[] detectRoots(File[] folders)
  {
    roots := File[,]
    folders.each |folder|
    {
      File? dir := folder
      for (i := 0; i <= 3 && dir != null; ++i)
      {
        lib := dir + `lib/fan/`
        if (((dir + `fan.props`).exists && !(dir + `fan.props`).isDir) ||
            (lib.exists && lib.isDir && lib.list.any |f| { !f.isDir && f.ext == "pod" }))
          if (!roots.contains(dir.normalize)) roots.add(dir.normalize)
        parent := dir.parent
        if (parent == dir) break
        dir = parent
      }
    }
    return roots
  }
}

** Main-thread lookup service. A file change invalidates all namespace caches,
** including inherited/parameterized types, not just the modified pod entry.
** CType/CSlot results belong to a snapshot; do not retain across refreshes.
class PodLookup
{
  ** Thread-local compatibility routing: no mutable global namespace or actor
  ** sharing. Server entry points install their own service on the dispatch thread.
  static PodLookup current()
  {
    p := Actor.locals["fantomLsp.podLookup"] as PodLookup
    if (p == null) Actor.locals["fantomLsp.podLookup"] = p = PodLookup()
    return p
  }

  Void install() { Actor.locals["fantomLsp.podLookup"] = this }

  ** D6: runtime FAN_ENV_PATH is NOT a source of workspace lookup roots.
  new make(File[] roots := File[,]) { configure(roots) }

  private File[] roots := File[,]
  private Str:Str stamps := [:]
  private LspNamespace? cached

  Void configure(File[] roots)
  {
    this.roots = roots.map |r->File| { r.normalize }.unique
    cached = null
    stamps.clear
  }

  LspNamespace namespace()
  {
    now := Str:Str[:]
    files := LspNamespace.workspaceFiles(roots)
    files.each |f, name|
    {
      now[name] = "${f.osPath}|${f.modified.ticks}|${f.size}"
    }
    if (cached == null || now != stamps)
    {
      cached = LspNamespace(roots, files)
      stamps = now
    }
    return cached
  }

  ** CompilerInput.ns is mutable/compiler-associated: never share service cache
  ** with a compiler or another actor. Freeze roots into the actor request.
  LspNamespace freshNamespace() { LspNamespace(roots) }
  File[] envPath() { roots.dup }

  CType? findType(Str podName, Str name)
  {
    ns := namespace
    try { return ns.resolvePod(podName, null).resolveType(name, false) }
    catch (CompilerErr e) { return null }
  }

  CSlot? findSlot(Str podName, Str typeName, Str slotName)
  {
    findType(podName, typeName)?.slot(slotName)
  }

  CType? findTypeInPods(Str[] podNames, Str name)
  {
    ns := namespace
    return podNames.eachWhile |pn| { tryType(ns, pn, name) }
  }

  CType? findTypeInAnyPod(Str name)
  {
    ns := namespace // one filesystem/stamp snapshot for the entire search
    names := ns.workspacePodNames
    Env.cur.findAllPodNames.each |pn| { if (!names.contains(pn)) names.add(pn) }
    return names.eachWhile |pn| { tryType(ns, pn, name) }
  }

  private CType? tryType(LspNamespace ns, Str podName, Str name)
  {
    try { return ns.resolvePod(podName, null).resolveType(name, false) }
    catch (Err e)
    {
      // An unrelated corrupt/unknown pod must not abort a broad search. Never
      // retry that pod through reflection. Preserve this snapshot's successful
      // types/docs: resolvePod caches a pod only after findPod succeeds.
      Env.cur.err.printLine("[fantomLsp] Skipping pod $podName in type search: $e.msg")
      return null
    }
  }

  Str? typeDoc(CType t) { t.doc?.text ?: namespace.documentation(t.qname) }
  Str? slotDoc(CSlot s) { s.doc?.text ?: namespace.documentation(s.qname) }

  ** Compatibility ONLY: sys::Type is final and cannot wrap a CType. Suppress
  ** workspace pods instead of loading them into the JVM or serving stale Types.
  Type? reflectionType(Str podName, Str name)
  {
    if (namespace.podFile(podName) != null) return null
    return Pod.find(podName, false)?.type(name, false)
  }

  Type? reflectionTypeInAnyPod(Str name)
  {
    ns := namespace
    return Env.cur.findAllPodNames.eachWhile |pn|
    {
      // Filter BEFORE Pod.find: Pod.list eagerly loads every runtime pod.
      if (ns.podFile(pn) != null) return null
      try
      {
        pod := Pod.find(pn, false)
        if (pod == null) Env.cur.err.printLine("[fantomLsp] Skipping unavailable reflection pod $pn")
        return pod?.type(name, false)
      }
      catch (Err e)
      {
        Env.cur.err.printLine("[fantomLsp] Skipping reflection pod $pn: $e.msg")
        return null
      }
    }
  }

  Void logEnvironment(OutStream out := Env.cur.err)
  {
    sep := Env.cur.os == "win32" ? ";" : ":"
    out.printLine("[fantomLsp] Runtime env path: " + Env.cur.path.map |r->Str| { r.osPath }.join(sep))
    out.printLine("[fantomLsp] Effective env path: " + roots.map |r->Str| { r.osPath }.join(sep))
    ns := namespace
    ns.workspacePodNames.each |name|
    {
      try
      {
        pod := ns.resolvePod(name, null)
        out.printLine("[fantomLsp] Workspace pod $name ${pod.version}: ${ns.podFile(name).osPath}")
      }
      catch (Err e) { out.printLine("[fantomLsp] Workspace pod $name ${ns.podFile(name)}: FAILED $e.msg") }
    }
  }
}
