using compiler

** Compiler 1.0.83.4006: TypeRef is present (feature-detected below).
** Visitor.walk(c, VisitDepth.expr) reaches generated closure doCall bodies;
** ClosureExpr.code is null after InitClosures, and TypeDef.closure.enclosingSlot
** supplies their source owner. Normalize moves field code into synthetic init
** methods (FieldDef.walkInit=false). Those bodies must not be discarded.
** Loc line/col are one-based UTF-16 positions; a tab counts as ONE character.
** Local declaration/check/generic types without a TypeRef loc are deliberately
** left to the heuristic. Extract before ClosureVars for best binding coverage.
** A pre-resolution compiler has no trustworthy index: return resolved=false
** with no declarations/occurrences; the pipeline must not publish that value.
class SemanticIndexer
{
  ** The compile pipeline must pass true only after ResolveExpr completes (including
  ** its final CompilerErr for resolution errors). Earlier step failures pass
  ** false. The default is conservative: AST literals do not prove resolution.
  SemanticSnapshot extract(Compiler c, Str:Str textByFileKey, Bool resolveExprComplete := false)
  {
    index := SemanticIndexWalk(c, textByFileKey)
    return index.extract(resolveExprComplete)
  }
}

internal class SemanticIndexWalk : Visitor
{
  new make(Compiler c, Str:Str texts)
  {
    this.c = c
    texts.each |text, key| { files[UriKey.canonical(key)] = SemanticTokens(text) }
  }

  private Compiler c
  private Str:SemanticTokens files := [:]
  private Str:SymbolDecl decls := [:]
  private Str:Occurrence[] byFile := [:]
  private Str:Occurrence[] byKey := [:]
  // Registers uniquely identify bindings within each method. Following shadows
  // first preserves captures without mutable Map keys or pod-wide linear scans.
  private Str:Str bindings := [:]
  private Str:Str fileKeys := [:]
  private Str?[] stmtOwners := [,]
  private Str? initOwner
  private Str:Str? closureOwners := [:]
  private Str:Bool seen := [:]
  private Bool declaring := true
  private TypeDef? curType
  private SlotDef? curSlot
  private Type? typeRef := Type.find("compiler::TypeRef", false)

  SemanticSnapshot extract(Bool resolveExprComplete)
  {
    pod := c.input.podName
    if (c.types == null || !resolveExprComplete) return SemanticSnapshot(pod, 0)
    walk(c, VisitDepth.expr)
    declaring = false
    walk(c, VisitDepth.expr)
    hashes := Str:Str[:]
    files.each |tokens, key| { hashes[key] = tokens.text.toBuf.toDigest("SHA-1").toHex }
    // The caller, which knows overlay provenance and generation, supplies those
    // pipeline fields. textByFileKey alone cannot distinguish disk from overlays.
    return SemanticSnapshot(pod, 0, hashes, Str:Str[:], byFile, decls, byKey, Str[,], true)
  }

  override Void enterTypeDef(TypeDef d)
  {
    curType = d
    if (!declaring || synthetic(d.qname, d.isSynthetic)) return
    supers := Str[,]
    if (d.base != null) supers.add(d.base.qname)
    d.mixins.each |t| { supers.add(t.qname) }
    declare(d.loc, d.name, d.qname, d.isMixin ? DocumentSymbol.interfaceKind :
      (d.isEnum ? DocumentSymbol.enumKind : DocumentSymbol.classKind), d.signature,
      d.doc?.text, null, supers)
    typeOccurrence(d.base)
    d.mixins.each |t| { typeOccurrence(t) }
  }

  override Void exitTypeDef(TypeDef d) { curType = null }

  override Void enterFieldDef(FieldDef d)
  {
    curSlot = d
    if (!declaring || synthetic(d.qname, d.isSynthetic)) return
    declare(d.loc, d.name, d.qname, DocumentSymbol.fieldKind, d.signature,
      d.doc?.text, d.parent.qname)
    typeOccurrence(d.type)
  }

  override Void exitFieldDef(FieldDef d) { curSlot = null }

