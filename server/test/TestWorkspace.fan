using compiler

** Shared multi-pod fixture. Every instance has its own UUID root and pod names.
** All compiler output goes to root/lib/fan; no install and no JVM Pod.load.
** Owners MUST call cleanup from their Test.teardown (also on failing tests).
class TestWorkspace
{
  new make()
  {
    id = Uuid().toStr.replace("-", "")
    root = (Env.cur.tempDir + `fantomLsp-test-${id}/`).create
    libDir = (root + `lib/fan/`).create
    lookup = PodLookup([root])
  }

  const Str id
  const File root
  const File libDir
  PodLookup lookup

  Str podName(Str prefix := "alpha") { prefix + id }

  ** Write a complete source tree; paths are relative to fan/. Dependency
  ** strings use their actual unique pod names, e.g. ws.podName("alpha")+" 1.0".
  File writePod(Str name, Str:Str sources, Str[] depends := ["sys 1.0"])
  {
    dir := (root + `${name}/`).create
    fanDir := (dir + `fan/`).create
    sources.each |text, path|
    {
      file := fanDir + path.toUri
      if (!file.normalize.osPath.startsWith(fanDir.normalize.osPath))
        throw ArgErr("Source path escapes fixture: $path")
      file.parent.create
      file.out.print(text).close
    }
    deps := depends.map |d->Str| { d.toCode }.join(", ")
    (dir + `build.fan`).out.print(
      "using build\nclass Build : BuildPod\n{\n  new make()\n  {\n" +
      "    podName = ${name.toCode}\n    summary = \"LSP test fixture\"\n" +
      "    version = Version(\"1.0\")\n    srcDirs = [`fan/`]\n    depends = [$deps]\n  }\n}\n").close
    return dir
  }

  ** Compile the written tree to a file, never CompilerOutputMode.transientPod.
  ** For a rebuild pass the same unique name and new sources/version.
  File buildPod(Str name, Str:Str sources, Str[] depends := ["sys 1.0"],
                Version version := Version("1.0"))
  {
    dir := writePod(name, sources, depends)
    // Keep the registry-visible build version consistent with the pod metadata.
    build := dir + `build.fan`
    buildText := build.readAllStr.replace("Version(\"1.0\")", "Version(${version.toStr.toCode})")
    build.out.print(buildText).close
    input := CompilerInput()
    input.podName = name
    input.summary = "LSP test fixture"
    input.version = version
    input.baseDir = dir
    input.srcFiles = [`fan/`]
    input.mode = CompilerInputMode.file
    input.output = CompilerOutputMode.podFile
    input.outDir = libDir
    input.depends = depends.map |d->Depend| { Depend(d) }
    input.ns = lookup.freshNamespace
    input.includeDoc = true
    input.includeSrc = true
    input.log = CompilerLog(Buf().out)
    Compiler(input).compile
    return libDir + `${name}.pod`
  }

  LspNamespace namespace() { lookup.freshNamespace }
  Void cleanup() { root.delete }
}
