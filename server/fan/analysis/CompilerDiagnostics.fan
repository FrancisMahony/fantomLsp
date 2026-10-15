using compiler

class CompilerDiagnostics
{
  CompilerErr[] compileAndGetErrors(Str uri, Str sourceCode)
  {
    try
    {
      buildFan := findBuildFan(uri)
      key := UriKey.canonical(uri)
      files := buildFan == null ? Str[key] : sourceFiles(buildFan)
      name := buildFan == null ? "lspStandalone" : parsePodName(buildFan)
      if (name == null) throw ArgErr("build.fan has no literal podName: $buildFan")
      req := SemanticCompileRequest(1, buildFan == null ? key : WorkspaceManager.fileToUri(buildFan),
        name, buildFan, files, [key: sourceCode], [key: 1])
      compiler := SemanticCompile().attempt(req, req.texts)
      return filterErrorsForFile(compiler.errs, key)
    }
    catch (Err e)
    {
      Env.cur.err.printLine("[CompilerDiagnostics] Error: $e")
      return CompilerErr[,]
    }
  }

  internal Str[] sourceFiles(File buildFan)
  {
    files := File[,]
    parseSrcDirs(buildFan).each |dir|
    {
      if (dir.exists && dir.isDir) collectFanFiles(dir, files)
    }
    return files.map |f->Str| { WorkspaceManager.fileToUri(f) }.unique.sort
  }

  ** Unique ident for CompilerInput.podName (avoid colliding transient pods).
  internal static Str uniqueTransientPodName()
  {
    raw := Uuid.make.toStr.replace("-", "")
    if (raw.size > 24) raw = raw[0..<24]
    return "lspTemp" + raw
  }

  private Void collectFanFiles(File dir, File[] acc)
  {
    dir.list.each |f|
    {
      if (!f.isDir && f.ext == "fan")
        acc.add(f)
    }
  }

  ** Read the literal podName assignment without executing the build script.
  internal Str? parsePodName(File buildFan)
  {
    try
    {
      masks := maskBuildComments(buildFan.readAllStr)
      matcher := Regex("(?m)^\\s*(podName)\\s*=\\s*\"([^\"]+)\"").matcher(masks[0])
      while (matcher.find)
      {
        // Strings are preserved for the RHS, but are not executable assignments.
        if (masks[1][matcher.start(1)] == 'p') return matcher.group(2)
      }
    }
    catch (Err e) { Env.cur.err.printLine("[CompilerDiagnostics] Error parsing podName: $e") }
    return null
  }

