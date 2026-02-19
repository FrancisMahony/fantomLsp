using compiler

class CompilerDiagnostics
{
  CompilerErr[] compileAndGetErrors(Str uri, Str sourceCode)
  {
    Env.cur.err.printLine("[CompilerDiagnostics] === START compileAndGetErrors for $uri ===")

    try
    {
      buildFan := findBuildFan(uri)

      if (buildFan != null)
      {
        Env.cur.err.printLine("[CompilerDiagnostics] Found build.fan at: ${buildFan.osPath}")
        return compileProjectFile(uri, buildFan)
      }
      else
      {
        Env.cur.err.printLine("[CompilerDiagnostics] No build.fan found, using standalone mode")
        return compileStandaloneFile(sourceCode)
      }
    }
    catch (Err e)
    {
      Env.cur.err.printLine("[CompilerDiagnostics] Error: $e")
      e.trace
      return CompilerErr[,]
    }
  }

  private CompilerErr[] compileProjectFile(Str uri, File buildFan)
  {
    Env.cur.err.printLine("[CompilerDiagnostics] === Compiling as PROJECT file ===")

    try
    {
      srcDir := findSourceDir(buildFan)
      if (srcDir == null)
      {
        Env.cur.err.printLine("[CompilerDiagnostics] ERROR: Could not find source directory (fan/ or src/)")
        return CompilerErr[,]
      }

      Env.cur.err.printLine("[CompilerDiagnostics] Source dir: ${srcDir.osPath}")

      fanFiles := File[,]
      srcDir.walk |f|
      {
        if (f.ext == "fan") fanFiles.add(f)
      }
      Env.cur.err.printLine("[CompilerDiagnostics] Found ${fanFiles.size} .fan files")

      if (fanFiles.isEmpty)
      {
        Env.cur.err.printLine("[CompilerDiagnostics] ERROR: No .fan files found in source directory")
        return CompilerErr[,]
      }

      input := CompilerInput()
      input.podName = "temp"
      input.summary = "LSP compilation"
      input.version = Version("1.0")
      input.baseDir = buildFan.parent
      input.srcFiles = fanFiles.map |f| { f.uri }
      input.mode = CompilerInputMode.file
      input.output = CompilerOutputMode.transientPod

      depends := extractDependenciesFromBuildFan(buildFan)
      Env.cur.err.printLine("[CompilerDiagnostics] Dependencies: $depends")
      input.depends = depends

      silentBuf := Buf()
      input.log = CompilerLog(silentBuf.out)

      Env.cur.err.printLine("[CompilerDiagnostics] Starting compilation...")
      c := Compiler(input)

      try
      {
        c.compile
      }
      catch (CompilerErr err)
      {
      }
      catch (Err e)
      {
      }

      Env.cur.err.printLine("[CompilerDiagnostics] Compilation complete. Total errors: ${c.errs.size}")
      filtered := filterErrorsForFile(c.errs, uri)
      Env.cur.err.printLine("[CompilerDiagnostics] Filtered errors for this file: ${filtered.size}")

      return filtered
    }
    catch (Err e)
    {
      Env.cur.err.printLine("[CompilerDiagnostics] Project compile error: $e")
      e.trace
      return CompilerErr[,]
    }
  }

  private CompilerErr[] compileStandaloneFile(Str sourceCode)
  {
    Env.cur.err.printLine("[CompilerDiagnostics] === Compiling as STANDALONE file ===")

    try
    {
      input := CompilerInput()
      input.podName = "temp"
      input.summary = "LSP compilation"
      input.version = Version("1.0")
      input.srcStr = sourceCode
      input.srcStrLoc = Loc.makeUninit
      input.mode = CompilerInputMode.str
      input.output = CompilerOutputMode.transientPod

      depends := extractDependenciesFromSource(sourceCode)
      Env.cur.err.printLine("[CompilerDiagnostics] Dependencies: $depends")
      input.depends = depends

      silentBuf := Buf()
      input.log = CompilerLog(silentBuf.out)

      c := Compiler(input)

      try
      {
        c.compile
      }
      catch (CompilerErr err)
      {
      }
      catch (Err e)
      {
      }

      Env.cur.err.printLine("[CompilerDiagnostics] Compilation complete. Errors: ${c.errs.size}")
      return c.errs
    }
    catch (Err e)
    {
      Env.cur.err.printLine("[CompilerDiagnostics] Standalone compile error: $e")
      e.trace
      return CompilerErr[,]
    }
  }

  private CompilerErr[] filterErrorsForFile(CompilerErr[] errs, Str uri)
  {
    try
    {
      if (!uri.startsWith("file://"))
        return errs

      filePath := uri["file://".size..-1]
      if (filePath.startsWith("/") && filePath.size > 2 && filePath[2] == ':')
        filePath = filePath[1..-1]

      targetFile := File.os(filePath)
      targetName := targetFile.name

      Env.cur.err.printLine("[CompilerDiagnostics] Filtering for file: $targetName")

      return errs.findAll |err|
      {
        if (err.file == null)
          return false
        return err.file.endsWith(targetName)
      }
    }
    catch (Err e)
    {
      return errs
    }
  }

