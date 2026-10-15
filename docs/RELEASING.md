# Releasing

## 1. Bump the version

Both of these must match:

- `client/package.json` → `"version"` (then run `npm install` in `client/` so `package-lock.json` matches)
- `server/build.fan` → `version = Version("x.y.z")`

The server reports its pod version in `initialize` → `serverInfo.version`, and on startup in the **Fantom Language Server** output channel.

Move the `Unreleased` section of [CHANGELOG.md](../CHANGELOG.md) under the new version number.

## 2. Automated checks

```bash
cd server
fan build.fan
fant fantomLsp

cd ../client
npm run compile
npx tsc --noEmit -p .
```

All must pass.

## 3. Package

```bash
scripts/build.sh        # macOS / Linux
scripts\build.bat       # Windows
```

The script:
1. Builds `fantomLsp.pod` and copies it into `client/server/lib/fan/`. The extension runs this bundled pod, never one in the Fantom installation.
2. Compiles the client.
3. Temporarily copies `README.md`, `CHANGELOG.md` and `LICENSE` into `client/` for the Marketplace listing.
4. Produces `client/fantom-lsp-<version>.vsix`.

## 4. Manual smoke test

Install the VSIX into a clean profile, or remove the old version first:

```bash
code --uninstall-extension NV5-FrancisMahony.fantom-lsp
code --install-extension client/fantom-lsp-<version>.vsix
```

Open a workspace containing several pods with `build.fan` files, then check the output channels.

**Fantom Language Server** should show:
- `Version: <version>`;
- `Workspace index complete (...); N symbol entries`, with N greater than 0.

**Fantom LSP Launch** should show your workspace build folders under the lookup roots.

Then, in a real pod:

| Check | Pass if |
|---|---|
| Open a `.fan` file | Server starts; **Fantom LS** appears in the status bar; no error notifications. |
| Hover a type, `sys::Str`, `Type.slot` | Signature and documentation shown. |
| F12 on a call where another type has a slot with the same name | Goes to the correct declaration. |
| F12 into another workspace pod | Opens that pod's source at the declaration. |
| F12 into an installed pod (e.g. `Str.size`) | Opens packaged source, or returns nothing. |
| Click a code-lens count | Opens the references peek. |
| Rename a local; rename a collision-prone slot | Precise edit, or a clear refusal. |
| Type an error, then save | Parser error appears immediately; compiler errors appear on save. |
| Format document | Matches `fantom.formatting.bracketStyle`. |
| Completion after `using `, `using pod::` and a `.` | Sensible items. |

**Do not ship if** the test suite fails, or same-pod types report *Unknown type* after saving.

## 5. Publish

The Marketplace listing points relative links in `README.md` (`CONTRIBUTING.md`, `docs/`, `LICENSE`) at `https://github.com/FrancisMahony/fantomLsp/blob/HEAD/...`, as set by the `repository` field in `client/package.json`. Make sure the GitHub repository is **public**, and the docs are pushed, before publishing; otherwise those links show 404.

Publishing requires a Personal Access Token from Azure DevOps with the Marketplace *Manage* scope.

```bash
cd client
npx @vscode/vsce login NV5-FrancisMahony
npx @vscode/vsce publish --packagePath fantom-lsp-<version>.vsix
```

Tag the release commit: `git tag v<version> && git push --tags`.
