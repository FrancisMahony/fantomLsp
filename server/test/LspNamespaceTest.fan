using compiler

class LspNamespaceTest : Test
{
  private TestWorkspace? ws
  override Void setup() { ws = TestWorkspace() }
  override Void teardown() { ws?.cleanup }

  Void testRebuildRefreshesNamespaceAndSignaturesWithoutJvmLoad()
  {
    name := ws.podName
    file := ws.buildPod(name, ["A.fan": "** A type doc\nclass A { Str first() { \"one\" } }\n"])
    oldTime := file.modified
    firstNs := ws.lookup.namespace
    first := ws.lookup.findType(name, "A")
    verifyEq(first.pod.version, Version("1.0"))
    verifyNotNull(first.method("first"))
    verifyNull(first.method("added"))
    verifyEq(ws.lookup.typeDoc(first), "A type doc")
    verifyNull(Pod.find(name, false))

    file = ws.buildPod(name, ["A.fan":
      "** New type doc\nclass A { Str first() { \"two\" }\n** Added doc\nInt added(Str value, Int count := 1) { count } }\n"],
      ["sys 1.0"], Version("2.0"))
    // Deterministic mtime change even on coarse-resolution file systems.
    file.modified = oldTime + 2sec
    second := ws.lookup.findType(name, "A")
    verifyNotSame(ws.lookup.namespace, firstNs)
    verifyEq(second.pod.version, Version("2.0"))
    added := ws.lookup.findSlot(name, "A", "added") as CMethod
    verifyNotNull(added)
    verifyEq(added.parent.qname, "$name::A")
    verifyEq(added.returns.qname, "sys::Int")
    verifyEq(added.params.map |p->Str| { p.name }, ["value", "count"])
    verifyEq(added.params.map |p->Str| { p.type.qname }, ["sys::Str", "sys::Int"])
    verify(added.signature.contains("added"))
    verifyEq(ws.lookup.slotDoc(added), "Added doc")
    verifyEq(ws.lookup.typeDoc(second), "New type doc")
    verifyNull(first.method("added")) // the earlier snapshot remains stable
    verifyNull(Pod.find(name, false))
    verifyNull(ws.lookup.reflectionType(name, "A"))

    file.delete
    verifyNull(ws.lookup.findType(name, "A"))
  }

  Void testNewestRootWinsAndInstalledCopyLoses()
  {
    // util is an installed pod, but is not installed/modified by this test.
    installed := Pod.find("util")
    verifyNotNull(installed.type("PathEnv", false))
    file := ws.buildPod("util", ["WorkspaceOnly.fan": "class WorkspaceOnly {}\n"])
    lookup := ws.lookup
    verifyEq(lookup.namespace.resolvePod("util", null).file.normalize, file.normalize)
    verifyNotNull(lookup.findType("util", "WorkspaceOnly"))
    verifyNull(lookup.findType("util", "PathEnv"))
    verifyNull(lookup.reflectionType("util", "PathEnv"))
    verifyNotNull(lookup.findType("sys", "Str"))

    newerRoot := (ws.root + `other/`).create
    newerLib := (newerRoot + `lib/fan/`).create
    copy := file.copyTo(newerLib + `util.pod`)
    copy.modified = file.modified + 2sec
    lookup.configure([ws.root, newerRoot])
    verifyEq(lookup.namespace.podFile("util").normalize, copy.normalize)
    copy.delete
    verifyEq(lookup.namespace.podFile("util").normalize, file.normalize)

    logs := Buf()
    lookup.logEnvironment(logs.out)
    text := logs.flip.readAllStr
    verify(text.contains("Effective env path:"))
    verify(text.contains(ws.root.osPath))
    verify(text.contains("Workspace pod util 1.0:"))
    verify(text.contains(file.osPath))
  }

  Void testMultiPodDependencyAndInheritedSlot()
  {
    alpha := ws.podName("alpha")
    beta := ws.podName("beta")
    ws.buildPod(alpha, ["A.fan": "class A { Str run(Int count) { count.toStr } }\n"])
    ws.buildPod(beta, ["B.fan": "using $alpha::A\nclass B : A {}\n"], ["sys 1.0", "$alpha 1.0"])
    slot := ws.lookup.findSlot(beta, "B", "run") as CMethod
    verifyEq(slot.parent.qname, "$alpha::A")
    verifyEq(slot.params.first.type.qname, "sys::Int")
    verifyNull(Pod.find(alpha, false))
    verifyNull(Pod.find(beta, false))
  }

