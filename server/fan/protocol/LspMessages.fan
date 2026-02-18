const class Position
{
  const Int line
  const Int character
  new make(Int line, Int character) { this.line = line; this.character = character }
  static Position fromMap([Str:Obj?] map)
  {
    Position(((Num)map["line"]).toInt, ((Num)map["character"]).toInt)
  }
  [Str:Obj?] toMap()
  {
    ["line": line, "character": character]
  }
}

const class LspRange
{
  const Position start
  const Position end
  new make(Position start, Position end) { this.start = start; this.end = end }
  static LspRange fromMap([Str:Obj?] map)
  {
    LspRange(Position.fromMap(map["start"]), Position.fromMap(map["end"]))
  }
  [Str:Obj?] toMap()
  {
    ["start": start.toMap, "end": end.toMap]
  }
}

const class Location
{
  const Str uri
  const LspRange range
  new make(Str uri, LspRange range) { this.uri = uri; this.range = range }
  [Str:Obj?] toMap()
  {
    ["uri": uri, "range": range.toMap]
  }
}

const class TextDocumentIdentifier
{
  const Str uri
  new make(Str uri) { this.uri = uri }
  static TextDocumentIdentifier fromMap([Str:Obj?] map)
  {
    TextDocumentIdentifier(map["uri"])
  }
}

const class VersionedTextDocumentIdentifier
{
  const Str uri
  const Int version
  new make(Str uri, Int version) { this.uri = uri; this.version = version }
  static VersionedTextDocumentIdentifier fromMap([Str:Obj?] map)
  {
    VersionedTextDocumentIdentifier(map["uri"], ((Num)map["version"]).toInt)
  }
}

const class TextDocumentItem
{
  const Str uri
  const Str languageId
  const Int version
  const Str text
  new make(Str uri, Str languageId, Int version, Str text)
  {
    this.uri = uri; this.languageId = languageId
    this.version = version; this.text = text
  }
  static TextDocumentItem fromMap([Str:Obj?] map)
  {
    TextDocumentItem(map["uri"], map["languageId"], ((Num)map["version"]).toInt, map["text"])
  }
}

const class TextDocumentContentChangeEvent
{
  const LspRange? range
  const Str text
  new make(LspRange? range, Str text) { this.range = range; this.text = text }
  static TextDocumentContentChangeEvent fromMap([Str:Obj?] map)
  {
    r := map["range"] != null ? LspRange.fromMap(map["range"]) : null
    return TextDocumentContentChangeEvent(r, map["text"])
  }
}

const class TextEdit
{
  const LspRange range
  const Str newText
  new make(LspRange range, Str newText) { this.range = range; this.newText = newText }
  [Str:Obj?] toMap()
  {
    ["range": range.toMap, "newText": newText]
  }
}

const class Diagnostic
{
  const LspRange range
  const Int severity
  const Str message
  const Str? source
  new make(LspRange range, Int severity, Str message, Str? source := null)
  {
    this.range = range; this.severity = severity
    this.message = message; this.source = source
  }
  [Str:Obj?] toMap()
  {
    m := Str:Obj?["range": range.toMap, "severity": severity, "message": message]
    if (source != null) m["source"] = source
    return m
  }

  static const Int error   := 1
  static const Int warning := 2
  static const Int info    := 3
  static const Int hint    := 4
}

const class CompletionItem
{
  const Str label
  const Int kind
  const Str? detail
  const Str? documentation
  const Str? insertText
  const Int? insertTextFormat
  new make(Str label, Int kind, Str? detail := null, Str? documentation := null,
           Str? insertText := null, Int? insertTextFormat := null)
  {
    this.label = label; this.kind = kind; this.detail = detail
    this.documentation = documentation; this.insertText = insertText
    this.insertTextFormat = insertTextFormat
  }
  [Str:Obj?] toMap()
  {
    m := Str:Obj?["label": label, "kind": kind]
    if (detail != null) m["detail"] = detail
    if (documentation != null) m["documentation"] = ["kind": "markdown", "value": documentation]
    if (insertText != null) m["insertText"] = insertText
    if (insertTextFormat != null) m["insertTextFormat"] = insertTextFormat
    return m
  }

  static const Int text          := 1
  static const Int method        := 2
  static const Int function      := 3
  static const Int constructor   := 4
  static const Int field         := 5
  static const Int variable      := 6
  static const Int classKind     := 7
  static const Int interfaceKind := 8
  static const Int module        := 9
  static const Int property      := 10
  static const Int keyword       := 14
  static const Int snippet       := 15
  static const Int enumMember    := 20
  static const Int constant      := 21
}

const class DocumentSymbol
{
  const Str name
  const Int kind
  const LspRange range
  const LspRange selectionRange
  const Str? detail
  const DocumentSymbol[] children
  new make(Str name, Int kind, LspRange range, LspRange selectionRange,
           Str? detail := null, DocumentSymbol[] children := DocumentSymbol[,])
  {
    this.name = name; this.kind = kind; this.range = range
    this.selectionRange = selectionRange; this.detail = detail
    this.children = children
  }
  [Str:Obj?] toMap()
  {
    m := Str:Obj?[
      "name": name, "kind": kind,
      "range": range.toMap, "selectionRange": selectionRange.toMap,
    ]
    if (detail != null) m["detail"] = detail
    if (!children.isEmpty) m["children"] = children.map |c| { c.toMap }
    return m
  }

  static const Int file        := 1
  static const Int module      := 2
  static const Int namespace   := 3
  static const Int classKind   := 5
  static const Int methodKind  := 6
  static const Int property    := 7
  static const Int fieldKind   := 8
  static const Int constructor := 9
  static const Int enumKind    := 10
  static const Int interfaceKind := 11
  static const Int variable    := 13
  static const Int constant    := 14
  static const Int enumMember  := 22
}

const class ParameterInformation
{
  const Str label
  const Str? documentation
  new make(Str label, Str? documentation := null)
  {
    this.label = label; this.documentation = documentation
  }
  [Str:Obj?] toMap()
  {
    m := Str:Obj?["label": label]
    if (documentation != null) m["documentation"] = documentation
    return m
  }
}

const class SignatureInformation
{
  const Str label
  const Str? documentation
  const ParameterInformation[] parameters
  new make(Str label, Str? documentation := null, ParameterInformation[] parameters := ParameterInformation[,])
  {
    this.label = label; this.documentation = documentation; this.parameters = parameters
  }
  [Str:Obj?] toMap()
  {
    m := Str:Obj?["label": label, "parameters": parameters.map |p| { p.toMap }]
    if (documentation != null) m["documentation"] = ["kind": "markdown", "value": documentation]
    return m
  }
}

const class WorkspaceEdit
{
  const [Str:TextEdit[]] changes
  new make([Str:TextEdit[]] changes) { this.changes = changes }
  [Str:Obj?] toMap()
  {
    m := Str:Obj?[:]
    changes.each |edits, uri|
    {
      m[uri] = edits.map |e| { e.toMap }
    }
    return ["changes": m]
  }
}
