# Fantom Language Support

A full-featured Language Server Protocol (LSP) implementation for the [Fantom programming language](https://fantom.org), with a VS Code client extension.

```
┌──────────────────┐       stdio / JSON-RPC       ┌──────────────────┐
│  VS Code Client  │ ◄══════════════════════════► │ Fantom LS Server │
│  (TypeScript)    │   Content-Length + JSON       │ (Fantom on JVM)  │
└──────────────────┘                               └──────────────────┘
```

## Features

| Feature | Details |
|---------|---------|
| **Diagnostics** | Structural errors from the recovering parser + full compiler errors on save. Cross-file refresh. Resolves `@{macro}` deps from `etc/build/config.props`. |
| **Hover** | Type signatures, doc comments, slot details for types and slots from local code and compiled pods. |
| **Completion** | Keywords, pod names on `using` lines, dot-completion on typed expressions, local type and method names. |
| **Signature Help** | Parameter hints with active-parameter highlighting as you type. |
| **Go to Definition** | Jumps to definitions across all files in the workspace. |
| **Find References** | Finds all usages of a type or slot — in field declarations, method signatures, and method bodies. |
| **Rename Symbol** | Renames types, fields, and methods across the workspace including usages inside method bodies. |
| **Document Symbols** | Outline view and breadcrumb navigation for the current file. |
| **Workspace Symbol Search** | `Ctrl+T` fuzzy search across all symbols in all open workspace files. |
| **Code Actions** | Add missing `using`, remove unused `using`, uncomment a `//` line. |
| **Code Formatting** | Full-file formatting with configurable bracket style (preserve / K&R / Allman). |
| **Semantic Tokens** | Syntax highlighting for classes, methods, fields, enums, mixins, and modifiers. |
| **Call Hierarchy** | Prepare, incoming calls, and outgoing calls for methods and constructors. |

## Requirements

- [Fantom](https://fantom.org/doc/docTools/Setup) 1.0.77 or later installed and on `PATH` (or set `fantom.home` in VS Code settings)
- Java 11+ (required by Fantom)
- VS Code 1.75+

## Installation

### 1. Build the server pod

```bash
cd server
fan build.fan
```

This compiles `fantomLsp.pod` into your Fantom installation's `lib/fan/` directory.

### 2. Build the VS Code extension

```bash
cd client
npm install
npm run compile
```

### 3. Load the extension in VS Code

Open the repo root in VS Code and press `F5` to launch an Extension Development Host, or package it with `vsce package` and install the `.vsix`.

## Configuration

| Setting | Default | Description |
|---------|---------|-------------|
| `fantom.home` | `""` | Path to Fantom installation (`FAN_HOME`). Falls back to `FAN_HOME` env var and `PATH`. |
| `fantom.javaOpts` | `"-Xmx1024m"` | JVM options passed to the language server process. |
| `fantom.formatting.bracketStyle` | `"preserve"` | Bracket style for formatting: `preserve`, `k&r`, or `allman`. |
| `fantom.trace.server` | `"off"` | LSP message tracing: `off`, `messages`, or `verbose`. |

## Project Structure

```
fantomLsp/
├── client/                          # VS Code extension (TypeScript)
│   ├── src/extension.ts             # Spawns server, wires LSP client
│   ├── syntaxes/fantom.tmLanguage.json  # TextMate grammar
│   └── language-configuration.json  # Brackets, comments, auto-close
│
├── server/                          # Fantom LSP server pod
│   ├── build.fan                    # BuildPod script
│   └── fan/
│       ├── protocol/                # JSON-RPC framing, LSP message types, dispatcher
│       ├── server/                  # FantomLanguageServer, TextDocumentManager, WorkspaceManager
│       ├── parser/                  # Error-recovering parser, partial AST
│       ├── analysis/                # SymbolTable, TypeResolver, ReferenceIndex
│       ├── features/                # One provider class per LSP feature
│       └── test/                    # Unit tests (fan build.fan test)
│
└── scripts/                         # build.bat / build.sh / test.bat / test.sh
```

## Running Tests

```bash
cd server
fan build.fan test
```

All tests run via Fantom's built-in `fant` test runner. The suite covers all providers, the parser, serialization, and analysis layers (~300 tests).

## Architecture

The server is written in Fantom for direct access to the `compiler` pod (AST, parser, type resolution) and the `sys` reflection API (`Type`, `Slot`, `Pod`). This means hover info, completion candidates, and go-to-definition for any compiled Fantom pod work with zero extra effort.

The VS Code client is ~100 lines of TypeScript boilerplate that spawns the server process over stdio and delegates everything to `vscode-languageclient`.

The server is editor-agnostic — it speaks standard LSP over stdio and can be used with Neovim, Emacs, Helix, or any other LSP-compatible editor.

## Known Limitation

**Local variable and parameter tracking is not implemented.** Rename and Find References work for types, fields, and methods but not for local variables or method parameters declared inside method bodies. This requires scope-aware parsing of method body contents and has a poor effort-to-value ratio given that locals are typically short-lived and renamed manually with ease.

## License

Academic Free License v3.0 — see [AFL-3.0](https://opensource.org/licenses/AFL-3.0).