  Void testBadWorkspacePodDoesNotFallBackToInstalled()
  {
    (ws.libDir + `util.pod`).out.print("not a zip").close
    verifyErr(IOErr#) { ws.lookup.findType("util", "PathEnv") }
  }

  Void testCorruptUnrelatedPodPreservesNamespaceAndDocs()
  {
    name := ws.podName("zeta")
    ws.buildPod(name, ["A.fan": "** Preserved type documentation\nclass A {}\n"])
    (ws.libDir + `aaaBroken.pod`).out.print("not a zip").close
    before := ws.lookup.namespace
    found := ws.lookup.findTypeInAnyPod("A")
    verifyNotNull(found)
    verifyEq(found.qname, "$name::A")
    verifyEq(ws.lookup.typeDoc(found), "Preserved type documentation")
    verifySame(ws.lookup.namespace, before)
    again := ws.lookup.findTypeInAnyPod("A")
    verifySame(again, found)
    verifyEq(ws.lookup.typeDoc(again), "Preserved type documentation")
    verifySame(ws.lookup.namespace, before)
  }

  Void testInstalledHomeRemainsReflectionFallback()
  {
    lookup := PodLookup([Env.cur.homeDir])
    verifyNull(lookup.namespace.podFile("sys"))
    verifyNull(lookup.namespace.podFile("util"))
    verifyEq(lookup.reflectionType("sys", "Str"), Str#)
    verifyEq(lookup.findType("sys", "Str").qname, "sys::Str")
    logs := Buf()
    lookup.logEnvironment(logs.out)
    text := logs.flip.readAllStr
    verify(text.contains(Env.cur.homeDir.osPath))
    verify(!text.contains("Workspace pod"))
  }

  Void testAutoDetectionStopsAtThreeAncestors()
  {
    (ws.root + `fan.props`).out.print("// env root\n").close
    folder := (ws.root + `one/two/three/`).create
    verify(LspNamespace.detectRoots([folder]).contains(ws.root.normalize))
    deeper := (folder + `four/`).create
    verify(!LspNamespace.detectRoots([deeper]).contains(ws.root.normalize))
    podsRoot := (ws.root + `pods/`).create
    podsLib := (podsRoot + `lib/fan/`).create
    (podsLib + `example.pod`).out.print("detection only").close
    verify(LspNamespace.detectRoots([podsRoot]).contains(podsRoot.normalize))
  }

  Void testServerInitOptionAndLegacyRouting()
  {
    name := ws.podName
    ws.buildPod(name, ["A.fan": "class A {}\n"])
    server := FantomLanguageServer()
    try
    {
      server.initialize(["initializationOptions": ["envPath": [ws.root.osPath]]])
      verifyNotNull(server.podLookup.findType(name, "A"))
      verifyNotNull(HoverProvider().findCompilerType([name], "A"))
      verifyNull(HoverProvider().findType([name], "A"))
      verifyEq(HoverProvider().findType(["sys"], "Str"), Str#)
      server.didChangeConfiguration(["settings": ["fantom": ["envPath": Str[,]]]])
      verifyNull(server.podLookup.findType(name, "A"))
    }
    finally { PodLookup().install }
  }

  Void testConfigurationAndFolderRootsHaveCurrentLifecycle()
  {
    name := ws.podName
    ws.buildPod(name, ["A.fan": "class A {}\n"])
    server := FantomLanguageServer()
    uri := WorkspaceManager.fileToUri(ws.root)
    try
    {
      server.initialize(["initializationOptions": ["envPath": [ws.root.osPath]]])
      verifyNotNull(server.podLookup.findType(name, "A"))
      server.didChangeConfiguration(["settings": ["fantom": ["envPath": Str[,]]]])
      verifyNull(server.podLookup.findType(name, "A"))
      server.didChangeWorkspaceFolders(["event": ["added": [["uri": uri]], "removed": Obj[,]]])
      verifyNotNull(server.podLookup.findType(name, "A"))
      server.didChangeWorkspaceFolders(["event": ["added": Obj[,], "removed": [["uri": uri]]]])
      verifyNull(server.podLookup.findType(name, "A"))
      server.didChangeConfiguration(["settings": ["fantom": ["envPath": [ws.root.osPath]]]])
      verifyNotNull(server.podLookup.findType(name, "A"))
      verify(!server.podLookup.envPath.contains(Env.cur.homeDir.normalize))
      verify(LspNamespace.pathRoots(["relative/root"]).isEmpty)
    }
    finally { PodLookup().install }
  }

  Void testProductionPathEnvChildDoesNotJvmLoadWorkspacePods()
  {
    // Actual fresh JVM with the extension's launch shape. Its runtime path
    // holds ONLY the server pod; test-built libraries are init-option roots.
    runtime := (ws.root + `runtime/`).create
    runtimeLib := (runtime + `lib/fan/`).create
    Env.cur.findPodFile("fantomLsp").copyTo(runtimeLib + `fantomLsp.pod`)
    (runtimeLib + `aaaRuntimeBroken.pod`).out.print("not a zip").close
    javaHome := Env.cur.vars["JAVA_HOME"]
    java := javaHome == null ? "java" :
      (File.os(javaHome) + (Env.cur.os == "win32" ? `bin/java.exe` : `bin/java`)).osPath
    output := Buf()
    child := Process()
    child.command = [java, "-Dfan.home=${Env.cur.homeDir.osPath}", "-cp",
      (Env.cur.homeDir + `lib/java/sys.jar`).osPath, "fanx.tools.Fan", "fantomLsp::NamespacePathEnvProbe"]
    child.dir = runtime
    child.env.keys.each |key|
    {
      if (key.upper == "FAN_ENV" || key.upper == "FAN_ENV_PATH") child.env.remove(key)
    }
    child.env["FAN_ENV"] = "util::PathEnv"
    child.env["FAN_ENV_PATH"] = runtime.osPath
    child.out = output.out
    child.err = output.out
    code := child.run.join
    text := output.flip.readAllStr
    echo(text)
    verifyEq(code, 0)
    verify(text.contains("D6 PATHENV PASS: no JVM workspace load, overwrite/delete/reload, corrupt isolation, runtime exclusion"))
  }
}

** Child entry point deliberately does NOT use Pod.list, even for assertions.
class NamespacePathEnvProbe
{
  static Void main()
  {
    if (Env.cur.typeof.qname != "util::PathEnv") throw Err("Not a PathEnv launch")
    ws := TestWorkspace()
    try
    {
      name := ws.podName
      typeName := "Fresh" + ws.id
      file := ws.buildPod(name, ["A.fan": "class $typeName {}\n"])
      // A lexically early, corrupt unrelated pod exercises broad-search isolation.
      (ws.libDir + `aaaBroken.pod`).out.print("not a zip").close
      server := FantomLanguageServer()
      server.initialize(["initializationOptions": ["envPath": [ws.root.osPath, Env.cur.workDir.osPath]]])
      lookup := server.podLookup
      if (lookup.envPath.contains(Env.cur.workDir.normalize)) throw Err("Runtime root became override")
      if (lookup.findTypeInAnyPod(typeName)?.qname != "$name::$typeName") throw Err("Any-pod workspace miss")
      if (lookup.reflectionTypeInAnyPod(typeName) != null) throw Err("Legacy leaked workspace Type")
      if (Pod.find(name, false) != null) throw Err("Workspace pod visible to JVM")
      if (lookup.findTypeInAnyPod("Str")?.qname != "sys::Str") throw Err("Corrupt pod aborted search")
      if (lookup.reflectionTypeInAnyPod("Str") != Str#) throw Err("Legacy corrupt isolation failed")
      // Delete is a Windows handle/lock assertion, not merely a cache assertion.
      oldTime := file.modified
      file.delete
      file = ws.buildPod(name, ["A.fan": "class $typeName { Int added() { 2 } }\n"], ["sys 1.0"], Version("2.0"))
      file.modified = oldTime + 2sec
      newer := lookup.findTypeInAnyPod(typeName)
      if (newer?.method("added") == null || newer.pod.version != Version("2.0")) throw Err("Rebuild not observed")
      if (Pod.find(name, false) != null) throw Err("Rebuilt workspace pod JVM-loaded")
      server.didChangeConfiguration(["settings": ["fantom": ["envPath": Str[,]]]])
      if (lookup.findType(name, typeName) != null) throw Err("Removed setting resurrected")
      file.delete
      echo("D6 PATHENV PASS: no JVM workspace load, overwrite/delete/reload, corrupt isolation, runtime exclusion")
    }
    finally { ws.cleanup }
  }
}
