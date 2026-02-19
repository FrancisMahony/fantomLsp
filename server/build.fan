using build

class Build : BuildPod
{
  new make()
  {
    podName = "fantomLsp"
    summary = "Fantom Language Server Protocol implementation"
    version = Version("0.5.0")
    depends = [
      "sys 1.0",
      "util 1.0",
      "concurrent 1.0",
      "build 1.0",
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
}
