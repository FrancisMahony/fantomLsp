**
** RenameProvider - Symbol Rename Feature
**
** CURRENT STATUS: INCOMPLETE - CRITICAL BUG
**
** KNOWN LIMITATIONS:
** 1. Type references inside method bodies are NOT tracked
**    - The RecoveringParser skips all code inside methods (braceDepth > 1)
**    - Only class definitions and type references in fields/parameters are renamed
**
** 2. Variable references are NOT supported
**    - Local variables, parameters are not tracked at all
**    - Only types (classes, mixins, enums) and their slots (fields, methods) are tracked
**
** EXAMPLE OF BROKEN BEHAVIOR:
**   class Example {
**     static Void main() {
**       user := User("test")    // Line 3: User NOT renamed (inside method)
**     }
**   }
**   class User { }               // Line 6: User IS renamed (class def)
**
**   When renaming "User" on line 3:
**   - ✓ Line 6 changes: class User -> class NewName
**   - ✗ Line 3 DOES NOT change: User(...) stays as User(...)
**
** ROOT CAUSE:
**   ReferenceIndex only tracks type references from:
**   - Field declarations: User myField
**   - Method parameters: make(User param)
**   - Method return types: User getName()
**
**   It does NOT track type usages inside method bodies because RecoveringParser.fan
**   lines 187-191 skip all lines when braceDepth > 1 (inside method bodies).
**
** TO FIX:
**   The parser must scan method body lines and extract type constructor calls
**   (User(...), User.make(...), etc.) and add them to ReferenceIndex.
**
** WHAT WORKS:
**   - Renaming types (classes/mixins) used in field declarations
**   - Renaming types used in method signatures (params, return types)
**   - Renaming fields and methods (slots)
**
** WHAT DOESN'T WORK:
**   - Renaming type usages inside method bodies
**   - Renaming local variables (not tracked)
**   - Renaming parameters (not tracked)
**
class RenameProvider
{
  [Str:Obj?]? prepareRename(DocumentState doc, Position pos)
  {
    word := doc.getWordAt(pos)
    if (word.isEmpty) return null

    line := doc.getLine(pos.line)
    if (line == null) return null

    startCol := pos.character
    endCol := pos.character

    while (startCol > 0 && isIdentChar(line[startCol - 1])) startCol--
    while (endCol < line.size && isIdentChar(line[endCol])) endCol++

    range := LspRange(Position(pos.line, startCol), Position(pos.line, endCol))

    return [
      "range": range.toMap,
      "placeholder": word
    ]
  }

  WorkspaceEdit? rename(DocumentState doc, Position pos, Str newName, SymbolTable symbolTable, ReferenceIndex referenceIndex)
  {
    word := doc.getWordAt(pos)
    if (word.isEmpty) return null

    changes := Str:TextEdit[][:]

    entries := symbolTable.findAllByName(word)
    entries.each |e|
    {
      uri := e.uri
      if (changes[uri] == null) changes[uri] = TextEdit[,]
      changes[uri].add(TextEdit(e.node.selectionRange, newName))
    }

    refs := referenceIndex.findReferences(word)
    refs.each |r|
    {
      uri := r.uri
      if (changes[uri] == null) changes[uri] = TextEdit[,]
      changes[uri].add(TextEdit(r.range, newName))
    }

    if (changes.isEmpty) return null
    return WorkspaceEdit(changes)
  }

  private static Bool isIdentChar(Int ch)
  {
    ch.isAlphaNum || ch == '_'
  }
}
