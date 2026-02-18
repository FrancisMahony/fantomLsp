class WorkspaceManager
{
  private Str[] folders := [,]
  private Str:Str fileContents := [:]
  private static const Str[] excludeDirs := [".git", "node_modules", ".hg", "build", "out", "dist", ".svn", "__pycache__", "lib", "temp", "tmp"]
  private static const Int maxFiles := 500

  Void addFolder(Str uri)
  {
    if (!folders.contains(uri)) folders.add(uri)
  }

  Str[] getFolders() { folders }

  Void indexWorkspace(SymbolTable symbolTable, TypeResolver typeResolver, ReferenceIndex referenceIndex)
  {
    Env.cur.err.printLine("[fantomLsp] Indexing workspace folders: $folders")
    folders.each |folderUri|
    {
      dir := uriToFile(folderUri)
      if (dir == null || !dir.exists) return
      indexDir(dir, folderUri, symbolTable, typeResolver, referenceIndex)
    }
    Env.cur.err.printLine("[fantomLsp] Indexing complete. Symbols indexed for ${symbolTable.allEntries.size} entries")
  }

  private Void indexDir(File dir, Str rootUri, SymbolTable symbolTable, TypeResolver typeResolver, ReferenceIndex referenceIndex)
  {
    fanFiles := File[,]
    collectFanFiles(dir, fanFiles)
    Env.cur.err.printLine("[fantomLsp] Found ${fanFiles.size} .fan files to index")
    limit := maxFiles.min(fanFiles.size)
    for (i := 0; i < limit; i++)
    {
      f := fanFiles[i]
      try
      {
        fileUri := fileToUri(f)
        text := f.readAllStr

        parser := RecoveringParser()
        result := parser.parse(fileUri, text)
        symbolTable.update(fileUri, result)
        typeResolver.updateUsings(fileUri, result)
        referenceIndex.update(fileUri, result)
      }
      catch (Err e)
      {
        Env.cur.err.printLine("[fantomLsp] Error indexing $f: $e.msg")
      }
    }
    if (fanFiles.size > maxFiles)
      Env.cur.err.printLine("[fantomLsp] Reached max file limit ($maxFiles), skipped ${fanFiles.size - maxFiles} files")
  }

  private Void collectFanFiles(File dir, File[] acc)
  {
    dir.list.each |f|
    {
      if (f.isDir)
      {
        if (!excludeDirs.contains(f.name))
          collectFanFiles(f, acc)
      }
      else if (f.ext == "fan")
      {
        acc.add(f)
      }
    }
  }

  Str? getFileContent(Str uri) { fileContents[uri] }

  Str[] getAllFileUris() { fileContents.keys }

  static File? uriToFile(Str uri)
  {
    try
    {
      path := uri
      if (path.startsWith("file:///"))
      {
        path = path["file:///".size..-1]
        if (!path.startsWith("/")) path = "/" + path
      }
      else if (path.startsWith("file://"))
      {
        path = path["file://".size..-1]
      }
      path = Uri.decode(path).toStr
      return File.os(path)
    }
    catch (Err e) return null
  }

  static Str fileToUri(File f)
  {
    path := f.normalize.osPath
    if (path == null) return "file:///${f.uri}"
    path = path.replace("\\", "/")
    if (!path.startsWith("/")) path = "/" + path
    return "file://" + path.toUri.encode
  }
}
