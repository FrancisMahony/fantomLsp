# Architecture

This document describes how the Fantom language server works internally: how it works out what a name refers to, where it gets type and source information, and how it stays responsive while compiling in the background. For build and test instructions see [CONTRIBUTING.md](../CONTRIBUTING.md).

## Overview

```
VS Code client (TypeScript)                Fantom language server (JVM)
  client/src/extension.ts   --stdio-->       Main / LspMainLoop
  - locates Fantom (fantom.home/FAN_HOME)      LspDispatcher -> feature providers
  - launches the server process                SymbolResolver (shared by all navigation features)
  - forwards settings                            |- SemanticSnapshot  (compiler-backed, exact)
                                                 |- HeuristicResolver (fallback, scope-aware)
                                                 '- ExternalSourceLocator (installed pod sources)
```

The server is an ordinary LSP stdio server and is not tied to VS Code. It is written in Fantom so it can drive the real Fantom `compiler` pod directly.

## Source layout

| Path | Contents |
|---|---|
| `server/fan/Main.fan` | Entry point and main loop (`LspMainLoop`, `StdinReaderActor`). |
| `server/fan/protocol/` | JSON-RPC framing, LSP message types, capability serialization, dispatcher. |
| `server/fan/server/` | `FantomLanguageServer` (state owner, lifecycle, background actors), document and workspace management. |
| `server/fan/parser/` | `RecoveringParser`: a fast, error-tolerant parser producing a partial AST. |
| `server/fan/analysis/` | Symbol resolution, semantic compile/index pipeline, pod registry and namespace, URI normalization. |
| `server/fan/features/` | One provider per LSP feature. |
| `server/test/` | Unit, integration, protocol-acceptance and stress tests (compiled into the pod). |

## Symbol identity

All navigation features share a single identity for every symbol (`ResolutionTypes.fan`):

| Kind | Key format | Example |
|---|---|---|
| Type | `pod::Type` | `acme::Conn` |
| Slot | `pod::Type.slot` | `acme::Conn.close` |
| Local / parameter | `local:<file>#<line>:<col>` (position of its declaration) | `local:file:///c:/src/Foo.fan#12:4` |
| Dynamic call (`->`) | `dyn:<name>` | `dyn:close` |

A slot key always names the **declaring** type, after inheritance has been applied. Fantom has no method overloading, so `pod::Type.slot` identifies exactly one declaration. Two unrelated `close()` methods therefore never share a key.

## Resolution

`SymbolResolver.resolveAt(file, position)` returns a `Resolution`: a list of targets plus a `Certainty`.

| Certainty | Meaning | Go to Definition | Rename |
|---|---|---|---|
| `proven` | Bound by the compiler, or the cursor is on a declaration or an in-scope local. | jumps | allowed (subject to safety checks) |
| `unique` | The fallback resolver found exactly one candidate. | jumps | refused |
| `ambiguous` | Several candidates in a deterministic order, or a single candidate the fallback can't vouch for (e.g. a dynamic call). | peek list | refused |
| `none` | Nothing could be determined. | no result | refused |

Definition, declaration, type definition, implementation, hover, signature help, references, rename, document highlight, linked editing, code lens and call/type hierarchy all use this resolver.

### 1. Compiler-backed semantic index (primary)

`LspCompiler` (`analysis/SemanticCompile.fan`) runs the installed Fantom compiler's frontend steps on one pod, up to and including `ResolveExpr`. It never runs the backend or writes a pod. After `ResolveExpr`, every `CallExpr`, `FieldExpr`, `LocalVarExpr`, `SlotLiteralExpr` and `StaticTargetExpr` in the compiler's AST is bound to its declaration.

- The compile uses the pod's real name and all `srcDirs` from its `build.fan`, including test directories.
- Open editor buffers replace the corresponding files on disk, so unsaved edits are compiled.
- If an error stops the compile before name resolution (for example a syntax error), it is retried once with the broken buffers replaced by their saved text.

`SemanticIndexer` walks the resolved AST and produces an immutable `SemanticSnapshot` for the pod:
- declarations: types, slots, parameters and locals, with name ranges;
- occurrences: every reference, tagged with the key it is bound to.

Compiler locations often point at the start of a declaration (facets, modifiers) rather than its name. The indexer therefore scans forward in the compiled text, skipping comments and strings, for the exact identifier token. If the token isn't found the occurrence is dropped; a range is never invented.

### 2. Keeping snapshots valid while editing

A snapshot describes the text that was compiled. `PositionMapper` compares that text with the current buffer:
- positions on unchanged lines are carried over, shifted by the number of lines inserted or deleted above them;
- positions inside the edited region are discarded.

After mapping, the identifier at the new range must still match the symbol's name. For files that aren't open, the snapshot's content hash must match the file on disk, otherwise that file's occurrences are ignored.

### 3. Heuristic fallback

`HeuristicResolver` handles positions where no fresh snapshot is available: unparseable files, lines edited since the last compile, dynamic `->` calls, and pods that haven't compiled yet. It works from `RecoveringParser`'s partial AST and follows the compiler's rules where it can:

- **Locals and parameters** are looked up only in the enclosing method or closure.
- **Receivers** are typed from declarations, simple inference, `this` and `super`, and fields (including inherited ones).
- **Type names** are visible in the compiler's order: the file's own pod, explicit `using pod::Type [as Alias]`, `using pod`, then `sys`.
- **Inheritance** is followed for slot lookup.
- **Several candidates** are ranked: same file, same pod, imported pods, other workspace pods, installed pods, then alphabetically by key.