  override Void enterMethodDef(MethodDef d)
  {
    curSlot = d
    if (!declaring) return
    if (!synthetic(d.qname, d.isSynthetic))
    {
      declare(d.loc, d.name, d.qname,
        d.isCtor ? DocumentSymbol.constructor : DocumentSymbol.methodKind,
        d.signature, d.doc?.text, d.parent.qname)
      if (!d.isCtor) typeOccurrence(d.returns)
    }
    closure := d.parentDef.closure
    // Only doCall contains source closure parameters; adapters/ctors do not.
    sourceParams := (!d.isSynthetic && !d.isFieldSetter) || (closure != null && closure.doCall === d)
    if (!sourceParams) return
    d.vars.each |v|
    {
      if (v.paramDef == null || v.shadows != null) return
      loc := closure == null ? v.paramDef.loc : closure.loc
      r := tokenRange(loc, v.name, true)
      if (closure != null)
      {
        // An implicit it has no source declaration. Never scan into the body
        // looking for an incidental use with the same name.
        r = closure.isItBlock ? null : closureParamRange(closure, v.name)
      }
      if (r == null) return
      bind(v, loc, r)
      typeOccurrence(v.paramDef.type)
    }
  }

  override Void exitMethodDef(MethodDef d) { curSlot = null }

  override Void enterStmt(Stmt stmt)
  {
    stmtOwners.add(initOwner)
    if (curSlot is MethodDef && (((MethodDef)curSlot).isInstanceInit || ((MethodDef)curSlot).isStaticInit) &&
      stmt is ExprStmt)
    {
      expr := ((ExprStmt)stmt).expr
      if (expr is BinaryExpr && expr.id == ExprId.assign)
      {
        lhs := ((BinaryExpr)expr).lhs as FieldExpr
        field := lhs?.field as FieldDef
        // Normalize's field-initializer assignment retains field.loc. A write
        // in an explicit static block is not a declaration initializer.
        if (field != null && !synthetic(field.qname, field.isSynthetic) && sameLoc(lhs.loc, field.loc))
          initOwner = field.qname
      }
    }
    if (!declaring || stmt isnot LocalDefStmt) return
    d := (LocalDefStmt)stmt
    if (d.var == null || d.var.shadows != null) return
    r := tokenRange(d.loc, d.name, true)
    if (r != null) bind(d.var, d.loc, r)
  }

  override Void exitStmt(Stmt stmt) { initOwner = stmtOwners.removeAt(-1) }

  private Void bind(MethodVar v, Loc loc, LspRange r)
  {
    file := fileKey(loc)
    if (file == null) return
    key := SymbolKey.localKey(file, r.start)
    bindings[bindingId(v)] = key
    decls[key] = SymbolDecl(key, file, r, r, DocumentSymbol.variable,
      v.ctype.signature, null, sourceOwner())
    add(file, r, key, OccKind.decl, null, sourceOwner())
  }

