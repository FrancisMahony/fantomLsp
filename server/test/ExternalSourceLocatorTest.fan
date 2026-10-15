class ExternalSourceLocatorTest : Test
{
  private File? root

  override Void setup() { root = tempDir }
  override Void teardown() { root?.delete }

  Void testApiDocLocations()
  {
    doc := "== Str\nloc=Str.fan:20/12\n\nDocumentation\n\n-- size(\n) sys::Int\nloc=45\n\n-- other sys::Int\nloc=99/90\n"
    type := ExternalSourceLocator.parseApiDoc(doc, "Str")
    verifyNotNull(type)
    verifyEq(type.file, "Str.fan")
    verifyEq(type.line, 20)
    verifyEq(ExternalSourceLocator.parseApiDoc(doc, "Str", "size").line, 45)
    verifyEq(ExternalSourceLocator.parseApiDoc(doc.replace("loc=45", "loc=:45/42"), "Str", "size").line, 45)
    verifyNull(ExternalSourceLocator.parseApiDoc(doc, "Str", "absent"))
    verifyNull(ExternalSourceLocator.parseApiDoc(doc, "Missing"))
    verifyNull(ExternalSourceLocator.parseApiDoc(doc.replace("Str.fan:20", "../Str.fan:20"), "Str"))
    verifyNull(ExternalSourceLocator.parseApiDoc(doc.replace("loc=45", "loc=0"), "Str", "size"))
    verifyNull(ExternalSourceLocator.parseApiDoc(doc + "== Other\nloc=Other.fan:1\n\n-- missing sys::Int\nloc=2\n", "Str", "missing"))
  }

  Void testSyntheticPodZip()
  {
    src := "// Widget run\n\nclass Widget\n{\n  // run\n  // more\n  Void run() {}\n}\n"
    pod := archive("widget", ["src/Widget.fan": src,
      "doc/Widget.apidoc": "== Widget\nloc=Widget.fan:3\n\n-- run(\n) sys::Void\nloc=7\n"])
    locator := locatorFor(pod)
    loc := locator.locateInstalled("widget::Widget.run")
    verifyNotNull(loc)
    file := (File)loc[0]
    verifyEq(file, root + `cache/widget-1.2/Widget.fan`)
    verifyEq(file.readAllStr, src)
    verifyRange((LspRange)loc[1], 6, 7, 10)
    verifyRange((LspRange)locator.locateInstalled("widget::Widget")[1], 2, 6, 12)
    modified := file.modified
    verifyNotNull(locator.locateInstalled("widget::Widget.run"))
    verifyEq(file.modified, modified)
    verifyNull(locator.locateInstalled("widget::Widget.missing"))
    verifyNull(locator.locateInstalled("other::Widget.run"))
  }

  Void testIdentifierMaskAndBound()
  {
    text := "/* opened earlier\n run /* nested */\n*/\n" +
      "** run doc\n// run\n\"run\" 'r' `run` runLong longer_run\n" +
      "\"\"\"run\nrun\"\"\"\n  Void run() {}"
    verifyRange(ExternalSourceLocator.identifierRange(text, "run", 1), 8, 7, 10)
    verifyNull(ExternalSourceLocator.identifierRange("runLong longer_run", "run", 0))
    verifyNull(ExternalSourceLocator.identifierRange("run\nother", "run", 1))
    verifyNull(ExternalSourceLocator.identifierRange("run", "run", -1))
    inside := StrBuf()
    19.times { inside.add("// run\n") }
    inside.add("run")
    verifyRange(ExternalSourceLocator.identifierRange(inside.toStr, "run", 0), 19, 0, 3)
    verifyNull(ExternalSourceLocator.identifierRange("// run\n" + inside.toStr, "run", 0))
    verifyRange(ExternalSourceLocator.identifierRange("\"escaped \\\" run\" run", "run", 0), 0, 17, 20)
    verifyRange(ExternalSourceLocator.identifierRange("Widget Widget", "Widget", 0, 7), 0, 7, 13)
  }

  Void testSourceLookupOrder()
  {
    doc := "== Widget\nloc=Widget.fan:1\n\n-- run(\n) sys::Void\nloc=3\n"
    packed := "class Widget\n{\n  Void run() {}\n}\n"
    homeSrc := root + `home/src/widget/deep/Widget.fan`
    envSrc := root + `env/src/widget/fan/Widget.fan`
    write(homeSrc, "class Widget\n{\n    Void run() {}\n}\n")
    write(envSrc, "class Widget\n{\n      Void run() {}\n}\n")
    pod := archive("widget", ["doc/Widget.apidoc": doc, "src/Widget.fan": packed])
    verifyRange((LspRange)locatorFor(pod).locateInstalled("widget::Widget.run")[1], 2, 7, 10)
    pod = archive("widget", ["doc/Widget.apidoc": doc])
    verifyEq(locatorFor(pod).locateInstalled("widget::Widget.run")[0], homeSrc)
    homeSrc.delete
    verifyEq(locatorFor(pod).locateInstalled("widget::Widget.run")[0], envSrc)
    envSrc.delete
    verifyNull(locatorFor(pod).locateInstalled("widget::Widget.run"))
  }

  Void testPodRestrictedParserFallback()
  {
    src := "class Other\n{\n  Void run() {}\n}\nclass Widget\n{\n  Void run() {}\n}\n"
    pod := archive("widget", ["src/Declarations.fan": src])
    // An unrelated pod has a tempting same-name declaration, but no widget source.
    write(root + `home/src/other/fan/Widget.fan`, "class Widget\n{\n Void missing() {}\n}")
    loc := locatorFor(pod).locateInstalled("widget::Widget.run")
    verifyNotNull(loc)
    verifyRange((LspRange)loc[1], 6, 7, 10)
    verifyRange((LspRange)locatorFor(pod).locateInstalled("widget::Widget")[1], 4, 6, 12)
    verifyNull(locatorFor(pod).locateInstalled("widget::Widget.missing"))
    verifyNull(locatorFor(pod).locateInstalled("widget::Absent.run"))
    pod = archive("widget", Str:Str[:])
    verifyNull(locatorFor(pod).locateInstalled("widget::Widget.missing"))
    write(root + `home/src/widget/fan/Widget.fan`, "class Widget\n{\n Void run() {}\n}")
    verifyNotNull(locatorFor(pod).locateInstalled("widget::Widget.run"))
    write(root + `home/src/widget/second/Duplicate.fan`, "class Widget\n{\n Void run() {}\n}")
    verifyNull(locatorFor(pod).locateInstalled("widget::Widget.run"))
  }

  Void testFallbackKeepsDistinctEnvFilesWithSameBasename()
  {
    pod := archive("widget", Str:Str[:])
    src := "class Widget\n{\n  Void run() {}\n}\n"
    a := root + `env/src/widget/a/Widget.fan`
    b := root + `env/src/widget/b/Widget.fan`
    write(a, src)
    verifyNotNull(locatorFor(pod).locateInstalled("widget::Widget.run"))
    write(b, src)
    verifyNull(locatorFor(pod).locateInstalled("widget::Widget.run"))
    verifyNull(locatorFor(pod).locateInstalled("widget::Widget"))
  }

  Void testFallbackDeduplicatesPhysicalFileAcrossRoots()
  {
    pod := archive("widget", Str:Str[:])
    homeSrc := root + `home/src/widget/a/Widget.fan`
    write(homeSrc, "class Widget\n{\n  Void run() {}\n}\n")
    // Env lookup may return the home source root using a different path form.
    locator := ExternalSourceLocator(|Str name->File?| { pod },
      root + `cache/`, root + `home/`, |Uri uri->File?|
      {
        return root + `home/src/widget/../widget/`
      })
    loc := locator.locateInstalled("widget::Widget.run")
    verifyNotNull(loc)
    verifyEq(loc[0], homeSrc)
    verifyRange((LspRange)loc[1], 2, 7, 10)
  }

  Void testFallbackKeepsDistinctHomeAndEnvFiles()
  {
    pod := archive("widget", Str:Str[:])
    src := "class Widget\n{\n  Void run() {}\n}\n"
    write(root + `home/src/widget/a/Widget.fan`, src)
    write(root + `env/src/widget/b/Widget.fan`, src)
    verifyNull(locatorFor(pod).locateInstalled("widget::Widget.run"))
  }

  Void testFallbackArchiveSourcePrecedence()
  {
    src := "class Widget\n{\n  Void run() {}\n}\n"
    pod := archive("widget", ["src/Widget.fan": src])
    write(root + `home/src/widget/a/Widget.fan`, src)
    write(root + `env/src/widget/b/Widget.fan`, src)
    loc := locatorFor(pod).locateInstalled("widget::Widget.run")
    verifyNotNull(loc)
    verifyEq(loc[0], root + `cache/widget-1.2/Widget.fan`)
  }

  Void testUnknownAndInstalledMissingSource()
  {
    verifyNull(ExternalSourceLocator().locateInstalled("fantomLspMissingPodT07a::Widget.run"))
    // This installation has apidoc but neither embedded sys source nor a src tree.
    verifyNull(ExternalSourceLocator().locateInstalled("sys::Str.size"))
    ["", "Widget", "dyn:run", "local:file:///a.fan#1:2", "../bad::Widget.run"].each |key|
    {
      verifyNull(ExternalSourceLocator().locateInstalled(key))
    }
  }

  private ExternalSourceLocator locatorFor(File pod)
  {
    ExternalSourceLocator(|Str name->File?| { name == "widget" ? pod : null },
      root + `cache/`, root + `home/`, |Uri uri->File?|
      {
        f := root + `env/` + uri
        return f.exists ? f : null
      })
  }

  private File archive(Str name, Str:Str entries)
  {
    f := root + Uri.fromStr("${name}.pod")
    zip := Zip.write(f.out)
    try
    {
      all := entries.dup
      all["meta.props"] = "pod.name=${name}\npod.version=1.2\n"
      all.each |text, path|
      {
        out := zip.writeNext(Uri.fromStr(path))
        try { out.print(text) } finally { out.close }
      }
    }
    finally { zip.close }
    return f
  }

  private Void write(File f, Str text)
  {
    f.parent.create
    out := f.out
    try { out.print(text) } finally { out.close }
  }

  private Void verifyRange(LspRange? range, Int line, Int start, Int end)
  {
    verifyNotNull(range)
    verifyEq(range.start.line, line)
    verifyEq(range.start.character, start)
    verifyEq(range.end.line, line)
    verifyEq(range.end.character, end)
  }
}
