# Fantom LSP — Review, Plan, and Checklist

Review date: 2026-09-11  
Current versions: client `0.2.0`, server pod `0.2.0`, initialize `serverInfo.version` aligned with the pod.

**Symbol-resolution update (2026-10-14):** The binding delivery plan and authoritative execution/review status are in [plans/lsp-symbol-resolution.md](plans/lsp-symbol-resolution.md). This older review remains historical context. **A2** (name-only navigation/references/rename) is superseded by shared declaring-symbol identities, scope-aware fallback, and conservative rename safety; final T12 acceptance verification and T13 independent review/manual smoke remain pending. **R1** is mitigated for navigation by extracting real compiler bindings after name resolution, not by replacing `RecoveringParser`. The parser remains the fallback and the completion/semantic-token index; type tokens lacking compiler source locations use fallback. See `server/test/NavigationAcceptanceTest.fan` for protocol A1–A8 coverage. Workspace lookup is file-backed and separate from the JVM runtime path (D6).

**Status as of 2026-09-11:** Multi-root bounded work is done. **R1** (line-based parser vs compiler AST) still remaining, but nested types, facet classes, closures, and static blocks are improved. Cancel remains **sync best-effort** (`$/cancelRequest` tracked-ids only; no abort of in-flight hover/completion). Idle compile notifications go through `StdioWriteActor` (no 50ms Main drain). `fantom.maxFiles` / `initializationOptions.maxFiles` configures the workspace file cap.

Current rename safety intentionally goes beyond virtual-family refusal: any workspace subtype blocks slot rename, even for nonvirtual slots. Whole-workspace hierarchy coverage must be fresh/resolved/nonduplicate, so unrelated stale pods or source-hash mismatches can block all slot renames. Preparation never compiles; bounded reference refresh may leave hierarchy unavailable with background warm-up disabled. Locals remain scope-bounded without that global audit. T12 includes protocol refusal checks and a real 300-file/500-message mixed-feature stress test; verification/review status remains coordinator-owned in the linked plan.

This document is a code review of the VS Code client and Fantom language server, plus a prioritized plan to fix bugs and land missing language features.

---

## 1. Architecture snapshot

```
client (TypeScript)  --stdio JSON-RPC-->  server (Fantom)
  extension.ts                              Main → JsonRpc → LspDispatcher
                                            FantomLanguageServer
                                            RecoveringParser + SymbolTable + TypeResolver
                                            Feature providers
```

Strengths: editor-agnostic LSP, compiler-pod diagnostics, reflection-based hover/completion for compiled pods.

Weaknesses: single-threaded request loop, line-oriented parser (not the real compiler AST), name-only symbol matching, incomplete indexing, several dead/wrong code paths.

---

## 2. Obvious bugs (fix first)

### Client

| ID | Severity | Issue | Location |
|----|----------|--------|----------|
| C1 | High | `console.log()` with no args left in `findJavaExecutable` | `client/src/extension.ts:43` |
| C2 | High | Formatting middleware default is `"preserve"` but setting enum is only `allman` / `k&r` | `extension.ts:155` vs `package.json` |
| C3 | Medium | Launch output channel always `show(true)` — noisy on every start | `extension.ts:143` |
| C4 | Medium | `fantom.home` change does not restart the server | `extension.ts` config handler only sends bracket style |
| C5 | Low | Language id includes `.pod` (binary/zip pods, not source) | `package.json` `extensions` |
| C6 | Low | Client/server version strings disagree (`0.2.0` aligned) | `package.json`, `FantomLanguageServer.fan` |

### Protocol / process

| ID | Severity | Issue | Location |
|----|----------|--------|----------|
| P1 | High | **Synchronous main loop** — every request (including `initialized` workspace index and compiler diagnostics) blocks the next LSP message. Completions/hover freeze during index. | `Main.fan:19-45` |
| P2 | High | **Compiler diagnostics run on every `didChange`** (keystroke). README says parser-on-keystroke, compiler-on-save. Compiling the whole pod per keystroke is a major lag/crash source. | `FantomLanguageServer.didChange` → `DiagnosticsProvider.computeDiagnostics` |
| P3 | Medium | `initialized` indexing is blocking and capped at **500 files**; no progress notifications | `WorkspaceManager.maxFiles` |
| P4 | Medium | JSON-RPC logs full message bodies at debug forever (`log.level = debug`) | `Main.fan:8`, `JsonRpc.fan` |
| P5 | Medium | Incremental edits: `joinLines` always uses `\n`; original `\r\n` lost. Positions vs VS Code can drift. | `TextDocumentManager.applyEdit` |
| P6 | Medium | `offsetAt` assumes `\n` only (`+ 1` per line) | `DocumentState.offsetAt` |
| P7 | Low | Responses to unknown methods return `result: null` instead of JSON-RPC method-not-found | `LspDispatcher.handleRequest` default |
| P8 | Low | Client `$/` notifications (cancel, progress) logged as unhandled | dispatcher default |