  override Expr visitExpr(Expr e)
  {
    if (e is ClosureExpr)
    {
      closure := (ClosureExpr)e
      if (closure.cls != null) closureOwners[closure.cls.qname] = sourceOwner(e.loc)
    }
    if (declaring) return e
    key := null as Str
    alt := null as Str
    name := null as Str
    kind := OccKind.type
    // ResolveExpr folds constant Str.upper/lower calls into LiteralExpr while
    // retaining the method-token loc. Recover only those installed-compiler
    // folds, at that exact dotted member token. InitEnum also emits string
    // literals at enum names; those are declarations, not folded calls.
    if (e is LiteralExpr && e.id == ExprId.strLiteral && e.ctype != null)
    {
      file := fileKey(e.loc)
      folded := file == null ? null : ["upper", "lower"].find |n| { files[file].foldedMember(e.loc, n) }
      if (folded != null)
      { key = "sys::Str.$folded"; name = folded; kind = OccKind.call }
    }
    if (e is CallExpr && e isnot ShortcutExpr)
    {
      call := (CallExpr)e
      m := call.method
      if (m == null || m.qname.contains("\$")) return e
      // Shorthand must begin AT the call's type target, never at a later
      // argument/type token. Explicit Foo.make has call.loc on 'make'.
      spelling := m.isCtor && call.target is StaticTargetExpr && sameLoc(call.loc, call.target.loc) ?
        shorthandSpelling(call.loc, m.parent) : null
      shorthand := spelling != null
      if (m.isSynthetic && !shorthand) return e
      key = m.qname; name = m.name; kind = OccKind.call
      if (shorthand)
      {
        name = spelling
        kind = OccKind.ctorShorthand
        alt = m.parent.qname
        if (!sourceCtor(m)) { key = alt; alt = m.qname }
      }
    }
    else if (e is FieldExpr)
    {
      f := ((FieldExpr)e).field
      if (f == null || synthetic(f.qname, f.isSynthetic)) return e
      key = f.qname; name = f.name; kind = OccKind.field
    }
    else if (e is LocalVarExpr)
    {
      v := ((LocalVarExpr)e).var
      if (v == null) return e
      while (v.shadows != null) v = v.shadows
      key = bindings[bindingId(v)]
      name = v.name; kind = OccKind.local
    }
    else if (e is SlotLiteralExpr)
    {
      s := ((SlotLiteralExpr)e).slot
      if (s == null || synthetic(s.qname, s.isSynthetic)) return e
      key = s.qname; name = s.name; kind = OccKind.slotLiteral
    }
    else if (e is StaticTargetExpr)
    {
      if (e.ctype == null || synthetic(e.ctype.qname, e.ctype.isSynthetic)) return e
      // The constructor owns the same token (including its altKey).
      key = e.ctype.qname; name = e.ctype.name
    }
    if (key == null || name == null) return e
    r := kind == OccKind.type || kind == OccKind.ctorShorthand ? typeTokenRange(e.loc, name) :
      (kind == OccKind.slotLiteral ? slotTokenRange(e.loc, name) : tokenRange(e.loc, name, false))
    file := fileKey(e.loc)
    if (r != null && file != null)
    {
      // Static targets precede construction nodes in the visitor. Remove the
      // redundant type occurrence so resolution selects ctorShorthand.
      if (kind == OccKind.ctorShorthand) removeType(file, r)
      add(file, r, key, kind, alt, sourceOwner(e.loc))
    }
    return e
  }

