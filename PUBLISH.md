# Build and publish notes

## Prerequisites

| Tool | Why |
|------|-----|
| Java 11+ | JVM for `fan` / language server |
| Fantom or SkySpark | `FAN_HOME` with `lib\java\sys.jar` and `fan` on PATH |
| Node.js + npm | VS Code client / vsce |
| `vsce` | `npx vsce` (used by `scripts\build.bat`) |

Set `FAN_HOME` (example: `C:\Skyspark\skyspark-4.0.6`) before building so `fan build.fan` writes the pod.

## One-shot package (Windows)

```bat
C:\Code\monoRepos\fantomLsp\scripts\build.bat
```

This:

1. Compiles `fantomLsp.pod` (`fan build.fan`) into FAN_HOME **and** `C:\Code\monoRepos\fantomLsp\server\lib\fan\`
2. Copies the pod to `C:\Code\monoRepos\fantomLsp\client\server\lib\fan\fantomLsp.pod` (required inside the VSIX)
3. `npm install` + `npm run compile` in `client`
4. Copies root `README.md`, `CHANGELOG.md`, `LICENSE` into `client` for the marketplace listing
5. `npx vsce package` → `C:\Code\monoRepos\fantomLsp\client\fantom-lsp-<version>.vsix`
6. Removes the copied README/CHANGELOG/LICENSE from `client`

If vsce warns that `repository` is missing, type **y**.

**Unix:** `scripts/build.sh` builds server + copies pod + compiles client; it does **not** run vsce. Then:

```bash
cd client && npx vsce package
```

## Version numbers (keep in sync)

- `client/package.json` → `"version"`
- `server/build.fan` → `version = Version("x.y.z")`
- `FantomLanguageServer.initialize` → `serverInfo.version`

Marketplace identity: `publisher` + `name` in `package.json` (`NV5-FrancisMahony.fantom-lsp`).

## Sideload

```bat
code --uninstall-extension NV5-FrancisMahony.fantom-lsp
code --install-extension C:\Code\monoRepos\fantomLsp\client\fantom-lsp-0.2.0.vsix
```

Reload the window. Confirm Output **Fantom Language Server** → `Version: 0.2.0`.

## Marketplace

Personal Access Token from https://dev.azure.com → Marketplace publish.

```bat
cd /d C:\Code\monoRepos\fantomLsp\client
npx vsce login NV5-FrancisMahony
npx vsce publish
```

`vsce publish` packages again unless you pass an existing VSIX (`npx vsce publish --packagePath fantom-lsp-0.2.0.vsix`).

## Dev vs publish

| | Dev (F5) | Publish |
|--|----------|---------|
| Launch | `.vscode/launch.json` → Extension Host, `--extensionDevelopmentPath=…/client` | Installed VSIX |
| Pod | `client/server/lib/fan` via `FAN_ENV_PATH` | Same path **inside** the VSIX |
| After server edits | `fan build.fan` + copy pod to `client\server\lib\fan` + Restart LS | Full `scripts\build.bat` |

Do not rely on SkySpark `lib\fan\fantomLsp.pod` for the VSIX; always copy into `client\server\lib\fan`.

## After publish

Walk through `RELEASE.md` on a clean VS Code profile or after uninstall/reinstall.