### Parser

| ID | Severity | Issue | Location |
|----|----------|--------|----------|
| R1 | High | **Line-based parser**, not compiler AST. Nested types, methods spanning unusual layouts, `using as` aliases, `using [java]`, inheritance `class Foo : Bar, Mixin` only partially handled. |
| R2 | High | Slot parse: `if (rest.contains("("))` treats **any** `(` as a method — field inits like `Str x := foo()` become methods | `RecoveringParser.tryParseSlot` |
| R3 | High | Brace depth in type body uses **trimmed line** `contains("{")` / `== "}"` — braces in strings/comments skew depth | `parseTypeDef` |
| R4 | Medium | `using` aliases (`using foo::Bar as Baz`) stored as raw rest string | `parseUsing` |
| R5 | Medium | Body type/call extractors ignore `'...'` chars and triple quotes | `extractBodyTypeRefs` / `extractBodyCallRefs` |
| R6 | Medium | `getWordAt` does not include Fantom `::` / `.` so `sys::Str` hover is only `Str` or `sys` | `DocumentState.getWordAt` |
| R7 | Low | `class\t` handled for class but mixin/enum/facet mixed | `parseLine` |

### Analysis / navigation

| ID | Severity | Issue | Location |
|----|----------|--------|----------|
| A1 | **Critical** | **Go to Definition is broken** — `each` callback `return Location(...)` returns from the closure, not the method. Always falls through to `null` after the first `findByName` miss. | `DefinitionProvider.fan:14-21` |
| A2 | High | Definition/references/rename match **unqualified name only** — `foo` matches every `foo` in the workspace | `SymbolTable.findByName`, `ReferenceIndex` |
| A3 | High | `TypeResolver.updateUsings` is called on **index** but **never** on `didOpen`/`didChange` | `FantomLanguageServer` vs `WorkspaceManager.indexDir` |
| A4 | High | `WorkspaceManager.fileContents` is never populated — `getFileContent` / `getAllFileUris` dead | `WorkspaceManager.fan` |
| A5 | Medium | Index skips `lib/` entirely (excludes SkySpark/Fantom source under `lib`) | `excludeDirs` |
| A6 | Medium | Closed docs drop symbols (`didClose` → `symbolTable.remove`) so workspace search loses files that were only opened, not indexed | `FantomLanguageServer.didClose` |
| A7 | Medium | URI encoding: `fileToUri` vs `uriToFile` vs compiler `findBuildFan` disagree on Windows (`file:///` vs `file://`, `%3A`) | `WorkspaceManager`, `CompilerDiagnostics` |
| A8 | Medium | `findType` / `findSlot` take first match across all files — wrong file in multi-pod workspaces | `SymbolTable` |

### Resolved in 0.2.0

Fixed: **C1–C6**, **P1–P8**, **R2–R7**, **A1–A8**, **F1–F12**.

Current **A2/R1** status is recorded in the symbol-resolution update above and its linked delivery plan. The original parser-replacement concern remains a non-goal; compiler-backed navigation mitigates it without promising a full compiler-backed completion/parser rewrite. The prior preferred-uri/name-filter fixes were insufficient collision protection and are superseded by the shared resolver.

### Features

| ID | Severity | Issue | Location |
|----|----------|--------|----------|
| F1 | High | Hover/completion use **current file parse only**, not `SymbolTable` for other workspace types | `HoverProvider`, `CompletionProvider` |
| F2 | Medium | Completion trigger includes `" "` (space) — noisy keyword spam | `Serialization.serverCapabilities` |
| F3 | Medium | Method snippets are `name($0)` not per-parameter placeholders | `CompletionProvider.makeLocalItem` |
| F4 | Medium | Signature help returns `null` when method has **zero params** (`if (params.isEmpty) return null`) | `SignatureHelpProvider.fan:142` |
| F5 | Medium | Call hierarchy incoming uses **type name refs**, not `bodyCallRefs`; `from.name` is the callee, not the caller | `CallHierarchyProvider.incomingCalls` |
| F6 | Medium | Semantic tokens: `facetClassDef` type index `22` but legend has 23 types (0–22). Facet maps to `decorator` accidentally; **no tokens for references**, only declarations | `SemanticTokensProvider` |
| F7 | Medium | Formatter full-file replace; Allman split of `{` can break map literals / it-blocks; `isInString` is per-line not file state | `FormattingProvider` |
| F8 | Medium | Code action “uncomment” replaces **selection range**, not the whole commented line | `CodeActionProvider` |
| F9 | Medium | Unused-using detection is `contains(typeName)` substring — false positives (`Int` in comments) | `findUnusedUsings` |
| F10 | Medium | Compiler error range is `col + 10` dummy span | `DiagnosticsProvider` |
| F11 | Low | Duplicate commented `completion`/`signatureHelp` methods in `FantomLanguageServer` | lines 227–243 |
| F12 | Low | `workspace/didChangeWatchedFiles` not handled — new files on disk not indexed until restart | dispatcher |

