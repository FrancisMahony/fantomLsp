using build

class DocumentSymbolTest : Test
{
  Void testGetDocumentSymbols()
  {
    src := """class Person
               {
                 Str name
                 Int age
                 Void greet() { echo("Hello") }
               }"""
    
    parser := RecoveringParser()
    result := parser.parse("file:///test.fan", src)
    
    symbolTable := SymbolTable()
    symbolTable.update("file:///test.fan", result)
    
    symbols := symbolTable.getDocumentSymbols("file:///test.fan")
    
    verifyEq(symbols.size, 1)
    verifyEq(symbols[0].name, "Person")
    verifyEq(symbols[0].kind, DocumentSymbol.classKind)
    verifyEq(symbols[0].children.size, 3)
  }

  Void testDocumentSymbolsWithFieldsAndMethods()
  {
    src := "class Calculator\n{\n  Int result\n  Int add(Int a, Int b) { a + b }\n  Int subtract(Int a, Int b) { a - b }\n}"

    parser := RecoveringParser()
    result := parser.parse("file:///calc.fan", src)

    symbolTable := SymbolTable()
    symbolTable.update("file:///calc.fan", result)

    symbols := symbolTable.getDocumentSymbols("file:///calc.fan")

    verifyEq(symbols.size, 1)
    calc := symbols[0]
    verifyEq(calc.name, "Calculator")
    verifyEq(calc.children.size, 3)

    verifyEq(calc.children[0].name, "result")
    verifyEq(calc.children[0].kind, DocumentSymbol.fieldKind)

    verifyEq(calc.children[1].name, "add")
    verifyEq(calc.children[1].kind, DocumentSymbol.methodKind)

    verifyEq(calc.children[2].name, "subtract")
    verifyEq(calc.children[2].kind, DocumentSymbol.methodKind)
  }

  Void testDocumentSymbolsMultipleClasses()
  {
    src := "class Foo\n{\n  Str name\n}\nclass Bar\n{\n  Int count\n}"

    parser := RecoveringParser()
    result := parser.parse("file:///multi.fan", src)

    symbolTable := SymbolTable()
    symbolTable.update("file:///multi.fan", result)

    symbols := symbolTable.getDocumentSymbols("file:///multi.fan")

    verifyEq(symbols.size, 2)
    verifyEq(symbols[0].name, "Foo")
    verifyEq(symbols[1].name, "Bar")
  }

  Void testDocumentSymbolsMixin()
  {
    src := """mixin Flyable
               {
                 Void fly()
               }"""
    
    parser := RecoveringParser()
    result := parser.parse("file:///mixin.fan", src)
    
    symbolTable := SymbolTable()
    symbolTable.update("file:///mixin.fan", result)
    
    symbols := symbolTable.getDocumentSymbols("file:///mixin.fan")
    
    verifyEq(symbols.size, 1)
    verifyEq(symbols[0].name, "Flyable")
    verifyEq(symbols[0].kind, DocumentSymbol.interfaceKind)
    verifyEq(symbols[0].children.size, 1)
    verifyEq(symbols[0].children[0].name, "fly")
  }

  Void testDocumentSymbolsEnum()
  {
    src := "enum class Color\n{\n  red, green, blue\n}"

    parser := RecoveringParser()
    result := parser.parse("file:///enum.fan", src)

    symbolTable := SymbolTable()
    symbolTable.update("file:///enum.fan", result)

    symbols := symbolTable.getDocumentSymbols("file:///enum.fan")

    verifyEq(symbols.size, 1)
    verifyEq(symbols[0].name, "Color")
    verifyEq(symbols[0].kind, DocumentSymbol.enumKind)
  }

  Void testDocumentSymbolsEmptyFile()
  {
    src := ""
    
    parser := RecoveringParser()
    result := parser.parse("file:///empty.fan", src)
    
    symbolTable := SymbolTable()
    symbolTable.update("file:///empty.fan", result)
    
    symbols := symbolTable.getDocumentSymbols("file:///empty.fan")
    
    verifyEq(symbols.size, 0)
  }
}
