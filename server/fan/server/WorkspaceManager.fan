class WorkspaceManager
{
  private Str[] folders := [,]
  // Keep `lib` excluded like node_modules-style junk (installed pods / vendor trees).
  // Project sources should live under `fan/` or `src/`, not a workspace-root `lib/`.
  Str[] excludeDirs := [".git", "node_modules", ".hg", "build", "out", "dist", ".svn", "__pycache__", "lib", "temp", "tmp"]
  Int maxFiles := 0

  ** True once any workspace folder has been added. A session that had folders
  ** never falls back to standalone (folder-less) semantics, even after the
  ** last folder is removed.
  Bool everHadFolders := false { private set }

  Void addFolder(Str uri)
  {
    uri = UriKey.canonical(uri)
    everHadFolders = true
    if (!folders.contains(uri)) folders.add(uri)
  }

  **
  ** Whether disk content for `key` belongs in the index: in a folder-less
  ** (standalone) session any file does; once folders were used, only files
  ** under a current workspace folder do.
  **
  Bool isIndexable(Str key)
  {
    !everHadFolders || folderFor(key) != null
  }

  Void removeFolder(Str uri)
  {
    folders.remove(UriKey.canonical(uri))
  }

  Str[] getFolders() { folders }

  ** Return the longest matching workspace folder, respecting path boundaries.
  Str? folderFor(Str uri)
  {
    uri = UriKey.canonical(uri)
    Str? best := null
    folders.each |folder|
    {
      prefix := folder.endsWith("/") ? folder : folder + "/"
      if (uri == folder || uri.startsWith(prefix))
      {
        if (best == null || folder.size > best.size) best = folder
      }
    }
    return best
  }

  **
  ** Synchronous main-thread index for tests and synchronous paths.
  ** Keys for which `skip` returns true (open documents) are not applied.
  **
  Void indexWorkspace(SymbolTable symbolTable, TypeResolver typeResolver, ReferenceIndex referenceIndex, |Str->Bool|? skip := null)
  {
    Env.cur.err.printLine("[fantomLsp] Indexing workspace folders: $folders")
    collectFiles.each |file|
    {
      if (skip != null && skip(file.key)) return
      entry := parseIndexFile(file)
      if (entry != null) applyIndexEntry(entry, symbolTable, typeResolver, referenceIndex)
    }
    Env.cur.err.printLine("[fantomLsp] Indexing complete. Symbols indexed for ${symbolTable.allEntries.size} entries")
  }

  ** Main thread: snapshot this manager's settings into a pure collection.
  IndexFile[] collectFiles()
  {
    collectWorkspaceFiles(folders.dup, excludeDirs.dup, maxFiles)
  }

  **
  ** Pure (any thread): discover source files under `folders`. Pods (build.fan
  ** directories) are indexed per pod; folders without build.fan are indexed as a
  ** single tree. `maxFiles > 0` limits each indexed directory, as before.
  **
  static IndexFile[] collectWorkspaceFiles(Str[] folders, Str[] excludeDirs, Int maxFiles)
  {
    result := IndexFile[,]
    folders.each |folderUri|
    {
      dir := uriToFile(folderUri)
      if (dir == null || !dir.exists) return
      pods := File[,]
      findBuildPodsIn(dir, pods, 0, excludeDirs)
      roots := pods.isEmpty ? [dir] : pods
      roots.each |root|
      {
        fanFiles := File[,]
        collectFanFilesIn(root, fanFiles, excludeDirs)
        limit := fanFiles.size
        if (maxFiles > 0) limit = maxFiles.min(fanFiles.size)
        for (i := 0; i < limit; i++)
          result.add(IndexFile(fileToUri(fanFiles[i]), fanFiles[i], folderUri))
        if (maxFiles > 0 && fanFiles.size > maxFiles)
          Env.cur.err.printLine("[fantomLsp] Reached max file limit ($maxFiles) under $root, skipped ${fanFiles.size - maxFiles} files")
      }
    }
    return result
  }

  **
  ** Pure (any thread): read and parse one file. The returned entry is owned by
  ** the caller; producers hand it over and never touch it again.
  **
  static IndexEntry? parseIndexFile(IndexFile file)
  {
    try
    {
      readTicks := Duration.now.ticks
      text := file.file.readAllStr
      result := RecoveringParser().parse(file.key, text)
      hash := Buf().print(text).toDigest("SHA-1").toHex
      return IndexEntry(file.key, file.folderKey, result, hash, readTicks)
    }
    catch (Err e)
    {
      Env.cur.err.printLine("[fantomLsp] Error indexing $file.file: $e.msg")
      return null
    }
  }

  ** Main thread only: apply a parsed entry to the analysis state.
  static Void applyIndexEntry(IndexEntry entry, SymbolTable symbolTable, TypeResolver typeResolver, ReferenceIndex referenceIndex)
  {
    symbolTable.update(entry.key, entry.result)
    typeResolver.updateUsings(entry.key, entry.result)
    referenceIndex.update(entry.key, entry.result)
  }

  ** Discover directories that contain build.fan (Fantom pods), skipping excludeDirs.
  internal Void findBuildPods(File dir, File[] acc, Int depth)
  {
    findBuildPodsIn(dir, acc, depth, excludeDirs)
  }

  private static Void findBuildPodsIn(File dir, File[] acc, Int depth, Str[] excludeDirs)
  {
    if (depth > 12) return
    build := dir + `build.fan`
    if (build.exists)
    {
      acc.add(dir)
      return
    }
    dir.list.each |f|
    {
      if (!f.isDir) return
      if (excludeDirs.contains(f.name)) return
      findBuildPodsIn(f, acc, depth + 1, excludeDirs)
    }
  }

  private static Void collectFanFilesIn(File dir, File[] acc, Str[] excludeDirs)
  {
    dir.list.each |f|
    {
      if (f.isDir)
      {
        if (!excludeDirs.contains(f.name))
          collectFanFilesIn(f, acc, excludeDirs)
      }
      else if (f.ext == "fan" || f.ext == "fwt")
      {
        acc.add(f)
      }
    }
  }

  static Bool isFanSourceUri(Str uri)
  {
    lower := uri.lower
    return lower.endsWith(".fan") || lower.endsWith(".fwt")
  }

  static File? uriToFile(Str uri)
  {
    try
    {
      key := UriKey.canonical(uri)
      if (!key.startsWith("file://")) return null
      path := UriKey.decodePath(key["file://".size..-1])
      if (!key.startsWith("file:///")) path = "//" + path
      // Windows drive paths are not rooted POSIX paths.
      if (path.size > 2 && path[2] == ':') path = path[1..-1]
      if (path.size > 1 && path[1] == ':' && path[0].isAlpha)
        path = path[0].upper.toChar + path[1..-1]
      return File.os(path)
    }
    catch (Err e) return null
  }

  static Str fileToUri(File f)
  {
    path := f.normalize.osPath
    if (path == null) return UriKey.canonical("file:///${f.uri.encode}")
    path = path.replace("\\", "/")
    if (path.startsWith("//")) return UriKey.canonical("file:" + path.replace("%", "%25"))
    if (!path.startsWith("/")) path = "/" + path
    // osPath is already decoded; protect literal percent signs before intake.
    return UriKey.canonical("file://" + path.replace("%", "%25"))
  }
}

** A discovered workspace source file (immutable; safe on any thread).
const class IndexFile
{
  ** Canonical URI key.
  const Str key
  const File file
  ** Canonical key of the workspace folder that produced this file.
  const Str folderKey

  new make(Str key, File file, Str folderKey)
  {
    this.key = key
    this.file = file
    this.folderKey = folderKey
  }
}

**
** One parsed file produced off the main thread. The producer hands it over
** (inside an `Unsafe` batch) and never touches it again; after hand-over it is
** owned by the main thread.
**
class IndexEntry
{
  const Str key
  const Str folderKey
  ParseResult result
  ** SHA-1 of the parsed text.
  const Str contentHash
  ** `Duration.now.ticks` taken before the file was read. Main-thread events
  ** stamped later than this (watched-file changes, didClose re-reads) win.
  const Int readTicks

  new make(Str key, Str folderKey, ParseResult result, Str contentHash, Int readTicks)
  {
    this.key = key
    this.folderKey = folderKey
    this.result = result
    this.contentHash = contentHash
    this.readTicks = readTicks
  }
}