  ** Source spelling of a shorthand's type target: the simple name (optionally
  ** pod-qualified), or a using alias which the compiler resolved to exactly
  ** this type. Never a later or unrelated token.
  private Str? shorthandSpelling(Loc loc, CType parent)
  {
    if (typeTokenRange(loc, parent.name) != null) return parent.name
    file := fileKey(loc)
    if (file == null || curType == null) return null
    // Closure TypeDefs share their source CompilationUnit (and its usings).
    alias := curType.unit.usings.find |u|
    {
      u.asName != null && u.resolvedType?.qname == parent.qname && files[file].exact(loc, u.asName) != null
    }
    return alias?.asName
  }

  ** A constructor owns shorthand only with a non-synthetic workspace source
  ** declaration. Same pod: its declaration was extracted here. Cross pod: the
  ** dependency was loaded from a workspace pod file (LspNamespace.podFile, the
  ** same workspace test as PodLookup.reflectionType; never JVM reflection),
  ** whose fcode retains DefaultCtor's synthetic flag. The target build need
  ** not be in this snapshot. Installed/reflected pods keep the type key.
  private Bool sourceCtor(CMethod m)
  {
    if (m is MethodDef) return decls[m.qname] != null
    ns := c.ns as LspNamespace
    if (ns == null || ns.podFile(m.parent.pod.name) == null) return false
    return !synthetic(m.qname, m.isSynthetic)
  }

  private Void removeType(Str file, LspRange r)
  {
    old := byFile[file]?.find |o| { o.kind == OccKind.type && sameRange(o.range, r) }
    if (old == null) return
    byFile[file].remove(old)
    byKey[old.key]?.remove(old)
    seen.remove(identity(file, r, old.key))
  }

  private Void typeOccurrence(CType? t)
  {
    if (t == null || typeRef == null || !t.typeof.fits(typeRef)) return
    loc := t.typeof.field("loc").get(t) as Loc
    if (loc == null) return
    r := typeTokenRange(loc, t.name)
    file := fileKey(loc)
    if (r != null && file != null) add(file, r, t.qname, OccKind.type, null, sourceOwner())
  }

  private Void declare(Loc loc, Str name, Str key, Int kind, Str? sig,
    Str? doc, Str? parent, Str[] supers := Str[,])
  {
    file := fileKey(loc)
    r := tokenRange(loc, name, true)
    if (file == null || r == null) return
    full := files[file].fullRange(loc, r)
    decls[key] = SymbolDecl(key, file, r, full, kind, sig, doc, parent, supers)
    add(file, r, key, OccKind.decl, null, sourceOwner())
  }

  private Str? sourceOwner(Loc? loc := null)
  {
    closure := curType?.closure
    if (closure != null)
    {
      if (closureOwners.containsKey(curType.qname)) return closureOwners[curType.qname]
      return canonicalOwner(closure.enclosingSlot, closure.loc)
    }
    if (initOwner != null) return initOwner
    slot := curSlot
    if (slot == null) return null
    return canonicalOwner(slot, loc)
  }

  private Str? canonicalOwner(SlotDef slot, Loc? loc)
  {
    if (slot is MethodDef && ((MethodDef)slot).accessorFor != null)
      return ((MethodDef)slot).accessorFor.qname
    if (!synthetic(slot.qname, slot.isSynthetic)) return slot.qname
    if (slot.name.endsWith("\$Once"))
    {
      original := slot.parentDef.slotDef(slot.name[0..<-5])
      if (original != null && !synthetic(original.qname, original.isSynthetic)) return original.qname
    }
    return null
  }

  private Str? fileKey(Loc loc)
  {
    cached := fileKeys[loc.file]
    if (cached != null) return cached
    key := UriKey.canonical(loc.file)
    if (files.containsKey(key)) { fileKeys[loc.file] = key; return key }
    try
    {
      key = UriKey.canonical(File.os(loc.file).normalize.uri.toStr)
      if (!files.containsKey(key)) return null
      fileKeys[loc.file] = key
      return key
    }
    catch (Err e) { return null }
  }

  private LspRange? tokenRange(Loc loc, Str name, Bool declaration)
  {
    key := fileKey(loc)
    return key == null ? null : (declaration ? files[key].declaration(loc, name) : files[key].exact(loc, name))
  }

  private LspRange? typeTokenRange(Loc loc, Str name)
  {
    key := fileKey(loc)
    return key == null ? null : files[key].typeToken(loc, name)
  }

  private LspRange? slotTokenRange(Loc loc, Str name)
  {
    key := fileKey(loc)
    return key == null ? null : files[key].slotToken(loc, name)
  }

  private static Str bindingId(MethodVar v)
  {
    m := v.method
    return "${m.qname}:${m.loc.file}:${m.loc.line}:${m.loc.col}:${m.isGetter}:${m.isSetter}:${v.register}"
  }
  private static Bool sameLoc(Loc a, Loc b) { a.file == b.file && a.line == b.line && a.col == b.col }

  private LspRange? closureParamRange(ClosureExpr closure, Str name)
  {
    key := fileKey(closure.loc)
    return key == null ? null : files[key].closureParam(closure.loc, name)
  }

  private Void add(Str file, LspRange r, Str key, OccKind kind, Str? alt, Str? owner)
  {
    id := identity(file, r, key)
    if (seen[id] == true) return
    seen[id] = true
    o := Occurrence(file, r, key, kind, alt, owner)
    if (byFile[file] == null) byFile[file] = Occurrence[,]
    if (byKey[key] == null) byKey[key] = Occurrence[,]
    byFile[file].add(o); byKey[key].add(o)
  }

  private static Str identity(Str file, LspRange r, Str key)
  { "$file#${r.start.line}:${r.start.character}:${r.end.character}:$key" }
  private static Bool sameRange(LspRange a, LspRange b)
  { a.start.line == b.start.line && a.start.character == b.start.character && a.end.character == b.end.character }
  private static Bool synthetic(Str key, Bool flag) { flag || key.contains("\$") }
}