  ** Equal-length lexical views: comments masked / comments and literals masked.
  ** Keep newlines and offsets, and never treat comment markers inside literals
  ** as comments. The second view guards matches inside multiline string text.
  private Str[] maskBuildComments(Str text)
  {
    comments := StrBuf()
    code := StrBuf()
    blockDepth := 0
    lineComment := false
    quote := 0
    triple := false
    lineStart := true
    i := 0
    while (i < text.size)
    {
      ch := text[i]
      next := i + 1 < text.size ? text[i+1] : 0
      count := 1
      comment := blockDepth > 0 || lineComment
      literal := quote != 0
      if (lineComment)
      {
        if (ch == '\n' || ch == '\r') lineComment = false
      }
      else if (blockDepth > 0)
      {
        if (ch == '/' && next == '*') { blockDepth++; count = 2 }
        else if (ch == '*' && next == '/') { blockDepth--; count = 2 }
      }
      else if (quote != 0)
      {
        if (ch == '\\' && i + 1 < text.size) count = 2
        else if (triple)
        {
          if (ch == '"' && next == '"' && i + 2 < text.size && text[i+2] == '"')
          { quote = 0; triple = false; count = 3 }
        }
        else if (ch == quote) quote = 0
      }
      else if (ch == '/' && (next == '/' || next == '*'))
      {
        comment = true
        count = 2
        if (next == '/') lineComment = true
        else blockDepth = 1
      }
      else if (lineStart && ch == '*' && next == '*')
      {
        comment = true
        lineComment = true
        count = 2
      }
      else if (ch == '"' || ch == '\'' || ch == '`')
      {
        literal = true
        quote = ch
        triple = ch == '"' && next == '"' && i + 2 < text.size && text[i+2] == '"'
        if (triple) count = 3
      }
      for (j := 0; j < count; j++)
      {
        c := text[i+j]
        newline := c == '\n' || c == '\r'
        if (newline) lineStart = true
        else if (!c.isSpace) lineStart = false
        comments.addChar(comment && !newline ? ' ' : c)
        code.addChar((comment || literal) && !newline ? ' ' : c)
      }
      i += count
    }
    return [comments.toStr, code.toStr]
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
      masks := maskBuildComments(buildFan.readAllStr)
      depends := Depend[,]

      // Load macro values from the nearest etc/build/config.props
      buildProps := Str:Str[:]
      propsFile := findBuildProps(buildFan)
      if (propsFile != null)
        buildProps = parsePropsFile(propsFile)

      // Match a field assignment, never metadata keys, literals, comments,
      // longer identifiers, equality checks, or another object's member.
      // Explicit this.depends is the same BuildPod field as bare depends.
      matcher := Regex("(?<![A-Za-z0-9_.\$])(?:this\\s*\\.\\s*)?(depends)\\s*=(?!=)").matcher(masks[0])
      while (matcher.find)
      {
        if (masks[1][matcher.start(1)] != 'd') continue
        prev := matcher.start - 1
        while (prev >= 0 && masks[0][prev].isSpace) prev--
        if (prev >= 0 && masks[0][prev] == '.') continue
        entries := staticDependEntries(masks[0], matcher.end)
        if (entries == null) continue
        entries.each |depStr|
        {
          resolvedDep := resolveMacros(depStr.trim, buildProps)
          if (!resolvedDep.isEmpty)
          {
            try { depends.add(Depend(resolvedDep)) }
            catch (Err e)
            {
              Env.cur.err.printLine("[CompilerDiagnostics] Invalid depend '$resolvedDep': $e")
            }
          }
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

  ** Recognize only an entire static list RHS. Do not salvage quoted fragments
  ** from calls, maps, concatenations, interpolations, or mixed dynamic lists.
  ** Comments are already masked; delimiters inside strings remain literal.
  private Str[]? staticDependEntries(Str text, Int offset)
  {
    i := offset
    while (i < text.size && text[i].isSpace) i++
    // Only the built-in string-list annotation is recognized, not arbitrary
    // type names, constructors, casts, or evaluated expressions.
    if (i < text.size && text[i] != '[')
    {
      typed := Regex("^(?:sys\\s*::\\s*)?Str\\s*\\[").matcher(text[i..-1])
      if (!typed.find) return null
      i += typed.end - 1
    }
    if (i >= text.size || text[i] != '[') return null
    i++
    entries := Str[,]
    while (true)
    {
      while (i < text.size && text[i].isSpace) i++
      if (i >= text.size) return null
      if (text[i] == ']') break
      if (text[i] != '"') return null
      start := ++i
      while (i < text.size && text[i] != '"')
      {
        // Dependency literals need no Fantom escaping or interpolation.
        // BuildPod @{key} macros are resolved separately, as before.
        if (text[i] == '\\' || text[i] == '$' || text[i] == '\n' || text[i] == '\r') return null
        i++
      }
      if (i >= text.size) return null
      entries.add(text[start..<i])
      i++
      while (i < text.size && text[i].isSpace) i++
      if (i >= text.size) return null
      if (text[i] == ']') break
      if (text[i] != ',') return null
      i++
    }

    // A closing bracket alone does not prove a static RHS: ["sys 1.0"]
    // + moreDeps and ["sys 1.0"].add(...) are dynamic, even across lines.
    i++
    newline := false
    while (i < text.size && text[i].isSpace)
    {
      if (text[i] == '\n' || text[i] == '\r') newline = true
      i++
    }
    if (i < text.size && text[i] != ';' && text[i] != '}')
    {
      if (!newline || ".+-*/%&|^?:[<>=,({".containsChar(text[i])) return null
    }
    return entries
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
      file := WorkspaceManager.uriToFile(uri)
      if (file == null || !file.exists)
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

  internal CompilerErr[] filterErrorsForFile(CompilerErr[] errs, Str uri)
  {
    try
    {
      file := WorkspaceManager.uriToFile(uri)
      if (file == null)
        return CompilerErr[,]

      targetPath := file.normalize.osPath.replace("\\", "/")
      windows := Env.cur.os == "win32"
      if (windows) targetPath = targetPath.lower

      return errs.findAll |err|
      {
        if (err.file == null) return false
        try
        {
          errorFile := err.file.lower.startsWith("file:") ? WorkspaceManager.uriToFile(err.file) : File.os(err.file)
          if (errorFile == null) return false
          errorPath := errorFile.normalize.osPath.replace("\\", "/")
          if (windows) errorPath = errorPath.lower
          return errorPath == targetPath
        }
        catch (Err e) return false
      }
    }
    catch (Err e)
    {
      return CompilerErr[,]
    }
  }

  internal Depend[] extractDependenciesFromSource(Str sourceCode)
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
