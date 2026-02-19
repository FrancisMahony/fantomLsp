using compiler

class CompilerDiagnostics
{
  CompilerErr[] compileAndGetErrors(Str uri, Str sourceCode)
  {
    try
    {
      buildFan := findBuildFan(uri)
      if (buildFan != null)
        return compileProjectFile(uri, buildFan)
      else
        return compileStandaloneFile(sourceCode)
    }
    catch (Err e)
    {
      Env.cur.err.printLine("[CompilerDiagnostics] Error: $e")
      return CompilerErr[,]
    }
  }

  private CompilerErr[] compileProjectFile(Str uri, File buildFan)
  {
    try
    {
      srcDirs := parseSrcDirs(buildFan)
      if (srcDirs.isEmpty)
      {
        Env.cur.err.printLine("[CompilerDiagnostics] No srcDirs found in build.fan")
        return CompilerErr[,]
      }

      fanFiles := File[,]
      srcDirs.each |dir|
      {
        if (dir.exists && dir.isDir)
          dir.list.each |f| { if (f.ext == "fan") fanFiles.add(f) }
      }

      if (fanFiles.isEmpty)
      {
        Env.cur.err.printLine("[CompilerDiagnostics] No .fan files found in srcDirs")
        return CompilerErr[,]
      }

      input := CompilerInput()
      input.podName = "temp"
      input.summary = "LSP compilation"
      input.version = Version("1.0")
      input.baseDir = buildFan.parent
      input.srcFiles = fanFiles.map |f -> Uri| { f.uri }
      input.mode = CompilerInputMode.file
      input.output = CompilerOutputMode.transientPod
      input.depends = extractDependenciesFromBuildFan(buildFan)

      silentBuf := Buf()
      input.log = CompilerLog(silentBuf.out)

      c := Compiler(input)
      try { c.compile } catch (CompilerErr e) {} catch (Err e) {}

      return filterErrorsForFile(c.errs, uri)
    }
    catch (Err e)
    {
      Env.cur.err.printLine("[CompilerDiagnostics] Project compile error: $e")
      return CompilerErr[,]
    }
  }