** Lexical range table. Interpolation tokens are exact-expression-only;
** declarations never scan string contents. DSL bodies remain opaque.
internal class SemanticTokens
{
  new make(Str text)
  {
    this.text = text
    scanCode(false)
    // One pass indexes lines and balanced braces. Full declaration ranges use
    // the matching closing brace directly rather than rescan entire bodies.
    stack := Int[,]
    tokens.each |t, index|
    {
      if (!lineStart.containsKey(t.line)) lineStart[t.line] = index
      if (t.inString) return
      if (t.text == "{") stack.add(index)
      if (t.text == "}" && !stack.isEmpty) braceEnd[stack.removeAt(-1)] = index
    }
  }
  Str text
  SemanticIndexToken[] tokens := [,]
  private Int:Int lineStart := [:]
  private Int:Int braceEnd := [:]
  private Int cursor := 0
  private Int line := 0
  private Int col := 0

  private Bool at(Str s) { text.size-cursor >= s.size && text[cursor..<cursor+s.size] == s }
  private Void advance(Int count := 1)
  {
    for (n := 0; n < count; n++)
    {
      if (cursor >= text.size) return
      ch := text[cursor++]
      if (ch == '\r') { line++; col = 0 }
      else if (ch == '\n') { if (cursor < 2 || text[cursor-2] != '\r') line++; col = 0 }
      else col++
    }
  }

  private Void token(Bool inString)
  {
    start := cursor; l := line; c := col
    if (text[cursor].isAlpha || text[cursor] == '_')
    { while (cursor < text.size && (text[cursor].isAlphaNum || text[cursor] == '_')) advance }
    else advance
    tokens.add(SemanticIndexToken(text[start..<cursor], l, c, col, inString))
  }

  private Void scanCode(Bool inString)
  {
    depth := 0
    while (cursor < text.size)
    {
      ch := text[cursor]
      if (inString && ch == '}' && depth == 0) { advance; return }
      if (ch.isSpace) { advance; continue }
      if (at("//") || at("**"))
      { while (cursor < text.size && text[cursor] != '\r' && text[cursor] != '\n') advance; continue }
      if (at("/*"))
      {
        advance(2); nesting := 1
        while (cursor < text.size && nesting > 0)
        {
          if (at("/*")) { nesting++; advance(2) }
          else if (at("*/")) { nesting--; advance(2) }
          else advance
        }
        continue
      }
      if (at("<|"))
      {
        advance(2)
        while (cursor < text.size && !at("|>")) advance
        advance(2); continue
      }
      if (ch == '"' || ch == '\'' || ch == '`') { scanString(ch); continue }
      if (ch == '{') depth++
      if (ch == '}') depth--
      token(inString)
    }
  }

  private Void scanString(Int quote)
  {
    triple := quote == '"' && at("\"\"\"")
    delimiter := triple ? "\"\"\"" : quote.toChar
    advance(delimiter.size)
    while (cursor < text.size)
    {
      if (at(delimiter)) { advance(delimiter.size); return }
      if (text[cursor] == '\\') { advance(2); continue }
      if (quote != '\'' && text[cursor] == '$')
      {
        advance
        if (cursor < text.size && text[cursor] == '{') { advance; scanCode(true); continue }
        if (cursor < text.size && (text[cursor].isAlpha || text[cursor] == '_'))
        {
          token(true)
          while (at(".") && cursor+1 < text.size && (text[cursor+1].isAlpha || text[cursor+1] == '_'))
          { token(true); token(true) }
          continue
        }
      }
      advance
    }
  }

  private Int startIndex(Loc loc)
  {
    if (loc.line == null || loc.col == null) return tokens.size
    line := loc.line-1
    for (n := line; n <= line+20; n++)
    {
      index := lineStart[n]
      if (index == null) continue
      while (index < tokens.size && tokens[index].line == line && tokens[index].col < loc.col-1) index++
      return index
    }
    return tokens.size
  }

  LspRange? exact(Loc loc, Str name)
  {
    i := startIndex(loc)
    if (i >= tokens.size) return null
    t := tokens[i]
    return t.line == loc.line-1 && t.col == loc.col-1 && t.text == name ? t.range : null
  }

  LspRange? typeToken(Loc loc, Str name)
  {
    r := exact(loc, name)
    if (r != null) return r
    i := startIndex(loc)
    if (i+3 >= tokens.size) return null
    a := tokens[i]; b := tokens[i+1]; c := tokens[i+2]; d := tokens[i+3]
    if (a.line != loc.line-1 || a.col != loc.col-1 || !a.text[0].isAlpha ||
      b.text != ":" || c.text != ":" || d.text != name || d.line != a.line) return null
    return d.range
  }

