** Main-thread registry. Identity is the canonical build.fan key, never podName.
class PodRegistry
{
  private Str:PodInfo pods := [:]

  // Derived purely from `pods`, which is replaced only by rebuild; rebuild
  // drops all three. Nothing here lists the filesystem: prefixes are string
  // forms of the PodInfo's own (immutable) srcDirs/buildFan.
  private PodInfo[]? sortedMemo
  private RegistryPrefix[]? srcPrefixes
  private RegistryPrefix[]? buildPrefixes
  private Str:Obj ownerMemo := [:]
  private static const Int ownerMemoLimit := 20000

  ** Sorted by build key; a fresh list per call (callers may mutate it).
  PodInfo[] allPods() { sorted.dup }

  private PodInfo[] sorted()
  {
    if (sortedMemo == null) sortedMemo = pods.vals.sort |a, b| { a.buildKey <=> b.buildKey }
    return sortedMemo
  }

  private Void invalidate()
  {
    sortedMemo = null; srcPrefixes = null; buildPrefixes = null; ownerMemo.clear
  }

  PodInfo? byBuildKey(Str key) { pods[UriKey.canonical(key)] }

  Void rebuild(WorkspaceManager workspace)
  {
    next := Str:PodInfo[:]
    parser := CompilerDiagnostics()
    workspace.getFolders.dup.sort.each |folder|
    {
      root := WorkspaceManager.uriToFile(folder)
      if (root == null || !root.exists || !root.isDir) return
      dirs := File[,]
      discover(workspace, root, dirs, 0)
      dirs.each |dir|
      {
        build := dir + `build.fan`
        name := parser.parsePodName(build)
        if (name == null) return
        info := PodInfo(name, build, parser.parseSrcDirs(build),
          parser.extractDependenciesFromBuildFan(build).map |d->Str| { d.name }.unique.sort,
          workspace.folderFor(WorkspaceManager.fileToUri(build)) ?: folder)
        next[info.buildKey] = info
      }
    }
    pods = next
    invalidate
  }

  ** Longest source directory wins; otherwise the nearest build ancestor wins.
  ** Ties keep the first pod in build-key order (strict > over sorted pods).
  PodInfo? podForFile(Str key)
  {
    key = UriKey.canonical(key)
    hit := ownerMemo[key]
    if (hit != null) return hit as PodInfo
    owner := computeOwner(key)
    if (ownerMemo.size >= ownerMemoLimit) ownerMemo.clear
    ownerMemo[key] = owner ?: "none"
    return owner
  }

  private PodInfo? computeOwner(Str key)
  {
    if (srcPrefixes == null)
    {
      src := RegistryPrefix[,]; builds := RegistryPrefix[,]
      sorted.each |pod|
      {
        pod.srcDirs.each |dir| { src.add(RegistryPrefix(WorkspaceManager.fileToUri(dir), pod)) }
        builds.add(RegistryPrefix(WorkspaceManager.fileToUri(pod.buildFan.parent), pod))
      }
      srcPrefixes = src; buildPrefixes = builds
    }
    PodInfo? best := null
    bestLen := -1
    srcPrefixes.each |p|
    {
      if (p.prefix.size > bestLen && contains(p.prefix, key)) { best = p.pod; bestLen = p.prefix.size }
    }
    if (best != null) return best
    buildPrefixes.each |p|
    {
      if (p.prefix.size > bestLen && contains(p.prefix, key)) { best = p.pod; bestLen = p.prefix.size }
    }
    return best
  }

  PodInfo[] byName(Str name, Str? preferFolderKey := null)
  {
    folder := preferFolderKey == null ? null : UriKey.canonical(preferFolderKey)
    return sorted.findAll |p| { p.podName == name }.sort |a, b|
    {
      ar := a.folderKey == folder ? 0 : 1
      br := b.folderKey == folder ? 0 : 1
      return ar == br ? a.buildKey <=> b.buildKey : ar <=> br
    }
  }

  Bool isWorkspacePod(Str name) { !byName(name).isEmpty }

  ** Canonical compiler source keys, deduplicated and sorted, including test/.
  Str[] filesOf(PodInfo pod)
  {
    keys := Str[,]
    pod.srcDirs.each |dir|
    {
      if (!dir.exists || !dir.isDir) return
      dir.walk |file|
      {
        if (file.isDir || file.name == "build.fan" || (file.ext != "fan" && file.ext != "fwt")) return
        key := WorkspaceManager.fileToUri(file)
        if (podForFile(key)?.buildKey == pod.buildKey) keys.add(key)
      }
    }
    return keys.unique.sort
  }

  private static Bool contains(Str dir, Str key)
  {
    key == dir || key.startsWith(dir.endsWith("/") ? dir : dir + "/")
  }

  // Workspace discovery stops at a build root; also discover nested builds.
  private Void discover(WorkspaceManager workspace, File root, File[] dirs, Int depth)
  {
    if (depth > 12) return
    found := File[,]
    workspace.findBuildPods(root, found, depth)
    found.each |dir|
    {
      dirs.add(dir)
      dir.listDirs.each |child|
      {
        if (!workspace.excludeDirs.contains(child.name))
          discover(workspace, child, dirs, depth + 1)
      }
    }
  }
}

internal const class RegistryPrefix
{
  const Str prefix
  const PodInfo pod
  new make(Str prefix, PodInfo pod) { this.prefix = prefix; this.pod = pod }
}

const class PodInfo
{
  const Str podName
  const Str buildKey
  const File buildFan
  const File[] srcDirs
  const Str[] dependNames
  const Str folderKey

  new make(Str podName, File buildFan, File[] srcDirs, Str[] dependNames, Str folderKey)
  {
    this.podName = podName
    this.buildFan = buildFan.normalize
    this.buildKey = WorkspaceManager.fileToUri(this.buildFan)
    this.srcDirs = srcDirs.map |d->File| { d.normalize }.toImmutable
    this.dependNames = dependNames.toImmutable
    this.folderKey = UriKey.canonical(folderKey)
  }
}