The fallback reports `proven` only when the cursor is on a declaration or an in-scope local. A candidate search reports `unique` or `ambiguous`, never `proven`. When parser candidates have to be re-resolved, for references and call hierarchy, the work is capped at 500 per request and can be cancelled.

## Where type information and source come from

| Question | Source |
|---|---|
| Compiling pod `A` | `A`'s source files, with open buffers in place of disk content. |
| What a dependency `B` contains, while compiling `A` | The newest `B.pod` in the workspace lookup roots; if none, the installed copy. |
| Where to jump for a symbol in a workspace pod | That pod's own snapshot, or its parsed source. Never a compiled copy. |
| Hover and signature help for a workspace pod | Its snapshot or parsed source. Never a compiled copy. |
| Hover, signature and navigation for a pod with no workspace source | Its `.pod` file (workspace lookup roots first, then installed). |

A pod is a **workspace pod** if a `build.fan` declaring it is found under a workspace folder (`PodRegistry`). Each pod is compiled separately, as `fan build.fan` does, so a dependency's API is read from its compiled `.pod`. After changing a dependency's public API, rebuild it so its dependents get compiler-proven results. Until then the fallback still navigates to the new source.

### Runtime path vs. workspace lookup roots

Two pod search paths are kept apart on purpose:

- **Runtime path (JVM).** The client launches the server with `FAN_ENV=util::PathEnv` and `FAN_ENV_PATH=<extension>/server`; the Fantom installation is `PathEnv`'s fallback. Any inherited `FAN_ENV_PATH` is removed. This path only loads the server itself, plus `sys`, `compiler` and the other installed pods it needs.
- **Workspace lookup roots (compiler namespace).** These are the `fantom.envPath` setting combined with auto-detected roots: each workspace folder and its three nearest parent folders, if it contains `fan.props` or `lib/fan/*.pod`. Folders below a workspace folder aren't searched. `LspNamespace` reads `.pod` files from these roots directly. They are never loaded into the JVM, so Windows doesn't lock them and rebuilds are picked up on the next lookup or compile (file timestamps are checked). The Fantom installation itself is never treated as a workspace root.

`ExternalSourceLocator` finds source for installed pods. It reads the exact `loc=` line from the pod's `doc/<Type>.apidoc` and opens the source packed in the same `.pod` (`/src/<file>`), falling back to `FAN_HOME/src/<pod>/`. If no apidoc is available, it parses that pod's sources and accepts only a single unambiguous match.

## Threading model

All mutable analysis state is read and written **only on the main (dispatch) thread**. This includes the symbol table, reference index, documents, pod registry, snapshots and the diagnostics cache.

```
StdinReaderActor  -- parsed frames (FIFO) -->  main thread
                                                 |  applyBackgroundResults()  <-- mailbox
                                                 |  dispatch request
IndexActor            -- index batches  ----------------------------------^
SemanticCompileActor  -- snapshots, diagnostics ---------------------------^
StdioWriteActor  <-- every outgoing message (single writer)
```

- **Background actors only produce results.** They receive immutable inputs, never hold a reference to the server, and post immutable results to a mailbox.
- **Results are applied on the main thread.** `applyBackgroundResults` runs before every dispatch and on a 200 ms idle tick, so background results appear without waiting for the next client message.
- **Stale results are discarded.** Index batches carry a generation number; batches from a superseded generation are dropped. Compile results are checked against the document versions and content stamps they were built from.
- **The semantic compiler runs one compile at a time.** Pending requests are coalesced per pod and prioritised: rename freshness first, then pods with open documents, then background warm-up.
- **Cancellation.** The stdin reader marks `$/cancelRequest` tokens as soon as they arrive, so long-running handlers (references, code lens, call hierarchy, rename freshness waits) can stop early.
- **One writer.** Every outgoing message goes through `StdioWriteActor`.

## Diagnostics

- **Parser diagnostics** are computed on every change.
- **Compiler diagnostics** come from the semantic compile, which runs on open, on save, and during background warm-up.

Compiler errors are matched to files by their full normalized path. They are cached per document and merged into every publish, so parser updates don't wipe them. A cached error is dropped only when an edit touches the lines it covers.

## Rename safety

Rename edits only occurrences that carry exactly the target key, and refuses (JSON-RPC error `-32803`, with a reason) unless:

- the target is `proven` and declared in the workspace;
- the pods that might reference it have fresh snapshots, waiting up to 10 seconds for compiles to finish;
- the slot isn't part of a virtual/override/abstract/mixin family, and no workspace type inherits from its owner.

Locals and parameters are renamed only within their declaring scope and skip the workspace-wide checks.

## File identity

`UriKey.canonical` gives each file a single internal key: percent-decoded, forward slashes, lowercase Windows drive letter. This keeps `file:///c%3A/...` and `file:///C:/...` from being indexed twice. Locations sent back to the client use the client's original URI for open documents.

## Code lens

`textDocument/codeLens` returns unresolved lenses for workspace methods, constructors and fields. `codeLens/resolve` computes the reference count from snapshot data only, adding `+` when coverage is incomplete, and returns a `fantom.showReferences` command that opens the references peek. When new snapshots arrive, the server asks the client to refresh lenses via `workspace/codeLens/refresh`, at most once per second.
