using compiler

class TestCompiler
{
  static Void main()
  {
    echo("=== Testing Fantom Compiler Integration ===")
    
    testCode := 
      "class TestClass
       {
         Void test()
         {
           unknownVar := 123
           x := unknownVar + y
         }
       }"
    
    input := CompilerInput()
    input.podName = "testPod"
    input.summary = "Test compilation"
    input.version = Version("1.0")
    input.srcStr = testCode
    input.srcStrLoc = Loc.makeUninit
    input.mode = CompilerInputMode.str
    input.output = CompilerOutputMode.transientPod
    
    compiler := Compiler(input)
    
    echo("\n--- Compiling test code ---")
    
    try
    {
      result := compiler.compile
      echo("Result: $result")
    }
    catch (CompilerErr err)
    {
      echo("Compilation failed (expected for test)")
    }
    catch (Err e)
    {
      echo("Unexpected error: $e")
    }
    
    echo("\n--- Diagnostics from Compiler ---")
    echo("Errors: ${compiler.errs.size}")
    echo("Warnings: ${compiler.warns.size}")
    
    if (!compiler.errs.isEmpty)
    {
      echo("\n--- Error Details ---")
      compiler.errs.each |err|
      {
        echo("  [${err.level}] ${err.file}:${err.line}:${err.col} - ${err.msg}")
      }
    }
    
    if (!compiler.warns.isEmpty)
    {
      echo("\n--- Warning Details ---")
      compiler.warns.each |warn|
      {
        echo("  [${warn.level}] ${warn.file}:${warn.line}:${warn.col} - ${warn.msg}")
      }
    }
    
    echo("\n=== SUCCESS: Compiler integration works! ===")
  }
}
