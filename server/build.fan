using build

class Build : BuildPod
{
  new make()
  {
    podName = "fantomLsp"
    summary = "Fantom Language Server Protocol implementation"
    version = Version("0.3.0")
    depends = [
      "sys 1.0",
      "util 1.0",
      "concurrent 1.0",
      "build 1.0",
      "compiler 1.0",
    ]
    srcDirs = [
      `fan/`,
      `fan/protocol/`,
      `fan/server/`,
      `fan/parser/`,
      `fan/analysis/`,
      `fan/features/`,
      `test/`,
    ]
  }

  @Target { help = "Build pod and copy to server/lib/fan/ for PathEnv" }
  override Void compile()
  {
    super.compile

    // Copy built pod to server/lib/fan/ so PathEnv finds it
    builtPod := Env.cur.homeDir + `lib/fan/${podName}.pod`
    localLib := scriptDir + `lib/fan/`
    localLib.create
    localPod := localLib + `${podName}.pod`
    builtPod.copyTo(localPod, ["overwrite": true])
    log.info("Copied pod to $localPod")
  }
}
