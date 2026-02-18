# Fantom Language Server Protocol (LSP) for VS Code

## Context

There is no full-featured LSP for the Fantom programming language. Existing editor support is limited to basic syntax highlighting (VS Code, Sublime) or the aging F4 Eclipse-based IDE. This project fills that gap with a modern, editor-agnostic LSP server and a VS Code client extension.

## Architecture Decision: Fantom Server + TypeScript Client

**The server should be written in Fantom. The VS Code client extension in TypeScript.**

Rationale:
1. **Compiler pod access** — Fantom's `compiler` pod exposes the tokenizer, parser, AST nodes, and type resolution pipeline. Reimplementing all of this in TypeScript would be thousands of lines of work that always lags behind the real compiler.
2. **Reflection API** — Fantom's `sys::Type`, `sys::Slot`, `sys::Pod` APIs let the server inspect compiled dependencies for hover info, completion, and go-to-definition with zero extra work.
3. **No new dependencies** — Fantom already requires a JVM. Users developing in Fantom already have it installed.
4. **Precedent** — This is exactly how Java (Eclipse JDT LS), Kotlin (kotlin-lsp), and other JVM language LSPs work: thin TS client spawns a JVM server process over stdio.
5. **Editor agnostic** — The Fantom server can be reused by Neovim, Emacs, Helix, etc.

The TypeScript client is ~100 lines of boilerplate: spawn the server, pipe stdio, contribute language configuration.

```
┌──────────────────┐       stdio / JSON-RPC       ┌──────────────────┐
│  VS Code Client  │ ◄══════════════════════════► │ Fantom LS Server │
│  (TypeScript)    │   Content-Length + JSON       │ (Fantom on JVM)  │
└──────────────────┘                               └──────────────────┘
  vscode-languageclient                              compiler pod (AST, parser)
  package.json                                       sys pod (reflection)
  TextMate grammar                                   util pod (JSON)
                                                     concurrent pod (actors)
```

---

## Project Structure

```
fantom-lsp/
├── client/                          # TypeScript VS Code extension
│   ├── package.json                 # Extension manifest + dependencies
│   ├── tsconfig.json
│   ├── src/
│   │   └── extension.ts             # Spawn server, configure client
│   ├── syntaxes/
│   │   └── fantom.tmLanguage.json   # TextMate grammar
│   └── language-configuration.json  # Brackets, comments, auto-close
│
├── server/                          # Fantom LSP server pod
│   ├── build.fan                    # BuildPod script
│   └── fan/
│       ├── Main.fan                 # Entry point: stdio loop
│       ├── protocol/
│       │   ├── JsonRpc.fan          # JSON-RPC framing (Content-Length)
│       │   ├── LspMessages.fan      # LSP types as Fantom classes
│       │   ├── LspDispatcher.fan    # Method routing
│       │   └── Serialization.fan    # LSP <-> Fantom Map conversion
│       ├── server/
│       │   ├── FantomLanguageServer.fan  # Top-level state + capabilities
│       │   ├── TextDocumentManager.fan   # Open doc tracking + versioning
│       │   └── WorkspaceManager.fan      # Pod discovery, workspace folders
│       ├── parser/
│       │   ├── RecoveringParser.fan      # Error-recovering parser
│       │   ├── PartialAst.fan           # AST error node types
│       │   └── IncrementalParser.fan    # Debounced reparse logic
│       ├── analysis/
│       │   ├── SymbolTable.fan          # Per-file + workspace symbol index
│       │   ├── TypeResolver.fan         # Type resolution (compiler + reflection)
│       │   ├── ScopeAnalyzer.fan        # Local variable scope tracking
│       │   └── ReferenceIndex.fan       # Cross-file reference tracking
│       ├── features/
│       │   ├── DiagnosticsProvider.fan
│       │   ├── HoverProvider.fan
│       │   ├── DefinitionProvider.fan
│       │   ├── ReferencesProvider.fan
│       │   ├── CompletionProvider.fan
│       │   ├── SignatureHelpProvider.fan
│       │   ├── RenameProvider.fan
│       │   ├── FormattingProvider.fan
│       │   ├── CodeActionProvider.fan
│       │   ├── WorkspaceSymbolProvider.fan
│       │   ├── SemanticTokensProvider.fan
│       │   └── CallHierarchyProvider.fan
│       └── util/
│           ├── FanDoc.fan               # FanDoc -> Markdown conversion
│           ├── UriUtil.fan              # file:// URI <-> Fantom File
│           └── LspPosition.fan          # LSP 0-based <-> Fantom 1-based
│
├── test/
│   ├── server/                      # Fantom unit tests
│   │   ├── build.fan
│   │   └── fan/
│   ├── integration/                 # End-to-end LSP protocol tests
│   └── fixtures/                    # Sample .fan files for testing
│
└── scripts/
    ├── build.sh / build.bat         # Build client + server
    └── package.sh / package.bat     # Create VSIX
```