---

## 3. Missing / incomplete features (product)

Documented in README but weak or absent:

1. **Go to Definition** — broken for slots (A1); no jump into **compiled pod source** (`src/` in pods) or `sys`.
2. **Find References / Rename** — types/slots by name only; **no locals/params** (known limitation); rename can collide unrelated symbols.
3. **Hover** — no workspace-type hover unless in the same file; no `pod::Type` qualified hover.
4. **Completion** — no `pod::` completion; no auto-import on accept; no `resolveProvider`.
5. **Diagnostics** — unused usings as warnings; no unused var / “wrong type”; no incremental compiler. **DONE:** `srcDirs` recurse nested dirs.
6. **Document highlight**, **inlay hints**, **folding range** — **DONE**. Remaining: selection range, linked editing, code lens.
7. **Incremental semantic tokens** (`semanticTokens/range`, `delta`) — only `full`.
8. **Progress / cancellation** — `$/cancelRequest` tracked-ids only; in-flight work is not aborted.
9. **Multi-root** — **DONE** (bounded): folders appended; prefer current folder when resolving types/slots. Full per-pod isolation not in scope.
10. **`.fwt` files** — **DONE:** indexer collects `.fan` and `.fwt`.

Compiler diagnostics extra bugs:

- **DONE:** `parseSrcDirs` recurses; nested `srcDirs` like `` `fan/protocol/` `` and `` `fan/` `` walk children.
- Transient pod name always `"temp"` — collisions / cache weirdness.
- Compiles **all** project files on **every** diagnostic request.

---

## 4. Implementation plan (phased)

### Phase 0 — Stabilize (1–3 days)

Goal: stop freezes and fix navigation that is simply wrong.

- [x] **C1** Remove stray `console.log()`
- [x] **C2** Default bracket style to `"allman"` in middleware
- [x] **C6 / serverInfo** Align versions (`0.2.0`)
- [x] **A1** Fix `DefinitionProvider` (use `eachWhile` / for-loop; return first real location)
- [x] **P2** Split diagnostics: parser-only on `didChange`; compiler on `didOpen`/`didSave` (match README)
- [x] **F11** Delete commented duplicate methods
- [x] **P4** Default log level `info`; gate `<<`/`>>` dumps on a flag
- [x] Tests: definition for type + slot; didChange does not invoke compiler

### Phase 1 — Correctness of core LSP (1–2 weeks)

- [x] **P5/P6** Preserve `\r\n` in document model; test incremental edits
- [x] **A7** One `uriToFile` / `fileToUri` used everywhere (Windows drive letters)
- [x] **A3** Call `typeResolver.updateUsings` on open/change
- [x] **A2** Qualify symbols (`pod`/`file` + type + slot); references/rename use that
- [x] **R2** Distinguish field vs method (assignment / no `{` body vs `(` after name)
- [x] **R4** Parse `using` as / java ffi
- [x] **F4** Signature help for 0-arg methods (empty param list, still show sig)
- [x] **F10** Map compiler `Loc` length if available; else word-at-col
- [x] **Compiler `srcDirs`** Recurse directories when a dir URI is listed
- [x] Index `.fwt` as well as `.fan`
- [x] Handle `workspace/didChangeWatchedFiles` (add/remove from index)
- [x] **A6** Do not drop indexed symbols on close (only drop overlay for unsaved buffer)

### Phase 2 — Concurrency and scale (1 week)

- [x] **P1** Async workspace index via Actor; compiler diagnostics via `CompileDiagnosticsActor`; idle compile notifications via `StdioWriteActor`
- [x] Raise/remove `maxFiles` with progress; configurable exclude dirs (do not blindly skip all `lib`)
  - `WorkspaceManager.maxFiles` default **2000** (was 500). `lib` stays in `excludeDirs` as vendor/junk (documented).
- [x] Debounce parser diagnostics (~150ms) + cap/logging
  - `didChange` applies all `contentChanges` then parse+parser diagnostics **once per notification**. Skip re-parse when document version matches cached (dirty flag).
- [x] Request cancellation (`$/cancelRequest`) — tracked-ids only; no abort of in-flight hover/completion

