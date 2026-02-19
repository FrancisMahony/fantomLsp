using build

class RenameProviderTest : Test
{
  Void testRenameField()
  {
    code := "class Foo\n{\n  Str name\n  Void test() { echo(name) }\n}"
    doc := DocumentState("file:///test.fan", 1, code)
    
    symbolTable := SymbolTable()
    parseResult := RecoveringParser().parse("file:///test.fan", code)
    symbolTable.update("file:///test.fan", parseResult)
    
    referenceIndex := ReferenceIndex()
    referenceIndex.update("file:///test.fan", parseResult)
    
    provider := RenameProvider()
    pos := Position(2, 7)
    edit := provider.rename(doc, pos, "fullName", symbolTable, referenceIndex)
    
    verifyNotNull(edit)
    verify(edit.changes.size > 0)
  }

  Void testRenameMethod()
  {
    code := "class Foo\n{\n  Void run() { }\n  Void test() { run() }\n}"
    doc := DocumentState("file:///test.fan", 1, code)
    
    symbolTable := SymbolTable()
    parseResult := RecoveringParser().parse("file:///test.fan", code)
    symbolTable.update("file:///test.fan", parseResult)
    
    referenceIndex := ReferenceIndex()
    referenceIndex.update("file:///test.fan", parseResult)
    
    provider := RenameProvider()
    pos := Position(2, 7)
    edit := provider.rename(doc, pos, "execute", symbolTable, referenceIndex)
    
    verifyNotNull(edit)
    verify(edit.changes.size > 0)
  }

  Void testRenameType()
  {
    code := "class Foo\n{\n  Str name\n}"
    doc := DocumentState("file:///test.fan", 1, code)
    
    symbolTable := SymbolTable()
    parseResult := RecoveringParser().parse("file:///test.fan", code)
    symbolTable.update("file:///test.fan", parseResult)
    
    referenceIndex := ReferenceIndex()
    referenceIndex.update("file:///test.fan", parseResult)
    
    provider := RenameProvider()
    pos := Position(0, 6)
    edit := provider.rename(doc, pos, "Bar", symbolTable, referenceIndex)
    
    verifyNotNull(edit)
    verify(edit.changes.size > 0)
  }

  Void testRenameEmptyWord()
  {
    code := "class Foo { }"
    doc := DocumentState("file:///test.fan", 1, code)
    
    symbolTable := SymbolTable()
    parseResult := RecoveringParser().parse("file:///test.fan", code)
    symbolTable.update("file:///test.fan", parseResult)
    
    referenceIndex := ReferenceIndex()
    
    provider := RenameProvider()
    pos := Position(0, 11)
    edit := provider.rename(doc, pos, "Bar", symbolTable, referenceIndex)
    
    verifyNull(edit)
  }

  Void testRenameWithReferences()
  {
    code := "class Foo\n{\n  Str name\n  Void test() { echo(name) }\n}"
    doc := DocumentState("file:///test.fan", 1, code)
    
    symbolTable := SymbolTable()
    parseResult := RecoveringParser().parse("file:///test.fan", code)
    symbolTable.update("file:///test.fan", parseResult)
    
    referenceIndex := ReferenceIndex()
    referenceIndex.update("file:///test.fan", parseResult)
    
    provider := RenameProvider()
    pos := Position(2, 7)
    edit := provider.rename(doc, pos, "fullName", symbolTable, referenceIndex)
    
    verifyNotNull(edit)
    changes := edit.changes["file:///test.fan"]
    verifyNotNull(changes)
    verify(changes.size >= 1)
  }

  Void testRenameReturnsWorkspaceEdit()
  {
    code := "class Foo\n{\n  Str name\n}"
    doc := DocumentState("file:///test.fan", 1, code)
    
    symbolTable := SymbolTable()
    parseResult := RecoveringParser().parse("file:///test.fan", code)
    symbolTable.update("file:///test.fan", parseResult)
    
    referenceIndex := ReferenceIndex()
    
    provider := RenameProvider()
    pos := Position(2, 7)
    edit := provider.rename(doc, pos, "fullName", symbolTable, referenceIndex)
    
    verifyNotNull(edit)
    verifyType(edit, WorkspaceEdit#)
  }
}