---

## Phase 0: Bootstrapping

**Goal:** Extension launches the Fantom server, completes the `initialize`/`initialized` handshake, logs to Output panel. No language features yet.

### Client (`client/`)
- `extension.ts`: Locate Fantom (`FAN_HOME` env var or `fantom.home` setting), spawn `fan fantomLsp::Main` as child process, wire stdio to `LanguageClient`
- `package.json`: Declare `"languages"` contribution for `.fan` files, depend on `vscode-languageclient`
- `fantom.tmLanguage.json`: Basic TextMate grammar covering keywords, strings (including `"""` triple-quote and `${}` interpolation), comments (`//`, `/* */`, `**` fandoc), numbers, URI literals (backtick-delimited), DSL literals

### Server (`server/`)
- `Main.fan`: Read stdin, write stdout, dispatch to `FantomLanguageServer`
- `JsonRpc.fan`: Parse `Content-Length` headers, read/write JSON via `util::JsonInStream` / `util::JsonOutStream`. All logging to stderr (stdout is exclusively for JSON-RPC)
- `LspDispatcher.fan`: Route `initialize` → return `ServerCapabilities` (empty for now), `initialized`, `shutdown`, `exit`
- `build.fan`: BuildPod with depends on `sys`, `util`, `compiler`, `concurrent`

### Key challenge
- Finding the Fantom runtime reliably across platforms. Must check `FAN_HOME`, then PATH for `fan` / `fan.bat`, then provide a clear error if not found.

### Verification
- Install extension in VS Code, open a `.fan` file, check Output panel for `[Fantom Language Server]` showing the handshake completed

---

## Phase 1: Parsing & Diagnostics

**Goal:** Report syntax errors as the user types (red squiggles in the editor).

### Error-Recovering Parser (`RecoveringParser.fan`)
This is the **single most critical component** of the entire project. The standard `compiler::Parser` aborts on the first fatal error, making it unusable for editor scenarios with incomplete/malformed code.

**Strategy: Fork the compiler's Parser source** (open source, AFL 3.0 license) and add recovery:
- At **statement boundaries**: on parse error, catch `CompilerErr`, scan forward to next `;`, newline+keyword, or `}`, resume parsing
- At **type/slot boundaries**: scan to next `class`, `mixin`, or slot keyword and resume
- At **expression level**: scan to end of statement, insert an `ErrorExpr` placeholder node
- At **common incomplete patterns**: `obj.` → insert placeholder identifier; unclosed `{` → auto-close at EOF; `if (x ==` → insert placeholder RHS

Introduce `ErrorExpr` and `ErrorStmt` AST node types to represent unparseable regions while keeping the surrounding AST valid.

### Tokenizer Wrapper (`RecoveringTokenizer`)
- Wrap `compiler::Tokenizer`, catch exceptions on unterminated strings/comments, skip to next line, continue
- The tokenizer requires a `Compiler` instance — create a lightweight one with `CompilerInput` in string mode

### Document Manager (`TextDocumentManager.fan`)
- Track open documents: URI → (version, source text, cached AST, cached errors)
- Handle `didOpen`, `didChange` (apply incremental edits), `didClose`
- Debounce reparse: wait 200ms after last keystroke before parsing

