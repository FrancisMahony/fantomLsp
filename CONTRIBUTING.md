# Contributing

## Architecture

```
┌──────────────────┐       stdio / JSON-RPC       ┌──────────────────┐
│  VS Code Client  │ <=============================> │ Fantom LS Server │
│  (TypeScript)    │   Content-Length + JSON       │ (Fantom on JVM)  │
└──────────────────┘                               └──────────────────┘
```

The server is written in Fantom for direct access to the `compiler` pod (AST, parser, type resolution) and the `sys` reflection API (`Type`, `Slot`, `Pod`). This means hover, completion, and go-to-definition for any compiled Fantom pod work with zero extra configuration.

The VS Code client is a lightweight TypeScript wrapper that spawns the server process over stdio and delegates everything to `vscode-languageclient`.

The server is editor-agnostic -- it speaks standard LSP over stdio and can be adapted for Neovim, Emacs, Helix, or any other LSP-compatible editor.

## Project Structure

```
fantomLsp/
├── client/                              # VS Code extension (TypeScript)
│   ├── src/extension.ts                 # Spawns server, wires LSP client
│   ├── syntaxes/fantom.tmLanguage.json  # TextMate grammar
│   └── language-configuration.json      # Brackets, comments, auto-close
│
├── server/                              # Fantom LSP server pod
│   ├── build.fan                        # BuildPod script
│   ├── fan/
│   │   ├── protocol/                    # JSON-RPC framing, LSP message types, dispatcher
│   │   ├── server/                      # FantomLanguageServer, TextDocumentManager, WorkspaceManager
│   │   ├── parser/                      # Error-recovering parser, partial AST
│   │   ├── analysis/                    # SymbolTable, TypeResolver, ReferenceIndex
│   │   └── features/                    # One provider per LSP feature (hover, definition, completion, rename, diagnostics, formatting, semantic tokens, call hierarchy, highlights, folding, inlay hints, …)
│   └── test/                            # Unit tests
│
└── scripts/                             # build.bat / build.sh
```

## Building from Source

### Server

```bash
cd server
fan build.fan
```

This compiles `fantomLsp.pod` into your Fantom installation's `lib/fan/` directory.

### Client

```bash
cd client
npm install
npm run compile
```

### Running in Development

Open the repo root in VS Code and press `F5` to launch an Extension Development Host.

### Packaging / publish

See [PUBLISH.md](PUBLISH.md). On Windows, prefer `scripts\build.bat` so the pod is copied into the VSIX.

Pre-release checklist: [RELEASE.md](RELEASE.md).

## Running Tests

```bash
cd server
fant fantomLsp
```

Tests run via Fantom's built-in `fant` runner. The suite covers all providers, the parser, serialization, and analysis layers.

## License

Free to use. Source code is proprietary. See [LICENSE](LICENSE) for details.
