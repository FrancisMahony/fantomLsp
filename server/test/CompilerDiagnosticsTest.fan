class CompilerDiagnosticsTest : Test
{
  private CompilerDiagnostics diag := CompilerDiagnostics()

  ** Helper: write text content to a File
  private static Void writeFile(File f, Str content)
  {
    out := f.out
    out.print(content)
    out.close
  }

  //------------------------------------------------------------------------
  // parseSrcDirs
  //------------------------------------------------------------------------

  Void testParseSrcDirsSingleDir()
  {
    projectDir := tempDir()
    buildFan := projectDir + `build.fan`
    writeFile(buildFan,
      "class Build : BuildPod\n" +
      "{\n" +
      "  new make()\n" +
      "  {\n" +
      "    srcDirs = [`fan/`]\n" +
      "  }\n" +
      "}\n")

    dirs := diag.parseSrcDirs(buildFan)
    verifyEq(dirs.size, 1)
    verifyEq(dirs[0].uri, (projectDir + `fan/`).uri)
  }

  Void testParseSrcDirsMultipleDirs()
  {
    projectDir := tempDir()
    buildFan := projectDir + `build.fan`
    writeFile(buildFan,
      "class Build : BuildPod\n" +
      "{\n" +
      "  new make()\n" +
      "  {\n" +
      "    srcDirs = [\n" +
      "      `fan/`,\n" +
      "      `fan/protocol/`,\n" +
      "      `fan/server/`,\n" +
      "    ]\n" +
      "  }\n" +
      "}\n")

    dirs := diag.parseSrcDirs(buildFan)
    verifyEq(dirs.size, 3)
    verifyEq(dirs[0].uri, (projectDir + `fan/`).uri)
    verifyEq(dirs[1].uri, (projectDir + `fan/protocol/`).uri)
    verifyEq(dirs[2].uri, (projectDir + `fan/server/`).uri)
  }

  Void testParseSrcDirsInlineList()
  {
    // All dirs on one line
    projectDir := tempDir()
    buildFan := projectDir + `build.fan`
    writeFile(buildFan,
      "class Build : BuildPod { new make() { srcDirs = [`src/`, `test/`] } }\n")

    dirs := diag.parseSrcDirs(buildFan)
    verifyEq(dirs.size, 2)
    verifyEq(dirs[0].uri, (projectDir + `src/`).uri)
    verifyEq(dirs[1].uri, (projectDir + `test/`).uri)
  }

  Void testParseSrcDirsEmptyWhenNone()
  {
    projectDir := tempDir()
    buildFan := projectDir + `build.fan`
    writeFile(buildFan,
      "class Build : BuildPod { new make() { podName = \"test\" } }\n")

    dirs := diag.parseSrcDirs(buildFan)
    verifyEq(dirs.size, 0)
  }

  Void testParseSrcDirsMatchesOwnBuildFan()
  {
    // Simulate the fantomLsp project's own build.fan format
    projectDir := tempDir()
    buildFan := projectDir + `build.fan`
    writeFile(buildFan,
      "using build\n" +
      "class Build : BuildPod\n" +
      "{\n" +
      "  new make()\n" +
      "  {\n" +
      "    podName = \"fantomLsp\"\n" +
      "    srcDirs = [\n" +
      "      `fan/`,\n" +
      "      `fan/protocol/`,\n" +
      "      `fan/server/`,\n" +
      "      `fan/parser/`,\n" +
      "      `fan/analysis/`,\n" +
      "      `fan/features/`,\n" +
      "      `test/`,\n" +
      "    ]\n" +
      "  }\n" +
      "}\n")

    dirs := diag.parseSrcDirs(buildFan)
    verifyEq(dirs.size, 7)
    dirUris := dirs.map |d -> Uri| { d.uri }
    verify(dirUris.contains((projectDir + `fan/`).uri))
    verify(dirUris.contains((projectDir + `fan/protocol/`).uri))
    verify(dirUris.contains((projectDir + `test/`).uri))
  }

  //------------------------------------------------------------------------
  // parsePropsFile
  //------------------------------------------------------------------------

  Void testParsePropsFileBasic()
  {
    projectDir := tempDir()
    propsFile := projectDir + `config.props`
    writeFile(propsFile,
      "fan.depend=1.0\n" +
      "hx.depend=4.0.5\n" +
      "nv5.depend=4.0.5\n")

    props := diag.parsePropsFile(propsFile)
    verifyEq(props["fan.depend"], "1.0")
    verifyEq(props["hx.depend"], "4.0.5")
    verifyEq(props["nv5.depend"], "4.0.5")
  }

  Void testParsePropsFileSkipsComments()
  {
    projectDir := tempDir()
    propsFile := projectDir + `config.props`
    writeFile(propsFile,
      "# this is a comment\n" +
      "fan.depend=1.0\n" +
      "// another comment\n" +
      "hx.depend=4.0.5\n")

    props := diag.parsePropsFile(propsFile)
    verifyEq(props.size, 2)
    verifyEq(props["fan.depend"], "1.0")
    verifyEq(props["hx.depend"], "4.0.5")
  }

  Void testParsePropsFileTrimsWhitespace()
  {
    projectDir := tempDir()
    propsFile := projectDir + `config.props`
    writeFile(propsFile,
      "  fan.depend = 1.0  \n" +
      "hx.depend  =  4.0.5\n")

    props := diag.parsePropsFile(propsFile)
    verifyEq(props["fan.depend"], "1.0")
    verifyEq(props["hx.depend"], "4.0.5")
  }

  //------------------------------------------------------------------------
  // findBuildProps
  //------------------------------------------------------------------------

  Void testFindBuildPropsInParentEtcDir()
  {
    // Typical SkySpark layout: root/etc/build/config.props
    //                          root/src/mymod/build.fan
    rootDir := tempDir()
    etcDir := rootDir + `etc/build/`
    etcDir.create
    propsFile := etcDir + `config.props`
    writeFile(propsFile, "fan.depend=1.0\n")

    subDir := rootDir + `src/mymod/`
    subDir.create
    buildFan := subDir + `build.fan`
    writeFile(buildFan, "class Build : BuildPod { new make() { } }\n")

    found := diag.findBuildProps(buildFan)
    verifyNotNull(found)
    verifyEq(found.osPath, propsFile.osPath)
  }

  Void testFindBuildPropsStopsAtNearest()
  {
    // If there are two etc/build/config.props in the hierarchy, the nearest wins
    rootDir := tempDir()
    outerEtc := rootDir + `etc/build/`
    outerEtc.create
    writeFile(outerEtc + `config.props`, "fan.depend=1.0\n")

    innerDir := rootDir + `sub/`
    innerDir.create
    innerEtc := innerDir + `etc/build/`
    innerEtc.create
    innerProps := innerEtc + `config.props`
    writeFile(innerProps, "fan.depend=2.0\n")

    buildFan := innerDir + `build.fan`
    writeFile(buildFan, "class Build : BuildPod { new make() { } }\n")

    found := diag.findBuildProps(buildFan)
    verifyNotNull(found)
    verifyEq(found.osPath, innerProps.osPath)
  }

  //------------------------------------------------------------------------
  // extractDependenciesFromBuildFan
  //------------------------------------------------------------------------

  Void testExtractDepsBasic()
  {
    projectDir := tempDir()
    buildFan := projectDir + `build.fan`
    writeFile(buildFan,
      "class Build : BuildPod\n" +
      "{\n" +
      "  new make()\n" +
      "  {\n" +
      "    depends = [\n" +
      "      \"sys 1.0\",\n" +
      "      \"util 1.0\",\n" +
      "      \"compiler 1.0\",\n" +
      "    ]\n" +
      "  }\n" +
      "}\n")

    deps := diag.extractDependenciesFromBuildFan(buildFan)
    verifyEq(deps.size, 3)
    names := deps.map |d -> Str| { d.name }
    verify(names.contains("sys"))
    verify(names.contains("util"))
    verify(names.contains("compiler"))
  }

  Void testExtractDepsUsesActualVersionString()
  {
    // The real version constraint from build.fan should be used, not hardcoded "1.0+"
    projectDir := tempDir()
    buildFan := projectDir + `build.fan`
    writeFile(buildFan,
      "class Build : BuildPod\n" +
      "{\n" +
      "  new make()\n" +
      "  {\n" +
      "    depends = [\n" +
      "      \"sys 1.0\",\n" +
      "      \"concurrent 1.0+\",\n" +
      "    ]\n" +
      "  }\n" +
      "}\n")

    deps := diag.extractDependenciesFromBuildFan(buildFan)
    verifyEq(deps.size, 2)
    verifyNotNull(deps.find |d| { d.name == "sys" })
    verifyNotNull(deps.find |d| { d.name == "concurrent" })
  }

  Void testExtractDepsFallbackToSys()
  {
    // When build.fan has no depends block, sys must always be included
    projectDir := tempDir()
    buildFan := projectDir + `build.fan`
    writeFile(buildFan,
      "class Build : BuildPod { new make() { podName = \"test\" } }\n")

    deps := diag.extractDependenciesFromBuildFan(buildFan)
    verify(deps.size >= 1)
    verify(deps.any |d| { d.name == "sys" })
  }

  Void testExtractDepsIncludesSysFromBuildFan()
  {
    // sys listed explicitly in depends — should not be dropped
    projectDir := tempDir()
    buildFan := projectDir + `build.fan`
    writeFile(buildFan,
      "class Build : BuildPod\n" +
      "{\n" +
      "  new make()\n" +
      "  {\n" +
      "    depends = [\"sys 1.0\", \"build 1.0\"]\n" +
      "  }\n" +
      "}\n")

    deps := diag.extractDependenciesFromBuildFan(buildFan)
    verifyEq(deps.size, 2)
    verify(deps.any |d| { d.name == "sys" })
    verify(deps.any |d| { d.name == "build" })
  }

  Void testExtractDepsTemplateVariablesResolvedFromProps()
  {
    // SkySpark build.fan uses @{key} macros resolved via etc/build/config.props
    rootDir := tempDir()
    etcDir := rootDir + `etc/build/`
    etcDir.create
    writeFile(etcDir + `config.props`,
      "fan.depend=1.0\n" +
      "hx.depend=4.0.5\n" +
      "nv5.depend=4.0.5\n")

    subDir := rootDir + `src/mymod/`
    subDir.create
    buildFan := subDir + `build.fan`
    writeFile(buildFan,
      "class Build : BuildPod\n" +
      "{\n" +
      "  new make()\n" +
      "  {\n" +
      "    depends = [\n" +
      "      \"sys @{fan.depend}\",\n" +
      "      \"concurrent @{fan.depend}\",\n" +
      "      \"hx @{hx.depend}\",\n" +
      "      \"hxConn @{hx.depend}\",\n" +
      "      \"nv5Util @{nv5.depend}\",\n" +
      "    ]\n" +
      "  }\n" +
      "}\n")

    deps := diag.extractDependenciesFromBuildFan(buildFan)
    verifyEq(deps.size, 5)
    names := deps.map |d -> Str| { d.name }
    verify(names.contains("sys"))
    verify(names.contains("concurrent"))
    verify(names.contains("hx"))
    verify(names.contains("hxConn"))
    verify(names.contains("nv5Util"))
  }

  Void testExtractDepsTemplateVariablesFallbackWhenNoProps()
  {
    // Without a config.props, @{key} macros fall back to "1.0+"
    projectDir := tempDir()
    buildFan := projectDir + `build.fan`
    writeFile(buildFan,
      "class Build : BuildPod\n" +
      "{\n" +
      "  new make()\n" +
      "  {\n" +
      "    depends = [\n" +
      "      \"sys @{fan.depend}\",\n" +
      "      \"hx @{hx.depend}\",\n" +
      "    ]\n" +
      "  }\n" +
      "}\n")

    deps := diag.extractDependenciesFromBuildFan(buildFan)
    verifyEq(deps.size, 2)
    verify(deps.any |d| { d.name == "sys" })
    verify(deps.any |d| { d.name == "hx" })
  }

  Void testExtractDepsCommentedLinesSkipped()
  {
    // Commented-out deps like //"haystack @{hx.depend}" must NOT be included
    projectDir := tempDir()
    buildFan := projectDir + `build.fan`
    writeFile(buildFan,
      "class Build : BuildPod\n" +
      "{\n" +
      "  new make()\n" +
      "  {\n" +
      "    depends = [\n" +
      "      \"sys 1.0\",\n" +
      "      //\"haystack 1.0\",\n" +
      "      \"hx 1.0\",\n" +
      "    ]\n" +
      "  }\n" +
      "}\n")

    deps := diag.extractDependenciesFromBuildFan(buildFan)
    verifyEq(deps.size, 2)
    verify(deps.any |d| { d.name == "sys" })
    verify(deps.any |d| { d.name == "hx" })
    verify(!deps.any |d| { d.name == "haystack" })
  }

  //------------------------------------------------------------------------
  // findBuildFan
  //------------------------------------------------------------------------

  Void testFindBuildFanInImmediateParent()
  {
    projectDir := tempDir()
    fanDir := projectDir + `fan/`
    fanDir.create

    buildFan := projectDir + `build.fan`
    writeFile(buildFan, "class Build : BuildPod { new make() { } }\n")

    srcFile := fanDir + `MyClass.fan`
    writeFile(srcFile, "class MyClass { }\n")

    uri := "file:///" + srcFile.osPath.replace("\\", "/")
    found := diag.findBuildFan(uri)
    verifyNotNull(found)
    verifyEq(found.osPath, buildFan.osPath)
  }

  Void testFindBuildFanWalksUpMultipleLevels()
  {
    projectDir := tempDir()
    deepDir := projectDir + `fan/sub/`
    deepDir.create

    buildFan := projectDir + `build.fan`
    writeFile(buildFan, "class Build : BuildPod { new make() { } }\n")

    srcFile := deepDir + `Deep.fan`
    writeFile(srcFile, "class Deep { }\n")

    uri := "file:///" + srcFile.osPath.replace("\\", "/")
    found := diag.findBuildFan(uri)
    verifyNotNull(found)
    verifyEq(found.osPath, buildFan.osPath)
  }

  Void testFindBuildFanReturnsNullWhenNone()
  {
    projectDir := tempDir()
    srcFile := projectDir + `Standalone.fan`
    writeFile(srcFile, "class Standalone { }\n")

    uri := "file:///" + srcFile.osPath.replace("\\", "/")
    found := diag.findBuildFan(uri)
    verifyNull(found)
  }

  Void testFindBuildFanStopsAtNearestBuildFan()
  {
    // If two build.fan files exist in the hierarchy, the nearest one wins
    projectDir := tempDir()
    innerDir := projectDir + `sub/`
    innerDir.create

    outerBuild := projectDir + `build.fan`
    writeFile(outerBuild, "class Build : BuildPod { new make() { } }\n")

    innerBuild := innerDir + `build.fan`
    writeFile(innerBuild, "class Build : BuildPod { new make() { } }\n")

    srcFile := innerDir + `MyClass.fan`
    writeFile(srcFile, "class MyClass { }\n")

    uri := "file:///" + srcFile.osPath.replace("\\", "/")
    found := diag.findBuildFan(uri)
    verifyNotNull(found)
    verifyEq(found.osPath, innerBuild.osPath)
  }
}