### Diagnostics Provider
- Convert `CompilerErr[]` from parser to LSP `Diagnostic[]` (map 1-based `Loc` to 0-based LSP positions)
- Publish via `textDocument/publishDiagnostics` notification
- Clear diagnostics when file is closed

### Key Fantom APIs
`compiler::Tokenizer`, `compiler::Token`, `compiler::TokenVal`, `compiler::Loc`, `compiler::CompilerErr`, `compiler::Compiler`, `compiler::CompilerInput`, all AST node types

### Verification
- Open a `.fan` file with syntax errors → red squiggles appear at correct locations
- Fix the errors → squiggles disappear
- Type incomplete code (`class Foo {`, `obj.`) → no crash, partial errors shown

---

## Phase 2: Navigation

**Goal:** Go-to-definition, hover info, find references, document symbols.

### Symbol Table (`SymbolTable.fan`)
- Walk the parsed AST using `compiler::Visitor` to collect all definitions (types, fields, methods, local variables, parameters)
- Build per-file symbol tables on each parse

### Type Resolution (`TypeResolver.fan`)
This is where Fantom's ecosystem pays off:
- **Source types** (current pod): resolved from parsed AST `TypeDef` nodes
- **Compiled dependency types**: resolved via `sys::Pod.find(name)` → `Pod.types()` → `Type.slots()`, `Type.doc()`, `Type.inheritance()`
- **Compiler bridge**: use `compiler::ReflectNamespace` to bridge runtime `sys::Type` into compiler `CType` for unified resolution
- Resolve `using` imports to map short names to qualified types

### Go-to-Definition (`DefinitionProvider.fan`)
- Resolve token at cursor: type name → `TypeDef` location; method/field → `SlotDef` location; local variable → `LocalDefStmt` location
- For compiled pod types: jump to source if embedded in pod, otherwise show hover info

### Hover (`HoverProvider.fan`)
- Show type signature as Fantom code block + FanDoc converted to Markdown
- `FanDoc.fan` converts Fantom's `**` doc comment format to Markdown

### Find References (`ReferencesProvider.fan`)
- Initially: same-file references via identifier matching against resolved symbol table
- Later: cross-file references via workspace index

### Document Symbols
- Emit `DocumentSymbol` for each type, field, method — feeds the Outline view and breadcrumbs

### Key Fantom APIs
`compiler::Visitor`, `sys::Pod.find()`, `sys::Type.find()`, `sys::Type.slots()`, `sys::Type.doc()`, `sys::Slot.doc()`, `sys::Type.inheritance()`, `compiler::CType`, `compiler::ReflectNamespace`

### Verification
- Ctrl+click on a type name → jumps to its definition
- Hover over a method → shows signature + documentation
- Right-click → Find All References → lists occurrences
- Outline view shows file structure

---

## Phase 3: Intelligence

**Goal:** Code completion, signature help, type-aware diagnostics.

### Compiler-Driven Type Resolution
Run the `compiler::Compiler` pipeline up to (but not including) code generation on the current file:
`Tokenize → Parse → ResolveImports → ResolveDepends → CheckInheritance → Inherit → ResolveExpr → CheckErrors`

This gives a fully type-annotated AST. Wrap each step in error handling to tolerate error nodes from the recovering parser.

### Build.fan Discovery
- Walk up from source file to find `build.fan`
- Parse it to extract `podName`, `depends`, `srcDirs` — needed for the compiler to resolve dependencies

### Code Completion (`CompletionProvider.fan`)
Trigger contexts:
| Trigger | What to complete |
|---------|-----------------|
| After `.` | Receiver type's slots (fields + methods), filtered by visibility |
| After `::` | Pod types or type slots |
| After `using` | Pod names via `Env.cur.findAllPodNames()` |
| Bare identifier | Locals → params → `this` members → imported types → `sys` types → keywords |
| Type position (after `:`) | Type names from usings + sys |

**Dot-completion strategy**: Insert a `__cursor__` placeholder at cursor position before parsing, run type resolution to determine receiver type, then list its slots.

### Signature Help (`SignatureHelpProvider.fan`)
- Triggered on `(` and `,` inside method calls
- Resolve the method, return its parameter list with types, highlight the active parameter

