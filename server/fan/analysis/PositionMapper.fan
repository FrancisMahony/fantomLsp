** Maps positions only on unchanged prefix/suffix lines of two text versions.
** CRLF and LF are equivalent; character offsets are preserved, not remapped.
const class PositionMapper
{
  private const Int oldLineCount
  private const Int newLineCount
  private const Int prefixCount
  private const Int suffixCount

  new make(Str oldText, Str newText)
  {
    // Keep empty lines, including the final line after a trailing newline.
    oldLines := oldText.replace("\r\n", "\n").split('\n', false)
    newLines := newText.replace("\r\n", "\n").split('\n', false)
    oldLineCount = oldLines.size
    newLineCount = newLines.size
    prefix := 0
    while (prefix < oldLines.size && prefix < newLines.size &&
           oldLines[prefix] == newLines[prefix])
      prefix++
    suffix := 0
    // Prefix and suffix must not overlap, even when lines repeat.
    while (suffix < oldLines.size - prefix && suffix < newLines.size - prefix &&
           oldLines[oldLines.size-1-suffix] == newLines[newLines.size-1-suffix])
      suffix++
    prefixCount = prefix
    suffixCount = suffix
  }

  ** Map a compiled-text position to the current text, or null if its line changed.
  Position? toNew(Position pos)
  {
    map(pos, oldLineCount, newLineCount)
  }

  ** Inverse of toNew on unchanged lines.
  Position? toOld(Position pos)
  {
    map(pos, newLineCount, oldLineCount)
  }

  ** Identifier ranges must have both endpoints on the same unchanged line.
  LspRange? rangeToNew(LspRange range)
  {
    start := toNew(range.start)
    end := toNew(range.end)
    if (start == null || end == null || start.line != end.line) return null
    return LspRange(start, end)
  }

  private Position? map(Position pos, Int fromCount, Int toCount)
  {
    if (pos.line < 0 || pos.line >= fromCount || pos.character < 0) return null
    if (pos.line < prefixCount) return pos
    if (pos.line >= fromCount - suffixCount)
      return Position(pos.line + toCount - fromCount, pos.character)
    return null
  }
}
