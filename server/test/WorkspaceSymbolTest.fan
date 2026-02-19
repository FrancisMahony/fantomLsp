using build

class WorkspaceSymbolTest : Test
{
  Void testSearchByClassName()
  {
    src := """class Calculator
               {
                 Int add(Int a, Int b) { return a + b }
               }"""
    
    parser := RecoveringParser()
    result := parser.parse("file:///calc.fan", src)
    
    symbolTable := SymbolTable()
    symbolTable.update("file:///calc.fan", result)
    
    provider := WorkspaceSymbolProvider()
    results := provider.search("Calc", symbolTable) as List
    
    verify(results.size > 0)
    firstResult := results[0] as [Str:Obj?]
    verifyEq(firstResult["name"], "Calculator")
    verifyEq(firstResult["kind"], DocumentSymbol.classKind)
  }

  Void testSearchByMethodName()
  {
    src := """class Math
               {
                 Int multiply(Int x, Int y) { return x * y }
                 Int divide(Int x, Int y) { return x / y }
               }"""
    
    parser := RecoveringParser()
    result := parser.parse("file:///math.fan", src)
    
    symbolTable := SymbolTable()
    symbolTable.update("file:///math.fan", result)
    
    provider := WorkspaceSymbolProvider()
    results := provider.search("multiply", symbolTable) as List
    
    verify(results.size > 0)
    found := results.any |r| { (r as [Str:Obj?])["name"] == "multiply" }
    verify(found)
  }

  Void testSearchMultipleFiles()
  {
    src1 := """class Person { Str name }"""
    src2 := """class Product { Str name }"""
    
    parser := RecoveringParser()
    result1 := parser.parse("file:///person.fan", src1)
    result2 := parser.parse("file:///product.fan", src2)
    
    symbolTable := SymbolTable()
    symbolTable.update("file:///person.fan", result1)
    symbolTable.update("file:///product.fan", result2)
    
    provider := WorkspaceSymbolProvider()
    results := provider.search("P", symbolTable) as List
    
    verifyEq(results.size, 2)
  }

  Void testSearchCaseInsensitive()
  {
    src := """class MyService
               {
                 Void doSomething() { }
               }"""
    
    parser := RecoveringParser()
    result := parser.parse("file:///service.fan", src)
    
    symbolTable := SymbolTable()
    symbolTable.update("file:///service.fan", result)
    
    provider := WorkspaceSymbolProvider()
    results := provider.search("myservice", symbolTable) as List
    
    verify(results.size > 0)
  }

  Void testSearchEmptyQuery()
  {
    src := """class Foo { }"""
    
    parser := RecoveringParser()
    result := parser.parse("file:///foo.fan", src)
    
    symbolTable := SymbolTable()
    symbolTable.update("file:///foo.fan", result)
    
    provider := WorkspaceSymbolProvider()
    results := provider.search("", symbolTable) as List
    
    verifyEq(results.size, 0)
  }

  Void testSearchWithLocation()
  {
    src := """class TestClass
               {
                 Str field
               }"""
    
    parser := RecoveringParser()
    result := parser.parse("file:///test.fan", src)
    
    symbolTable := SymbolTable()
    symbolTable.update("file:///test.fan", result)
    
    provider := WorkspaceSymbolProvider()
    results := provider.search("TestClass", symbolTable) as List
    
    verify(results.size > 0)
    firstResult := results[0] as [Str:Obj?]
    verify(firstResult["location"] != null)
    location := firstResult["location"] as [Str:Obj?]
    verifyEq(location["uri"], "file:///test.fan")
  }
}