### Type-Aware Diagnostics
- Beyond syntax errors: report type mismatches, unknown symbols, visibility errors, nullable safety violations
- These come from `compiler::CheckErrors` and `compiler::ResolveExpr`

### Verification
- Type `myList.` → completion dropdown shows List methods (add, map, each, etc.)
- Type `Pod.` → shows Pod's static methods
- Type a method call `(` → signature help shows parameters
- Assign wrong type to variable → diagnostic error appears

---

## Phase 4: Refactoring

**Goal:** Rename, code actions, formatting.

### Rename (`RenameProvider.fan`)
- Rename local variables (within method), parameters (signature + body), fields/methods (across pod source files), types (across pod + update `using` statements)
- Uses the reference index from Phase 2 to find all occurrences

### Code Actions (`CodeActionProvider.fan`)
Quick fixes triggered on diagnostics:
- Unknown type → **Add `using` import**
- Unused `using` → **Remove import**
- Missing `override` → **Add `override` keyword**
- Unresolved slot → **Suggest similar names** (Levenshtein distance)

### Formatting (`FormattingProvider.fan`)
- Basic formatter following Fantom community conventions: 2-space indent, same-line braces, spaces around operators
- Walk token list + AST, emit formatted output

### Verification
- F2 on a symbol → rename prompt → all references update
- Click lightbulb on "unknown type" error → "Add using" appears
- Format Document command → code is reformatted consistently

---

## Phase 5: Advanced Features

**Goal:** Workspace symbols, semantic highlighting, call hierarchy, performance.

### Workspace Symbol Index
- On server start, scan all `.fan` files in workspace folders + index installed pods via reflection
- Fuzzy-match search for `workspace/symbol` requests
- Background indexing via `concurrent::Actor` with progress notifications

### Semantic Highlighting (`SemanticTokensProvider.fan`)
- Token types: `namespace`, `type`, `class`, `interface` (mixin), `enum`, `method`, `property`, `variable`, `parameter`
- Modifiers: `declaration`, `static`, `readonly`, `abstract`, `deprecated` (via `@Deprecated` facet)

### Call Hierarchy
- Incoming calls: which methods call this one (via reference index filtered to `CallExpr`)
- Outgoing calls: which methods does this one call (walk method body AST)

### Performance Optimization
- Statement-level incremental re-parsing (only reparse the changed method body)
- Token-level diffing to identify minimal changed ranges
- Multi-root workspace support (multiple pods per workspace)

### Verification
- Ctrl+T → workspace symbol search returns results across all project files
- Semantic highlighting: types colored differently from variables, `const` fields from mutable ones
- Right-click → Show Call Hierarchy → shows callers/callees

---

## Concurrency Model

Single processing actor for all language analysis (parsing, resolution, completion) to avoid Fantom's immutability constraints on cross-actor messages. The main thread handles JSON-RPC dispatch and serializes requests to the processing actor:

```
Main Thread (JSON-RPC read/write)
  │
  └──► ProcessingActor (parse, resolve, complete, hover, etc.)
         Uses: compiler pod, sys reflection, symbol tables
```

A separate `IndexActor` handles background workspace indexing.

---

## Packaging & Distribution

- **VSIX** bundles: compiled TS client + `fantomLsp.pod` + TextMate grammar + language config
- **Runtime dependency**: User must have Fantom installed (`FAN_HOME` or `fan` on PATH) — the extension does NOT bundle the Fantom runtime since developers already have it
- Server launches via: `fan fantomLsp::Main` (or `java -cp <fan-classpath> fanx.tools.Fan fantomLsp::Main`)
- Publish to **VS Code Marketplace** and **Open VSX**

---

## Risks & Mitigations

| Risk | Mitigation |
|------|-----------|
| Forked parser diverges from upstream compiler | Minimize changes, mark all modifications, track upstream updates |
| Compiler pod API changes across Fantom versions | Pin minimum version, test against multiple |
| Stdout pollution from Fantom libraries (breaks JSON-RPC) | Redirect all logging to stderr, test thoroughly |
| Type inference for complex chained expressions | Start with explicit types, add inference gradually across phases |
| Performance on large codebases | Debounce, background indexing, single-actor model |