  private CompilerErr[] compileStandaloneFile(Str sourceCode)
  {
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
      input.depends = extractDependenciesFromSource(sourceCode)

      silentBuf := Buf()
      input.log = CompilerLog(silentBuf.out)

      c := Compiler(input)
      try { c.compile } catch (CompilerErr e) {} catch (Err e) {}

      return c.errs
    }
    catch (Err e)
    {
      Env.cur.err.printLine("[CompilerDiagnostics] Standalone compile error: $e")
      return CompilerErr[,]
    }
  }

  ** Parse the srcDirs array from a build.fan file.
  ** Returns File objects for each listed directory, relative to buildFan.parent.
  internal File[] parseSrcDirs(File buildFan)
  {
    try
    {
      content := buildFan.readAllStr
      baseDir := buildFan.parent
      dirs := File[,]

      inSrcDirs := false
      bracketDepth := 0

      content.splitLines.each |line|
      {
        trimmed := line.trim

        if (!inSrcDirs && trimmed.contains("srcDirs"))
          inSrcDirs = true

        if (inSrcDirs)
        {
          bracketDepth += trimmed.split('[').size - 1
          bracketDepth -= trimmed.split(']').size - 1

          // Extract backtick-quoted URI literals like `fan/` or `fan/protocol/`
          idx := 0
          while (idx < trimmed.size)
          {
            start := trimmed.index("`", idx)
            if (start == null) break
            end := trimmed.index("`", start + 1)
            if (end == null) break
            path := trimmed[start+1..<end]
            if (!path.isEmpty)
              dirs.add(baseDir + path.toUri)
            idx = end + 1
          }

          if (bracketDepth <= 0 && trimmed.contains("]"))
            inSrcDirs = false
        }
      }

      return dirs
    }
    catch (Err e)
    {
      Env.cur.err.printLine("[CompilerDiagnostics] Error parsing srcDirs: $e")
      return File[,]
    }
  }

  ** Extract depends from build.fan, resolving @{key} macros via etc/build/config.props.
  internal Depend[] extractDependenciesFromBuildFan(File buildFan)
  {
    try
    {
      content := buildFan.readAllStr
      depends := Depend[,]

      // Load macro values from the nearest etc/build/config.props
      buildProps := Str:Str[:]
      propsFile := findBuildProps(buildFan)
      if (propsFile != null)
        buildProps = parsePropsFile(propsFile)

      inDepends := false
      bracketDepth := 0

      content.splitLines.each |line|
      {
        trimmed := line.trim

        if (!inDepends && trimmed.contains("depends"))
          inDepends = true

        if (inDepends)
        {
          bracketDepth += trimmed.split('[').size - 1
          bracketDepth -= trimmed.split(']').size - 1

          if (trimmed.contains("\"") && !trimmed.startsWith("//"))
          {
            // Split on quotes; odd-indexed parts are the string contents
            parts := trimmed.split('"')
            idx := 1
            while (idx < parts.size)
            {
              depStr := parts[idx].trim
              if (!depStr.isEmpty)
              {
                resolvedDep := resolveMacros(depStr, buildProps)
                if (!resolvedDep.isEmpty)
                {
                  try
                  {
                    depends.add(Depend(resolvedDep))
                  }
                  catch (Err e)
                  {
                    Env.cur.err.printLine("[CompilerDiagnostics] Invalid depend '$resolvedDep': $e")
                  }
                }
              }
              idx += 2
            }
          }

          if (bracketDepth <= 0 && trimmed.contains("]"))
            inDepends = false
        }
      }

      if (depends.isEmpty)
        depends.add(Depend("sys 1.0+"))

      return depends
    }
    catch (Err e)
    {
      Env.cur.err.printLine("[CompilerDiagnostics] Error parsing depends: $e")
      return [Depend("sys 1.0+")]
    }
  }

  ** Find etc/build/config.props by walking up the directory tree from build.fan.
  internal File? findBuildProps(File buildFan)
  {
    try
    {
      dir := buildFan.parent
      while (dir != null)
      {
        candidate := dir + `etc/build/config.props`
        if (candidate.exists)
          return candidate
        parent := dir.parent
        if (parent == null || parent == dir) break
        dir = parent
      }
      // Fallback: search the Fantom environment path (same mechanism as `fan build.fan`)
      return Env.cur.findFile(`etc/build/config.props`, false)
    }
    catch (Err e)
    {
      Env.cur.err.printLine("[CompilerDiagnostics] Error in findBuildProps: $e")
      return null
    }
  }

  ** Parse a Java-style .props file (key=value lines) into a Str:Str map.
  internal Str:Str parsePropsFile(File propsFile)
  {
    try
    {
      props := Str:Str[:]
      propsFile.readAllStr.splitLines.each |line|
      {
        trimmed := line.trim
        if (trimmed.isEmpty || trimmed.startsWith("#") || trimmed.startsWith("//"))
          return
        eqIdx := trimmed.index("=")
        if (eqIdx == null) return
        key := trimmed[0..<eqIdx].trim
        val := (eqIdx + 1 < trimmed.size) ? trimmed[eqIdx+1..-1].trim : ""
        if (!key.isEmpty)
          props[key] = val
      }
      return props
    }
    catch (Err e)
    {
      Env.cur.err.printLine("[CompilerDiagnostics] Error parsing props file: $e")
      return Str:Str[:]
    }
  }

  ** Resolve @{key} macros in a string using the given props map.
  ** Any key not found in props falls back to "1.0+".
  private Str resolveMacros(Str str, Str:Str props)
  {
    result := str
    while (result.contains("@{"))
    {
      start := result.index("@{")
      if (start == null) break
      end := result.index("}", start)
      if (end == null) break
      key := result[start+2..<end]
      val := props[key] ?: "1.0+"
      prefix := result[0..<start]
      suffix := (end + 1 < result.size) ? result[end+1..-1] : ""
      result = prefix + val + suffix
    }
    return result
  }

  ** Find a build.fan by walking up the directory tree from the given file URI.
  internal File? findBuildFan(Str uri)
  {
    try
    {
      if (!uri.startsWith("file://"))
        return null

      filePath := uri["file://".size..-1]
      filePath = filePath.replace("%3A", ":").replace("%3a", ":")

      // Windows: strip leading slash before drive letter (e.g. /C:/ -> C:/)
      if (filePath.startsWith("/") && filePath.size > 2 && filePath[2] == ':')
        filePath = filePath[1..-1]

      file := File.os(filePath)
      if (!file.exists)
        return null

      dir := file.parent
      while (dir != null)
      {
        candidate := dir + `build.fan`
        if (candidate.exists)
          return candidate
        parent := dir.parent
        if (parent == null || parent == dir) break
        dir = parent
      }
      return null
    }
    catch (Err e)
    {
      Env.cur.err.printLine("[CompilerDiagnostics] Error in findBuildFan: $e")
      return null
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

      targetName := File.os(filePath).name

      return errs.findAll |err|
      {
        if (err.file == null) return false
        return err.file.endsWith(targetName)
      }
    }
    catch (Err e)
    {
      return errs
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
        if (podName.endsWith(";")) podName = podName[0..<-1]
        colonIdx := podName.index("::")
        if (colonIdx != null) podName = podName[0..<colonIdx]
        if (!podName.isEmpty && podName != "sys")
        {
          try { depends.add(Depend("${podName} 1.0+")) } catch (Err e) {}
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
      col  := (err.col  ?: 0)
      range := LspRange(Position(line, col), Position(line, col + 10))
      return ParseError(range, err.msg)
    }
  }
}
