# Release 0.2.0 — tests and publish

Do this **before** Marketplace / internal share. Automated suite is not a substitute for the last pass in VS Code.

## Automated (required)

```bat
cd /d C:\Code\monoRepos\fantomLsp\server
fan build.fan
fant fantomLsp
```

Must report all tests passed. Fix failures before packaging.

## Manual VS Code (required)

Use a **normal** window with the **0.2.0 VSIX** (or Extension Host after `scripts\build.bat`). Open a **multi-repo folder** such as `C:\Code` (not only a single pod). Confirm Output → **Fantom Language Server**:

- `Version: 0.2.0`
- `Found N pod(s) with build.fan` with **N > 0**
- `project compile … files via …\build.fan` on save (not `standalone` for files that have a nearby `build.fan`)

Then in a real pod (e.g. `analytics\src\conn\nv5Facilityone`):

| # | Check | Pass if |
|---|--------|---------|
| 1 | Open `.fan` | Server starts; status bar **Fantom LS** |
| 2 | Hover type / `sys::Str` / `Type.slot` | Markdown signature |
| 3 | F12 peer class in same pod | Opens the other `.fan` |
| 4 | F12 `Type.method` in **another** pod | Opens that library source |
| 5 | Completions: `using `, `using pod::`, dot on a local | Sensible items; extra pod type may add `using` |
| 6 | Typo while typing | Parser errors live |
| 7 | Save | Compiler diagnostics; **no** Unknown type for classes in the same `fan/` folder |
| 8 | Params with `:= null` | **Not** unused-local on `null` |
| 9 | Format document | Allman/K&R per setting |
| 10 | Outline / Ctrl+T | Types and methods |
| 11 | Unused using / organize usings | Warning + code action |
| 12 | Inlay on `x := "hi"` | `: Str` (optional) |

Fail the release if (7) or (3)/(4) regress.

## Publish (Windows)

1. Bump versions together if needed: `client\package.json`, `server\build.fan` `version`, `FantomLanguageServer` `serverInfo.version`.
2. `FAN_HOME` / `fantom.home` must point at a Fantom or SkySpark install with `lib\java\sys.jar`.
3. Java 11+ on `PATH` (or `JAVA_HOME`).
4. From repo root:

```bat
C:\Code\monoRepos\fantomLsp\scripts\build.bat
```

Answer **y** if vsce asks about a missing `repository` field.

5. Install only the **current** VSIX:

```bat
code --uninstall-extension NV5-FrancisMahony.fantom-lsp
code --install-extension C:\Code\monoRepos\fantomLsp\client\fantom-lsp-0.2.0.vsix
```

Delete leftover `client\fantom-lsp-0.1.1.vsix` if it reappears.

6. Marketplace (when ready):

```bat
cd /d C:\Code\monoRepos\fantomLsp\client
npx vsce login NV5-FrancisMahony
npx vsce publish
```

Or upload `fantom-lsp-0.2.0.vsix` in the publisher UI.

## What the VSIX must contain

`scripts\build.bat` copies `server\lib\fan\fantomLsp.pod` to `client\server\lib\fan\` **before** vsce. The extension sets `FAN_ENV_PATH` to that `server` folder. If the pod is missing, the host loads an old pod from SkySpark `lib\fan` and you will not be running 0.2.0.

After install, Output must show **Version: 0.2.0**. If it shows 0.1.1, the VSIX did not include the pod or another extension is winning.

## Users need

- Java 11+
- `fantom.home` or `FAN_HOME` (directory that contains `lib\java\sys.jar`)
- Optional: raise `fantom.javaOpts` (e.g. `-Xmx2048m`) for a huge `C:\Code` tree
- `fantom.maxFiles` default **0** (no index cap)

## Do not ship if

- `fant fantomLsp` fails
- Index log still has `Symbols indexed for 0 entries` on a tree that contains `build.fan` pods
- Same-pod types show **Unknown type** after save