### Phase 3 — Feature quality (2–3 weeks)

**Definition / hover / completion**

- [x] Workspace `SymbolTable` in hover and completion (not just current file)
- [x] Go to definition for `Type.slot` and `receiver.slot` using `TypeResolver` + AST
- [x] Optional: unzip pod `src` for stdlib go-to-def
- [x] Completion: remove space trigger; `using pod::` type names; snippet per parameter
- [x] Auto-import code action already exists — add completion additionalTextEdits for missing using

**References / rename / call hierarchy**

- [x] Index `bodyCallRefs` in `ReferenceIndex` (today only types + params)
- [x] **F5** Incoming calls: find methods whose `bodyCallRefs` contain the name; `from` is caller
- [x] Rename: unique edits per range (dedupe); skip if newName invalid identifier
- [x] Locals/params rename **in function scope** (parser: `localDef`)

**Tokens / format / actions**

- [x] **F6** Token types within legend; tokens for references (`bodyRefs`)
- [x] Formatter: don’t split `{` after `,` (already) and after `)` in it-blocks conservatively; round-trip tests
- [x] Uncomment uses full line range
- [x] Unused using: word-boundary / identifier scan, not `contains`

### Phase 4 — New capabilities (backlog)

- [x] `textDocument/documentHighlight`
- [x] `textDocument/foldingRange` (types, methods, comments)
- [x] `textDocument/inlayHint` (inferred types)
- [x] `completionItem/resolve` for docs
- [x] Diagnostics: unused usings as **warnings** (not only code actions)
- [x] `fantom.home` / `javaOpts` change → prompt restart
- [x] Don’t register `.pod` as fantom source
- [x] Neovim/docs: how to run `fan fantomLsp::Main` without VS Code

---

## 5. Suggested work order (checklist)

Use this as the execution checklist. Check items as they land with tests.

### P0 — ship blockers

- [x] Fix go-to-definition return bug (A1)
- [x] Compiler diagnostics only on save/open (P2)
- [x] Remove `console.log()`; fix format default `preserve` (C1, C2)
- [x] Align version strings
- [x] Recurse `srcDirs` for compiler (missed nested source)

### P1 — trust

- [x] URI helpers + CRLF document sync
- [x] Usings updated on every parse
- [x] Name-qualified references/rename (partial: type vs slot filter + dedupe)
- [x] Field vs method parse
- [x] Signature help empty params
- [x] Index watched files + `.fwt`
- [x] Keep symbols after close

### P2 — performance

- [x] Async index via Actor; async compile + idle notifications via `StdioWriteActor`
- [x] Debounce didChange parse (once-per-notification + dirty/version skip; no timers)
- [x] Configurable file cap / excludes (`maxFiles` field default 2000; `lib` still excluded, documented)
- [x] Quiet logging (`Main` log level info; no JsonRpc body dumps)

### P3 — intelligence

- [x] Cross-file hover/completion/definition
- [x] Call hierarchy from `bodyCallRefs`
- [x] Semantic tokens for refs
- [x] Better snippets + using completion
- [x] Formatter fixtures (it-block)

### P4 — extras

- [x] Highlights, folding, resolve, inlay
- [x] Local rename
- [x] Pod source definition
- [x] Settings restart

---

## 6. Testing plan

Existing suite: `fant fantomLsp` under `server/test/`.

Add/extend:

| Area | Tests |
|------|--------|
| Definition | Type, slot, missing symbol, first-match regression for A1 |
| DidChange | Parser errors only; no `Compiler` invocation (hook/spy or timing) |
| TextDocumentManager | Incremental insert/delete, CRLF, end-of-file |
| RecoveringParser | Field with `:= foo()`, `using a::B as C`, nested braces in strings |
| CompilerDiagnostics | Nested `srcDirs`, Windows URI, filter by filename |
| SignatureHelp | 0 params, nested parens, constructor shorthand |
| Rename | Two types named `Foo` in different files — must not both rename |
| CallHierarchy | incoming `from` is caller method |
| Formatting | Allman/K&R fixtures; triple quotes; list indent |

Do not treat green current tests as coverage for A1 (likely untested).

---

## 7. Non-goals (for this cleanup)

- Rewriting the parser as a full Fantom compiler front-end in one step (Phase 3+ may **reuse compiler AST** from `Compiler` instead of `RecoveringParser` for saved files).
- Supporting every LSP 3.17 optional feature.
- Publishing to Marketplace as part of bugfix work.

---

## 8. Recommended next commit

Smallest valuable slice:

1. A1 definition fix + tests  
2. P2 diagnostics split  
3. C1/C2/C6 client nits  

Then pause for a manual pass in Extension Host (open, hover, F12, edit, save, format).