  private File? findSourceDir(File buildFan)
  {
    try
    {
      baseDir := buildFan.parent

      fanDir := baseDir + `fan/`
      if (fanDir.exists && fanDir.isDir)
        return fanDir

      srcDir := baseDir + `src/`
      if (srcDir.exists && srcDir.isDir)
        return srcDir

      return null
    }
    catch (Err e)
    {
      return null
    }
  }

  private File? findBuildFan(Str uri)
  {
    try
    {
      Env.cur.err.printLine("[CompilerDiagnostics] Looking for build.fan for URI: $uri")

      if (!uri.startsWith("file://"))
      {
        Env.cur.err.printLine("[CompilerDiagnostics] URI doesn't start with file://")
        return null
      }

      filePath := uri["file://".size..-1]
      Env.cur.err.printLine("[CompilerDiagnostics] Extracted path: $filePath")

      filePath = filePath.replace("%3A", ":").replace("%3a", ":")
      Env.cur.err.printLine("[CompilerDiagnostics] URL-decoded path: $filePath")

      if (filePath.startsWith("/") && filePath.size > 2 && filePath[2] == ':')
        filePath = filePath[1..-1]

      Env.cur.err.printLine("[CompilerDiagnostics] Normalized path: $filePath")

      file := File.os(filePath)

      if (!file.exists)
      {
        Env.cur.err.printLine("[CompilerDiagnostics] File doesn't exist")
        return null
      }

      dir := file.parent
      Env.cur.err.printLine("[CompilerDiagnostics] Starting directory: ${dir.osPath}")

      while (dir != null)
      {
        buildFan := dir + `build.fan`
        Env.cur.err.printLine("[CompilerDiagnostics] Checking: ${buildFan.osPath}")

        if (buildFan.exists)
        {
          Env.cur.err.printLine("[CompilerDiagnostics] FOUND build.fan!")
          return buildFan
        }

        parent := dir.parent
        if (parent == null || parent == dir)
        {
          Env.cur.err.printLine("[CompilerDiagnostics] Reached root, stopping search")
          break
        }
        dir = parent
      }

      Env.cur.err.printLine("[CompilerDiagnostics] No build.fan found in any parent directory")
      return null
    }
    catch (Err e)
    {
      Env.cur.err.printLine("[CompilerDiagnostics] Error in findBuildFan: $e")
      e.trace
      return null
    }
  }

  private Depend[] extractDependenciesFromBuildFan(File buildFan)
  {
    try
    {
      content := buildFan.readAllStr
      depends := Depend[,]

      inDepends := false
      braceDepth := 0

      content.splitLines.each |line|
      {
        trimmed := line.trim

        if (trimmed.startsWith("depends"))
        {
          inDepends = true
        }

        if (inDepends)
        {
          braceDepth += trimmed.split('[').size - 1
          braceDepth -= trimmed.split(']').size - 1

          if (trimmed.contains("\"") && !trimmed.startsWith("//"))
          {
            quoted := trimmed.split('"')
            if (quoted.size >= 2)
            {
              depStr := quoted[1].trim
              if (!depStr.isEmpty)
              {
                spaceIdx := depStr.index(" ")
                podName := (spaceIdx != null) ? depStr[0..<spaceIdx] : depStr

                if (!podName.isEmpty && podName != "sys")
                {
                  try
                  {
                    depends.add(Depend("${podName} 1.0+"))
                    Env.cur.err.printLine("[CompilerDiagnostics] Extracted dependency: ${podName} 1.0+")
                  }
                  catch (Err e)
                  {
                    Env.cur.err.printLine("[CompilerDiagnostics] Failed to add dependency: $podName - $e")
                  }
                }
              }
            }
          }

          if (braceDepth <= 0 && trimmed.contains("]"))
          {
            inDepends = false
          }
        }
      }

      if (depends.isEmpty)
        depends.add(Depend("sys 1.0+"))

      return depends
    }
    catch (Err e)
    {
      Env.cur.err.printLine("[CompilerDiagnostics] Error parsing build.fan: $e")
      return [Depend("sys 1.0+")]
    }
  }

  private Depend[] extractDependenciesFromSource(Str sourceCode)
  {
    depends := Depend[,]
    depends.add(Depend("sys 1.0+"))

    sourceCode.splitLines.each |line|
    {
      trimmed := line.trim
      if (trimmed.startsWith("using "))
      {
        podName := trimmed["using ".size..-1].trim
        if (podName.endsWith(";"))
          podName = podName[0..<-1]

        colonIdx := podName.index("::")
        if (colonIdx != null)
          podName = podName[0..<colonIdx]

        if (!podName.isEmpty && podName != "sys")
        {
          try
          {
            depends.add(Depend("${podName} 1.0+"))
            Env.cur.err.printLine("[CompilerDiagnostics] Auto-extracted dependency: $podName")
          }
          catch (Err e) { }
        }
      }
    }

    return depends
  }

  ParseError[] convertToParseErrors(CompilerErr[] errs)
  {
    return errs.map |err -> ParseError|
    {
      line := (err.line ?: 1) - 1
      col := (err.col ?: 0)

      range := LspRange(
        Position(line, col),
        Position(line, col + 10)
      )

      return ParseError(range, err.msg)
    }
  }
}