  Bool foldedMember(Loc loc, Str name)
  {
    if (exact(loc, name) == null) return false
    i := startIndex(loc)
    if (i == 0) return false
    dot := tokens[i-1]
    member := tokens[i]
    // Require the immediately preceding source token to be a member-access
    // dot in the same lexical context, not an enum/declaration identifier.
    return dot.text == "." && dot.line == member.line && dot.inString == member.inString
  }

  LspRange? slotToken(Loc loc, Str name)
  {
    i := startIndex(loc)
    if (i >= tokens.size || tokens[i].line != loc.line-1 || tokens[i].col != loc.col-1) return null
    // Slot literal loc starts at its type or #; stop at the first # and
    // require the immediately following token, never a later same-name use.
    for (; i < tokens.size && tokens[i].line == loc.line-1; i++)
    {
      t := tokens[i]
      if (t.text == "#") return i+1 < tokens.size && tokens[i+1].text == name ? tokens[i+1].range : null
      if (!(t.text[0].isAlpha || t.text == ":")) return null
    }
    return null
  }

  LspRange? declaration(Loc loc, Str name)
  {
    i := startIndex(loc)
    inFunc := false
    for (; i < tokens.size && tokens[i].line <= (loc.line ?: 1)+19; i++)
    {
      t := tokens[i]
      if (t.inString) continue
      if (t.text == "@")
      {
        // Skip facet type qualification and its entire balanced value block.
        i++
        while (i+1 < tokens.size && (tokens[i+1].text == ":" ||
          (tokens[i].text == ":" && tokens[i+1].text[0].isAlpha))) i++
        if (i+1 < tokens.size && tokens[i+1].text == "{") i = braceEnd[i+1] ?: tokens.size
        continue
      }
      if (t.text == "|") { inFunc = !inFunc; continue }
      if (!inFunc && t.text == name) return t.range
      if (!inFunc && (t.text == "{" || t.text == ";" || t.text == ":=")) return null
    }
    return null
  }

  LspRange? find(Loc loc, Str name, Int extraLines)
  {
    if (loc.line == null || loc.col == null) return null
    line := loc.line - 1; col := loc.col - 1
    for (i := startIndex(loc); i < tokens.size && tokens[i].line <= line+extraLines; i++)
      if (!tokens[i].inString && tokens[i].text == name) return tokens[i].range
    return null
  }

  LspRange? closureParam(Loc loc, Str name)
  {
    if (loc.line == null || loc.col == null) return null
    started := false
    for (i := startIndex(loc); i < tokens.size; i++)
    {
      t := tokens[i]
      if (t.inString) continue
      if (t.line < loc.line-1 || (t.line == loc.line-1 && t.col < loc.col-1)) continue
      if (!started) { if (t.text != "|") return null; started = true; continue }
      if (t.text == "|" || t.text == "{" || t.line > loc.line+19) return null
      if (t.text == name) return t.range
    }
    return null
  }

  LspRange fullRange(Loc loc, LspRange name)
  {
    start := Position((loc.line ?: 1)-1, (loc.col ?: 1)-1)
    end := name.end
    for (i := startIndex(Loc("", name.start.line+1, name.start.character+1)); i < tokens.size; i++)
    {
      t := tokens[i]
      if (t.inString) continue
      if (t.line < name.start.line || (t.line == name.start.line && t.col < name.start.character)) continue
      if (t.line > end.line && t.text != "{") break
      if (t.text == "{")
      {
        close := braceEnd[i]
        return close == null ? LspRange(start, end) : LspRange(start, tokens[close].range.end)
      }
      if (t.text == "}" || t.text == ";") break
      end = t.range.end
    }
    return LspRange(start, end)
  }
}

internal const class SemanticIndexToken
{
  new make(Str text, Int line, Int col, Int endCol, Bool inString := false)
  { this.text = text; this.line = line; this.col = col; this.endCol = endCol; this.inString = inString }
  const Str text
  const Int line
  const Int col
  const Int endCol
  const Bool inString
  LspRange range() { LspRange(Position(line, col), Position(line, endCol)) }
}
