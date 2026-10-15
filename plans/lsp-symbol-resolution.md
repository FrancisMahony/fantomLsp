# Fantom LSP: Correct Symbol Resolution (Navigation, References, Code Lens)

- Plan date: 2026-10-13
- Baseline: branch `main`, last commit `dbffa8d0200ba6f0fe223d48ac04017b7f5995a7` (`.git/logs/HEAD`). Server pod `fantomLsp 0.2.0` (`server/build.fan`). Client `fantom-lsp 0.2.0`, `vscode-languageclient ^9.0.1`, VS Code engine `^1.75.0`.
- Readiness: **READY.** No user decisions are outstanding. Open items in §6 are owned by tasks; they are not blockers.

---

## 1. Goal, symptoms, acceptance

**Goal.** When you click an identifier, go to the declaration it actually binds to: the right slot, on the right type, in the right pod. One shared resolver drives definition, declaration, typeDefinition, implementation, hover, signature help, references, rename, document highlight, linked editing, code lens, and call/type hierarchy. The intermittent "codelens" error toasts stop.

**Reported symptoms.**
1. Clicking often lands on the wrong function, or on a function in the wrong library.
2. Random "codelens" error toasts in the bottom-right corner.
3. Suspected name collisions.

**Product acceptance (observable):**
- **A1.** Suppose two pods or types declare the same name (`close()`, `make`, `Foo`). Definition reaches the declaration the Fantom compiler binds to. This covers:
  - `Type.slot` and `pod::Type.slot`
  - `local.slot` (declared or inferred type), `this.slot`, `super.slot`
  - bare inherited `slot()`
  - chained calls `a.b().c()`
  - calls inside closures and it-blocks

  It must hold whenever the file's last compile reached name resolution and the clicked line has not been edited since.
- **A2.** Clicking a local variable or parameter resolves only within its enclosing method or closure scope. It never goes to a same-named field, or to a parameter in another method or file.
- **A3.** If the target cannot be proven, the result is either a deterministic ranked list (VS Code shows a peek list) or nothing. It is never a silent arbitrary jump. A single result is returned only when it is proven, or when it is the only candidate after scope/type filtering. "Cannot be proven" covers:
  - dynamic `->` calls
  - files that fail to parse
  - regions edited since the last compile
  - unknown receiver types
- **A4.** A call into another workspace pod opens that pod's workspace source at the slot name. A call into an installed-only pod (e.g. `sys::Str.size`) opens that pod's source at the correct declaration line when source is available (pod-zip `src/`, or `FAN_HOME/src`). If no source exists, the result is null and hover still works.
- **A5.** References, rename, code-lens counts, and document highlight include only occurrences bound to the same symbol. Rename refuses with a clear message when coverage cannot be proven, and it never renames unrelated same-named symbols.
- **A6.** Code lens shows "N references", computed lazily via `codeLens/resolve` from precise references. Clicking it opens the references peek. Setting `fantom.codeLens.enabled` (default true) turns it off. No code-lens request returns an error during indexing, editing, or compiling.
- **A7.** No `ConcurrentModificationException` (or other internal error caused by shared mutable state) reaches the client.
- **A8.** A physical file is never indexed under two URIs (Windows `file:///c%3A/...` vs `file:///C:/...`).

**Non-goals.**
- Replacing `RecoveringParser`; it remains as the fallback.
- Improving completion quality. Completion must not regress, but it is not migrated.
- Semantic token changes.
- Compiling on every keystroke (see the §9 follow-up).
- Resolving `->` dynamic calls; they cannot be decided by design.
- Publishing.

---

## 2. Root causes (verified in code)

### RC1: Bare-name lookup with a nondeterministic first match (main cause of wrong jumps)
- `SymbolTable.findByName` (`server/fan/analysis/SymbolTable.fan:66-92`) matches `e.name == name || e.node.name == name`.
  - Slot entries are stored as `Type.slot`, but `node.name` is the bare slot name, so `findByName("close")` matches every `close` in every type.
  - After checking the current file and the current folder, it returns the first hit while iterating `symbols.vals` of a HashMap. That order is arbitrary and shifts as files are indexed.
- `DefinitionProvider.definition` (`server/fan/features/DefinitionProvider.fan`):
  - Calls `typeResolver.resolveType(...)` and **discards the result** (lines 20, 28), so `using` imports never affect navigation.
  - Then calls global `findByName(word)` (line 30).
  - Then scans `allEntries` for **any child** named `word` (lines 36-43). Slot children are their params and locals (`RecoveringParser.fan:580-581`), so clicking local `x` can jump to a parameter `x` of an unrelated method in another file.
  - Never checks the enclosing method's locals first (hover does: `HoverProvider.fan:35-37`).
- `definitionTypeDotSlot` (`DefinitionProvider.fan:48-97`):
  - Treats the receiver text as a type name, so `conn.close()` looks up a type named `conn`, fails, and falls through to global `findByName("close")`.
  - Ignores inheritance.
  - Prefers workspace types regardless of `using`.
  - `findTypeInAnyPod` (`LspUtils.fan:35-38`) returns the first type in `Pod.list` order.
- `TypeResolver.resolveType` (`TypeResolver.fan:21-32`) calls `findType(name)` with no URI.
- `parseUsing` (`RecoveringParser.fan:274-291`) drops the `as Alias` part.

### RC2: Source for compiled pods is found by guessing a file and searching for a substring
- `findPodSourceFile` (`DefinitionProvider.fan:129-145`) guesses `src/<pod>/fan/<Type>.fan` and also tries the process CWD.
- `findInPodZip` reads `fan/<Type>.fan`, but upstream `WritePod.writeSrc` stores sources at `src/<file.name>` (fantom-lang/fantom `src/compiler/fan/steps/WritePod.fan`).
- `rangeInFile` (`DefinitionProvider.fan:167-181`) returns the first line that contains the substring.
- Upstream `doc/<Type>.apidoc` contains `loc=<file>:<line>[/<docLine>]` for types and `loc=<line>[/<docLine>]` for slots (`src/compiler/fan/util/ApiDocWriter.fan`, `encodeLoc`). That is exact line data, but the code does not use it.

### RC3: The same file is stored under two URI keys
- The workspace index keys files by `WorkspaceManager.fileToUri` (`WorkspaceManager.fan:92-99,156-163`). Opened documents keep the client's URI (`FantomLanguageServer.fan:229-237`), typically `file:///c%3A/...`.
- `SymbolTable` and `ReferenceIndex` store raw keys (`SymbolTable.fan:26`, `ReferenceIndex.fan:43`). An open file can therefore exist twice: a stale disk copy (old ranges) and a live copy.
- `preferredFolder` matching uses `startsWith` against client-form folder URIs (`SymbolTable.fan:46,81`), so the "prefer current folder" logic silently fails for indexed files.
- `didChangeWatchedFiles` looks up the raw URI (`FantomLanguageServer.fan:295`).

### RC4: Unsynchronized cross-thread mutation (most likely cause of the code-lens toasts)
- `IndexActor` (`FantomLanguageServer.fan:702-725` → `WorkspaceManager.indexWorkspace`) writes `SymbolTable.symbols`, `ReferenceIndex.refs`, and `TypeResolver.usingMap` on a pool thread. Meanwhile the main thread iterates the same HashMaps.
- Fantom `Map.each` iterates the backing Java `HashMap` (`src/sys/java/fan/sys/Map.java`), which throws `ConcurrentModificationException` when the map is modified during iteration.
- `CodeLensProvider` calls `ReferenceIndex.findReferences` (a full `refs.each`) **once per method** (`CodeLensProvider.fan:18`, `ReferenceIndex.fan:48-59`). VS Code requests code lens immediately after a file opens, which is exactly when indexing is running.
- The dispatcher turns the exception into JSON-RPC error `-32603` (`LspDispatcher.fan:45-50`), which VS Code shows as a "Request textDocument/codeLens failed" toast.
- `CompileDiagnosticsActor` calls `docManager.parseDocument` off-thread (`FantomLanguageServer.fan:146-159`). This mutates `DocumentState.cachedParse`/`dirty` (`TextDocumentManager.fan:52-65`) while `didChange` edits the same document. A slow parse of old text can store a stale cache with `dirty=false`; later requests then use stale ranges and land on the wrong lines.
- Folder removal re-indexes without dropping the removed folder's entries.

### RC5: The code lens does not conform to LSP and gives wrong numbers
- Lenses send `"command": {"title": ...}` with no `command` id (`CodeLensProvider.fan:19-20`); LSP requires `Command.command`.
- Counts are workspace-wide bare-name matches.
- Each request costs O(methods × all refs) on the request thread.

### RC6: References, rename, and hierarchies match names only
- `ReferenceIndex` stores bare names, and field accesses without `(` are not indexed (`ReferenceIndex.fan:5-44`; `RecoveringParser.extractBodyCallRefs:779-804`).
- `RenameProvider.rename` edits every same-named symbol and reference (`RenameProvider.fan:34-58`).
- `renameLocal` replaces the word **throughout the whole file** (`RenameProvider.fan:77-94`).
- `CallHierarchyProvider` (`:8,28-36,58-68`) and `TypeHierarchyProvider` (`:7,15,21-25,34-39`) match bare names.
- `DocumentHighlightProvider` and `LinkedEditingRangeProvider` link every same-spelled word in the document.

### RC7: Diagnostics already compile with the real compiler, then discard the resolved AST
- `CompilerDiagnostics.compileProjectFile` (`CompilerDiagnostics.fan:54-71`) runs the full `Compiler.compile` (frontend and backend, transient pod) and keeps only `c.errs`.
- Only the triggering file is overlaid; other unsaved open buffers are read from disk.
- `test/` srcDirs are skipped (line 40).
- `filterErrorsForFile` matches by `endsWith(file.name)` (lines 372-392), so errors from a same-named file in another directory leak in.

### RC8: The server resolves pods against stale installed copies, not your workspace builds (found in review; directly causes "wrong library")
- `client/src/extension.ts:106-107,126-127` sets `FAN_ENV_PATH` to the extension's own `server` folder only. A review probe under this launch printed `Env.cur.path = [skyspark-4.0.6]`.
- The workspace build output (`analytics/lib/fan`, 33 pods built 2026-10-13) is **not** on the path. `skyspark-4.0.6/lib/fan` holds 32 **older** copies of the `nv5*` pods (dated 10/6).
- Every reflection-based lookup therefore reads the stale copies: `Pod.find`, `findTypeInAnyPod`, hover, signature help, pod-source definition, and the compiler's `ReflectNamespace` dependency resolution. Signatures, slots, and line numbers can be wrong, or missing.
- Pods loaded by the JVM stay cached for the server's lifetime, so rebuilding a pod does not take effect without a restart, even with the path fixed.

### RC7 correction: unsaved-buffer overlay is broken today
- `CompilerDiagnostics.overlayOpenFile` passes `buf.toFile(f.uri)`, but `input.srcFiles` takes URIs and the compiler re-reads them from disk (`CompilerDiagnostics.fan:60,128`). A review probe confirmed the compile reads **disk** content, not the buffer.
- Separately, `DefinitionProvider.fan:16-23,74-82` takes the range from `findType` but the URI from `findByName`, which can point at a different file. That produces a wrong-line jump.

### Answer to the user's question: can we use the real AST and stop guessing?
**Yes, for any code the compiler can resolve.** Upstream `Compiler.frontend` runs `… Parse … Inherit … ResolveExpr …` (fantom-lang/fantom `src/compiler/fan/Compiler.fan`). After `ResolveExpr`:
- every `CallExpr.method` and `FieldExpr.field` is a `CMethod`/`CField` whose `qname` is the **declaring** `pod::Type.slot`, with inheritance already applied;
- `LocalVarExpr.var` is bound to its `MethodVar`;
- `TypeRef` nodes keep their source `Loc`.

Fantom does not allow method overloading, so `pod::Type.slot` identifies exactly one slot. `ResolveExpr.run` walks every type before calling `bombIfErr`, so `compiler.types` is usable even when other parts of the pod have type errors.

Certainty is impossible in these cases:
- `->` dynamic calls
- any error raised **before** `ResolveExpr`, which aborts with no `compiler.types`. Examples: syntax errors, an "Unknown type" found during Parse, a bad `using`, inheritance/enum/facet errors, Normalize errors. §7.12 mitigates this with a retry that swaps the failing overlays for their disk text.
- text edited since the last compile
- dependencies the server cannot see or that are stale (RC8, fixed by T03b)

Only these cases use the scope-aware heuristic fallback, and its result is either proven or a ranked list (D2).

---

## 3. User decisions

| ID | Decision | Rationale / consequence |
|---|---|---|
| D1 | **Hybrid resolver.** A compiler-backed semantic index is primary; a scope-aware heuristic handles unsaved, unparseable, or not-yet-compiled code. | Objective bindings wherever possible, with navigation still working on broken code. Largest effort. |
| D2 | If not provable, return a **deterministic ranked candidate list** (peek). Jump directly only when the target is proven or unique. | The user wants no guessing. |
| D3 | **All navigation features** move to the shared resolver (list in §1). | One source of truth; rename becomes collision-safe. |
| D4 | Code lens is **precise, lazy (`codeLens/resolve`), clickable** (opens the references peek), behind `fantom.codeLens.enabled` (default true). | Fixes LSP conformance, counts, and cost. |
| D5 | Dependencies of workspace pods are normally **built/installed** on the env path. | The compiler can resolve cross-pod calls. The LSP maps `pod::Type.slot` back to workspace source for workspace pods. |
| D6 | **Separate runtime and workspace lookup paths** (user approved during delivery). Workspace/configured env roots are passed to the file-backed namespace, not appended to JVM FAN_ENV_PATH. Runtime path retains extension server and installed runtime. | Overrides §7.12.1 launch composition: prevents JVM workspace-pod loading/Windows locks and permits reload without restart. Namespace still resolves current workspace builds first. |

## 4. Assumptions (reversible)
- **AS1.** The semantic compile includes **all** build.fan `srcDirs`, including `test/`, matching `fan build.fan`. Test files gain compiler diagnostics as a result. Reversal: exclude test dirs from the compile input only.
- **AS2.** After indexing, a background warm-up compiles each workspace pod once: one worker, pods of open docs first. Setting `fantom.semanticIndex.backgroundCompile` (default true).
- **AS3.** Snapshots keep a compact extracted index only. The compiler AST is not retained.
- **AS4.** Running `Compiler.frontend` only (no backend/transient pod) is enough for diagnostics and the index. `Compiler.cleanup` is private, so call `c.ns?.cleanup` in a `finally`. If frontend-only drops meaningful diagnostics (checked by T04b), keep `compile()` and read `c.types` afterwards.
- **AS5.** Compiler `Loc.line`/`col` are 1-based (upstream `Tokenizer`). Fantom `Str` indexes are UTF-16 units, which matches the default LSP encoding. Tab handling of `col` is checked by a T04a test.
- **AS6.** VS Code shows a code lens with `command: ""` as a non-clickable label; this is used only for "0 references". T10 verifies it manually and has a fallback.

## 5. Evidence index
- Local files are cited inline in §2. Paths are relative to the repo root.
- Upstream fantom-lang/fantom `master` (tree `5ad75b7`), under `src/compiler/fan/`:
  - `Compiler.fan`: frontend order; `types` is set by Parse.
  - `steps/Parse.fan`: `bombIfErr` runs before `compiler.types` is assigned.
  - `steps/ResolveExpr.fan`: walks all types, then calls `bombIfErr`.
  - `ast/Visitor.fan`: `walk(Compiler, VisitDepth)`; callbacks `enter/exit/visitTypeDef|FieldDef|MethodDef`, `enter/exit/visitBlock`, `enter/exit/visitStmt`, `visitExpr`.
  - `ast/Expr.fan`: `CallExpr.method`, `FieldExpr.field`, `LocalVarExpr.var`, `SlotLiteralExpr.slot`, `StaticTargetExpr`.
  - `ast/TypeRef.fan`: `TypeRef : Node, CType`, carries a loc.
  - `Loc.fan`: `file/line/col` only, 1-based, no end position.
  - `parser/Parser.fan`: a call's loc is the method-name token; binary `ShortcutExpr` uses the lhs loc; index expressions use `[`; `TypeCheckExpr` uses the target loc.
  - `ast/MethodVar.fan`: no loc (use `LocalDefStmt.loc`/`ParamDef.loc`).
  - `steps/ScanForUsingsAndTypes.fan`: a TypeDef's loc is the `class` keyword; a slot's loc is the start of the declaration (facets/modifiers); there is no `nameLoc`.
  - `steps/WritePod.fan`: sources at `src/<file.name>`, `doc/<Type>.apidoc`.
  - `util/ApiDocWriter.fan`: `loc` attribute format.
- `src/sys/java/fan/sys/Map.java`: `each` iterates the HashMap, so concurrent modification throws CME. `List.java`: `each` uses an index loop.
- Not verified: the locally installed compiler version (no local `src/compiler` was found). `TypeRef` may be missing in older versions, so T04a must feature-detect it.

## 6. Open questions and risks (non-blocking)
- **Q1 (T00, needs the user):** paste the code-lens toast text and the "Fantom Language Server" output stack trace. This is expected to confirm RC4/RC5. The plan fixes both causes either way.
- **R1 (T04a):** compiler API differences (`TypeRef`, Visitor callbacks, `Loc.col`). Mitigation: reflection-based feature detection; if an API is missing, skip that occurrence class.
- **R2 (T04b/T11):** compile time and memory for many pods. Mitigation: single worker, compact snapshots, settings toggle, open pods first.
- **R3 (T07a):** installed pods without `src/`/apidoc. Definition returns null; hover still works via reflection.
- **R4 (coordination):** every build installs to the shared `FAN_HOME/lib/fan/fantomLsp.pod`, so builds/tests must be serialized across tasks (see §8 Conventions).
- **R5 (T03b):** the right upstream `CNamespace` base for loading `.pod` files from workspace dirs must be confirmed against compiler 1.0.83. Fallback: make sure `FAN_ENV_PATH` includes the workspace env roots (client side). The compiler's reflection then sees current builds at server start, but rebuilt pods need a server restart (the status-bar restart).

---

## 7. Architecture

### 7.1 Overview
```
main thread (sole owner of ALL mutable analysis state)
  LspDispatcher.dispatch(msg)
    1. server.applyBackgroundResults()   <- drain mailbox (index batches, semantic snapshots)
    2. handle request/notification
         providers -> SymbolResolver.resolveAt(docKey, pos)
                        a) SemanticSnapshot (+ PositionMapper)  exact, compiler-backed
                        b) HeuristicResolver                    scope/usings/inheritance; proven or ranked list
                      -> ExternalSourceLocator (pod::Type.slot -> source Location)

background (pure producers; never touch main-thread state)
  IndexActor:            reads/parses files  -> mailbox "indexBatch"
  SemanticCompileActor:  frontend compile of one pod with immutable text overlays
                         -> SemanticIndexer.extract -> mailbox "snapshot"
                         -> publishes compiler diagnostics directly (version-guarded)
```

### 7.2 Canonical URI keys (T01)
- New `server/fan/analysis/UriKey.fan`:
  - `static Str canonical(Str uri)`: for `file:` URIs it percent-decodes, normalizes `file:`/`file://`/`file:///` prefixes, turns `\` into `/`, and lowercases the Windows drive letter. It emits `file:///c:/dir/x.fan` (decoded path). Idempotent. Non-file URIs are returned unchanged.
  - `static Str toClientUri(Str key)`: emits a VS Code-style URI (`file:///c%3A/dir/x.fan`, spaces as `%20`, other reserved characters percent-encoded).
- Every internal map key is canonical: documents, symbols, refs, usings, snapshots, folders, pod registry.
- For open docs, `TextDocumentManager` remembers the client's original URI string. All outgoing URIs (`Location.uri`, `publishDiagnostics.uri`, `WorkspaceEdit.changes` keys, call/type hierarchy items) go through one helper, `server.clientUri(key)`: the remembered string if the doc is open, otherwise `UriKey.toClientUri`.
- `WorkspaceManager.fileToUri` returns canonical keys. `uriToFile` accepts both forms.

### 7.3 State ownership (T02): main thread only, with a mailbox
- **Invariant:** `SymbolTable`, `ReferenceIndex`, `TypeResolver`, `TextDocumentManager`/`DocumentState`, `PodRegistry`, the snapshot store, and `WorkspaceManager.folders` are read and written **only on the main (dispatch) thread**.
- Background actors are pure producers:
  - `IndexActor` collects files, reads text, parses with `RecoveringParser`, computes a content hash, and sends batches of about 50 `[key, ParseResult, hash]` (wrapped in `Unsafe`, never touched again by the producer) to a mailbox actor. The mailbox follows the existing `OutgoingQueueActor` enqueue/drain pattern (`FantomLanguageServer.fan:645-674`).
  - Each batch carries an index `generation`. Batches from a superseded generation are dropped.
- `server.applyBackgroundResults()` is called first in `LspDispatcher.dispatch` for every message. It drains the mailbox and applies the results:
  - index entries are skipped for keys that are currently open (open buffers are authoritative);
  - entries under removed folders are dropped;
  - snapshots are stored (latest generation per pod wins).
- `didChangeWorkspaceFolders` removal drops that folder's entries immediately on the main thread.
- `CompileDiagnosticsActor` is replaced by `SemanticCompileActor` (T04b). It receives immutable inputs (`podName`, build.fan path, and a `Str:Str` overlay map `key -> text` plus `key -> version`, made immutable via `toImmutable`). It never calls `docManager`.
- A thread-safe `concurrent::ConcurrentMap` holds `docVersions` (`key -> latest version`). The main thread updates it on open/change/close; the compile actor reads it to drop stale diagnostics (§7.5).
- Tests and synchronous paths: keep `indexWorkspaceNow()` as a synchronous main-thread index (it parses inline and applies directly). Tests that call server methods directly call `applyBackgroundResults()` when needed.

### 7.4 Pod registry and structured usings (T03)
- `server/fan/analysis/PodRegistry.fan`, built on the main thread when an index generation completes, from every `build.fan` found (`WorkspaceManager.findBuildPods`). Per pod it holds:
  - `podName`, parsed from `podName = "..."`;
  - `buildFan`;
  - `srcDirs`, via the existing `CompilerDiagnostics.parseSrcDirs` (internal, same pod);
  - `dependNames`, via `extractDependenciesFromBuildFan` names;
  - `folderKey`.
- PodRegistry API:
  - `podForFile(key) -> PodInfo?` (longest srcDir prefix, else nearest ancestor build.fan dir);
  - `byName(podName, preferFolderKey) -> PodInfo[]` (deterministic order: same folder first, then path);
  - `isWorkspacePod(name)`;
  - `filesOf(pod)`.
- If two workspace pods share a name, ranking follows: same workspace folder, then path order. Both are kept, never silently merged.
- `usingDef` AstNode gains `usingPod`, `usingType` (nullable), `usingAlias` (nullable), and `isJava`. `name` keeps its current value for compatibility. `TypeResolver.updateUsings` keys aliases by alias name.
- Type-name visibility order for a file in pod P (the heuristic, mirroring the compiler):
  1. types in P;
  2. explicit `using pod::Type [as Alias]`;
  3. types of `using pod` imports;
  4. `sys`.

  Several equally visible matches produce multiple candidates (`ambiguous`).

### 7.5 Semantic index (T04a extraction, T04b pipeline)
- Contracts live in `server/fan/analysis/ResolutionTypes.fan` (T00c); use `const` classes wherever possible.
  - `SymbolKey` (a `Str`) and its helpers:
    - type `pod::Type`;
    - slot `pod::Type.slot`;
    - local `local:<fileKey>#<line>:<col>` (0-based declaration name position);
    - dynamic `dyn:<name>`.
    - Helpers: `podOf`, `typeKeyOf`, `simpleName`, `isLocal`, `isDyn`.
  - `Occurrence`: `fileKey`, `range` (identifier token, 0-based), `key`, `altKey` (nullable), `kind` (`OccKind`: call, field, type, local, ctorShorthand, slotLiteral, decl), `enclosingSlotKey` (nullable).
  - `SymbolDecl`: `key`, `fileKey`, `nameRange`, `fullRange`, `kind`, `signature` (nullable), `doc` (nullable), `parentTypeKey` (nullable), `superTypeKeys`.
  - `SemanticSnapshot`:
    - `podName`, `generation`;
    - `fileHash: Str:Str` (hash of compiled text per file);
    - `openText: Str:Str` (compiled text, only for files that were open overlays; used for position mapping);
    - `occByFile: Str:Occurrence[]` (sorted by position);
    - `decls: Str:SymbolDecl`;
    - `occByKey: Str:Occurrence[]`;
    - `parseFailedFiles: Str[]`;
    - `resolved: Bool`.
  - `Certainty` enum: proven, ambiguous, none.
  - `SymbolTarget`: `key`, `name`, `kind`, `fileKey` (nullable), `range` (nullable; internal coordinates), `signature` (nullable), `doc` (nullable), `source` (semantic, heuristic, or reflection).
  - `Resolution`: `targets`, `certainty`, `occurrenceRange` (nullable).
  - `RefResult`: `occurrences` (fileKey and range), `complete: Bool`, `uncoveredPods: Str[]`.
- `SemanticIndexer.extract(Compiler c, Str:Str textByFileKey) -> SemanticSnapshot` (in `server/fan/analysis/SemanticIndexer.fan`):
  - Walks `c.types` with a `compiler::Visitor` (`VisitDepth.expr`) and also covers closure bodies. T04a must verify how the installed compiler exposes closure code; a test with calls inside closures and it-blocks is mandatory.
  - Records declarations (TypeDef, FieldDef, MethodDef, ParamDef, local defs) and occurrences:

    | Construct | Occurrence key |
    |---|---|
    | `CallExpr` | `method.qname` |
    | `FieldExpr` | `field.qname` |
    | `LocalVarExpr` | local key (`MethodVar` → its declaring `LocalDefStmt`/`ParamDef` loc) |
    | `StaticTargetExpr` / `TypeRef` | `ctype.qname` (TypeRef feature-detected by reflection) |
    | `SlotLiteralExpr` | `slot.qname` |
    | constructor shorthand `Foo(...)` | `ctorShorthand` occurrence on the `Foo` token: key = ctor qname if that ctor has a non-synthetic workspace declaration, else type key; `altKey` = the other |

  - `qname` always names the **declaring** slot. Synthetic types and slots (names containing `$`, `isSynthetic`) are skipped. Occurrences are deduplicated by (range, key).
  - **Token ranges:** `Loc` is 1-based and often not the name token (decls start at facets/modifiers). Convert to 0-based, then scan forward in the compiled text, skipping comments and string literals, for the first identifier token equal to the expected name. Bounds: same line for expressions; up to 20 lines for declarations. Not found → drop the occurrence (never fabricate). Operator shortcuts with no identifier token are skipped.
- **Pipeline (T04b)** in `server/fan/analysis/SemanticCompile.fan`:
  - `LspCompiler : Compiler` overrides `frontend` to run the installed compiler's frontend steps **up to and including `ResolveExpr`**, catching `CompilerErr`. If `c.types != null`, it extracts the snapshot before closure rewriting steps (`ClosureVars`) can alter locals. If there were no errors, it continues with the remaining check steps for diagnostic parity, **skipping `CompileJs`**. The step list is built from the installed compiler via reflection (`Type.find("compiler::X", false)`), so older and newer compilers both work. `finally` calls `c.ns?.cleanup`. No backend, no transient pod.
  - Fallback if overriding proves infeasible: run `frontend` normally, extract afterwards, and accept that closure-captured locals fall back to the heuristic.
  - Compile input: all srcDirs (AS1), with open-document overlays for **every** open doc in that pod. Depends come from `extractDependenciesFromBuildFan`. Standalone files (no build.fan) compile as today, as a one-file pod.
  - `SemanticCompileActor` uses actor-local coalescing. `request(pod, inputs)` stores the latest inputs in `locals` and self-sends `run(pod)`. `run(pod)` takes and clears the pending inputs if present, otherwise does nothing. One compile runs at a time.
  - Outputs:
    1. the snapshot goes to the mailbox (even when `ResolveExpr` reported errors);
    2. on parse failure: no new snapshot; the mailbox gets `parseFailed(pod, files)`, and the main thread marks those files in the existing snapshot;
    3. diagnostics: for every open doc of that pod, parser diagnostics (computed in the actor from the overlay text via a pure `DiagnosticsProvider.computeParserDiagnosticsFor(DocumentState, ParseResult)`) plus compiler errors filtered by **full normalized path**. These are published only if `docVersions[key]` still equals the compiled version; stale ones are dropped.
  - Triggers:
    - `didOpen` (if no snapshot for the pod, or the snapshot is older than disk);
    - `didSave`;
    - watched-file change of a non-open file (low priority);
    - warm-up after each index generation (AS2; open-doc pods first; skipped when `fantom.semanticIndex.backgroundCompile=false`);
    - `ensureFresh(pods, timeout)` for rename (§7.10): send the requests and wait on the actor futures with a timeout, then `applyBackgroundResults()`.

### 7.6 Position mapping (T05)
- `server/fan/analysis/PositionMapper.fan` (pure): `make(Str oldText, Str newText)` computes the common prefix lines and common suffix lines.
  - `toNew(Position) -> Position?`: prefix → same; suffix → shifted by the line delta; changed middle → null.
  - `toOld(Position) -> Position?`: the inverse.
  - `rangeToNew(LspRange) -> LspRange?`: both ends must map and stay on the same line.
- Freshness rules in the facade:
  - open doc: compare the snapshot `openText` (or, if the file was compiled from disk, the disk text read via `uriToFile`) with the current buffer using a mapper;
  - non-open file: snapshot `fileHash` must equal the index content hash, otherwise that file's occurrences are ignored.
  - After mapping, verify the identifier text at the mapped range equals `simpleName(key)` (or the ctor shorthand type name). On mismatch → treat as not found.

### 7.7 Heuristic resolver (T06): fallback only, never crosses scopes
`HeuristicResolver.resolveAt(ctx, docKey, ParseResult, DocumentState, Position) -> Resolution` (in `server/fan/analysis/HeuristicResolver.fan`):
1. Read the identifier and its qualifier (`pod::Type`, `Type.slot`, `pod::Type.slot`, `recv.slot`, `recv?.slot`, `recv->slot`).
2. Cursor on a declaration name → that declaration (proven).
3. Unqualified lowercase identifier inside a method → enclosing local/param via `LspUtils.findEnclosingLocal` (closure scopes honoured) → proven local target. **Locals are never searched outside the enclosing method.**
4. Receiver typing:
   - type name or qualified type → resolve via §7.4;
   - local/param with a declared type, or a type inferred by `extractTypeFromRhs`;
   - `this` → the enclosing type; `super` → its base;
   - a field of the enclosing type (including inherited fields) → its declared type;
   - `->` → dynamic: all same-named slots in visible types, ambiguous, capped at 20;
   - unknown receiver → same-named slots in types visible to the file (P, usings, sys), then other workspace pods; ambiguous.
5. Bare call or identifier: the enclosing type's own and inherited slots, then (if capitalized) type visibility per §7.4.
6. Slot lookup on a type walks inheritance:
   - workspace types: `baseType`/`mixins` resolved per §7.4;
   - installed types: `Type.slot(name)`, taking `slot.parent` as the declaring type.
   - Keys always use the declaring type.
7. Exactly one target → proven. More than one → ambiguous, ranked same file < same pod < `using` pods < other workspace pods < installed pods, ties broken by key. The ranking is deterministic.
8. Removed from navigation: global `findByName`, the `allEntries` child scan, and `findTypeInAnyPod` as a "first pod wins" choice. Pod scans may only produce candidate lists.

### 7.8 External source locator (T07a): installed pods
`ExternalSourceLocator.locateInstalled(Str key) -> [File, LspRange]?` (in `server/fan/analysis/ExternalSourceLocator.fan`):
1. `Pod.find(pod, false)`, then `pod.file(`/doc/<Type>.apidoc`, false)`. Parse the `== <Type>` header `loc=<file>:<line>` and the `-- <slot>` blocks' `loc=<line>`.
2. Source file, in order:
   - `pod.file(`/src/<file>`, false)`, extracted to `Env.cur.tempDir/fantomLsp-src/<pod>-<version>/<file>` (reused if present);
   - `Env.cur.homeDir/src/<pod>/**/<file>`;
   - `Env.cur.findFile(`src/<pod>/...`)`.
3. Range: the first identifier token equal to the slot or type name at or after the line (masking comments and strings), at most 20 lines ahead.
4. No apidoc: search that pod's source files for the type declaration with `RecoveringParser`, **restricted to that pod**, then the slot within it.
5. Never use the process CWD. Never do a first-substring search over a whole file.

### 7.9 SymbolResolver facade (T07b)
`server/fan/analysis/SymbolResolver.fan`, constructed on the main thread from the server's state:
- `resolveAt(docKey, pos) -> Resolution`:
  1. If the doc's pod has a snapshot and the doc is not parse-failed, map the position (T05). An occurrence at the position → proven, with that key. A decl name at the position → proven. A `dyn:` key → heuristic step 4 `->` path.
  2. Otherwise → `HeuristicResolver`.
- `targetLocation(key, preferFolderKey) -> [fileKey, range][]`:
  - workspace pod (PodRegistry) → that pod's snapshot decl (mapped to the current text if open), else the index entry for the type within that pod and the slot within that type;
  - else `ExternalSourceLocator.locateInstalled`;
  - locals → their declaration.
  - Multiple workspace copies of a pod → ranked per §7.4.
- `signatureOf(key)` / `docOf(key)`: snapshot decl, else index node (`formatLocalSig`), else reflection (`Slot.find`/`Type.find` with `LspUtils.formatSlotSig`/`formatTypeSig`).
- `references(key, includeDecl) -> RefResult`:
  - candidate pods: the key's pod and workspace pods whose `dependNames` contain it (all workspace pods for keys from installed pods), filtered by the name prefilter (`ReferenceIndex` files containing the simple name);
  - fresh snapshot files → exact occurrences (mapped);
  - files that are not fresh → heuristic occurrences of the name whose `resolveAt` is proven with the same key; their pod is added to `uncoveredPods`, and `complete=false`;
  - locals → the declaring file and method only.
- All Location output goes through `server.clientUri` (§7.2).

### 7.10 Feature behavior
- **Definition/declaration:** proven → one `Location`; ambiguous → ranked `Location[]`; none → `null`.
- **typeDefinition:** the declared type of the target (local/field/return type) when resolvable, else the same as definition.
- **implementation:**
  - type key → workspace types whose resolved supertypes contain it;
  - slot key → slots with the same name in those subtypes.
  - Empty → definition.
- **Hover:** signature and doc of the resolved target. Ambiguous → first candidate plus "(+N other candidates)". Locals → existing `hoverLocal` formatting.
- **Signature help:** resolve the method-name token before the active `(` via `resolveAt`; render that target's params. Fall back to the current logic only for pod reflection of a proven key.
- **References:** `references(key)`. Incomplete results are still returned.
- **Highlight / linked editing:** same-file occurrences of the same key (locals: the declaring method only).
- **Rename:**
  - `prepareRename` returns an error (JSON-RPC `-32803`, message stating why) unless the target is `proven` (not merely `unique`, §7.12.13) and declared in the workspace.
  - `rename` runs `ensureFresh(uncoveredPods, 10s)` when `complete=false`. Still incomplete → `-32803` "Cannot rename safely: semantic index unavailable for pods X, Y (they may not compile)".
  - Local rename edits only within the declaring scope.
- **Code lens:**
  - `textDocument/codeLens` → lenses for workspace method, ctor, and field declarations in the file, each with `data: {uri: clientUri, key}` and no command. If `fantom.codeLens.enabled=false` → `[]`.
  - `codeLens/resolve` → `references(key, false)`. Command: `{title: "N references" (or "N+ references" when incomplete), command: "fantom.showReferences", arguments: [clientUri, declStart, locations]}`. Zero results → `{title: "0 references", command: ""}`.
  - Capability: `{resolveProvider: true}`.
  - If the client advertises `workspace.codeLens.refreshSupport`, the server sends a `workspace/codeLens/refresh` request after applying new snapshots, debounced to at most one per second. The response is ignored; the dispatcher already ignores id-only messages.
  - Client: register `fantom.showReferences(uri, pos, locs)`. It converts with `client.protocol2CodeConverter` and runs `editor.action.showReferences`.
- **Call hierarchy:**
  - prepare → resolver; method/ctor targets only. The item `data` carries `{key}`.
  - Incoming: call occurrences of the key, grouped by `enclosingSlotKey`; the heuristic uses the enclosing method from the parse.
  - Outgoing: call occurrences whose `enclosingSlotKey == key`, grouped by target.
- **Type hierarchy:**
  - prepare → resolver; type targets only. The item `data` carries `{key}`.
  - Supertypes from decl `superTypeKeys` (heuristic: heritage resolved per §7.4).
  - Subtypes: workspace types whose resolved supertypes contain the key.

### 7.12 Review amendments (binding; these override earlier sections where they conflict)
1. **Workspace pod environment (RC8, task T03b).**
   - The server must resolve workspace pods from current workspace builds, never from stale installed copies.
   - Client: compute `FAN_ENV_PATH` as `<extension>/server` + new setting `fantom.envPath` (string[]) + auto-detected workspace env roots. An env root is a workspace folder, or an ancestor up to 3 levels above it, that contains `fan.props` or `lib/fan/*.pod`. Join with the OS path delimiter.
   - Server: build an `LspNamespace`, a compiler `CNamespace` subclass. It resolves a pod by name from the newest `.pod` file found in workspace env roots' `lib/fan` first, then falls back to the standard reflection namespace. T03b must check which upstream namespace (`FPodNamespace` reading `.pod` files from a directory, or the `ReflectNamespace` base) fits the installed compiler, and record the choice.
   - Pods read from files rather than JVM-loaded reflection pick up rebuilt pods on the next compile. Detect changes by file modified time and invalidate the cache.
   - Reflection helpers (`Pod.find` in hover, signature help, locator) must go through a `PodLookup` service backed by the same namespace (`CType`/`CSlot` API) when the pod comes from a workspace root, so they show current signatures.
   - Log the effective env path and the resolved file and version for each workspace pod at startup.
2. **Compile under the real pod name** read from build.fan (not `uniqueTransientPodName`), so keys are `realPod::Type.slot`. A frontend-only compile loads no transient pod, so names cannot collide.
3. **Real overlays:** `LspCompiler` replaces the Tokenize step. For each source file it calls `Tokenize(c).tokenize(Loc.makeFile(realFile), text)` (or the installed compiler's equivalent), where `text` is the open buffer if one exists, otherwise the disk content. The obsolete `overlayOpenFile` is deleted.
4. **Failure before ResolveExpr:** if `c.types == null` after a compile with overlays, retry once with every overlay that has errors replaced by its disk text. If the retry reaches ResolveExpr, publish that snapshot (open-file freshness then comes from position mapping against the disk text). The diagnostics from the first attempt are the ones published.
5. **Synthetic code:** skip synthetic types and slots only as *declarations*. Always walk their bodies for occurrences: closure `doCall` methods (InitClosures) and the `instance$init`/`static$init` field initializers (Normalize). `enclosingSlotKey` maps to the real source method or field. Track the outer method/field while walking; for closure types, use the closure's enclosing slot.
6. **Local binding:** a first pass over each method builds a `MethodVar → declaring node` map (`LocalDefStmt.var`, `ParamDef`, closure params). Closure-captured shadow variables follow their `shadows` chain (or the installed compiler's equivalent) back to the original. Closure parameter keys use the parameter-name token, found by scanning forward from the closure signature. If a variable cannot be mapped, skip it; the heuristic handles it.
7. **Type references:** the Visitor has no TypeRef callback, so read field, return, param, and heritage types from the declarations directly (`TypeRef` loc when present). Types in local declarations, `is`/`as` checks, and generic arguments may have no loc; those positions go to the heuristic. Document this in T04a.
8. **Snapshots are keyed by build.fan canonical key**, not pod name, so duplicate pod names in multi-root workspaces are kept apart. `PodRegistry` maps each file to its build key.
9. **Diagnostics ordering:**
   - Remove the double send in `enqueueOutgoing` (`FantomLanguageServer.fan:128-133`): send through `StdioWriteActor` only, and delete the `OutgoingQueueActor` drain in `Main.fan:41`.
   - The compile actor no longer publishes. It posts `compilerDiags(buildKey, key→version→diags)` to the mailbox.
   - The main thread caches the latest compiler diagnostics per doc and **merges** them into every publish, so `didChange` parser publishes no longer wipe compiler diagnostics. Diagnostics for a doc are dropped only when it is edited on a line inside the error's range.
   - Because only the main thread publishes, the version race goes away.
10. **Mailbox latency:**
    - When the compile actor posts a snapshot, it also writes a `workspace/codeLens/refresh` request directly through `StdioWriteActor`, if the client supports it (debounce at most 1/s, unique string ids). The resulting client request drains the mailbox.
    - So that background results never sit idle until the next client message, `Main` reads stdin on a reader Actor that pushes parsed messages into a queue. The main loop takes from the queue with a 200 ms timeout. On timeout it calls `applyBackgroundResults()`, which also publishes any pending merged diagnostics. All state access stays on the main thread. This is owned by T02.
11. **`ensureFresh`:**
    - Each compile request carries a `ConcurrentMap` key `buildKey → generation`. When the actor finishes a compile, it records the completed generation in a shared `ConcurrentMap completedGen`.
    - `ensureFresh` loops: sleep 100 ms, check `completedGen ≥ requestedGen` for every pod, then call `applyBackgroundResults()`. It stops after 10 s, or early if the request is cancelled.
    - The actor uses a priority order held in actor-local state: rename/ensureFresh > open-doc pods > warm-up.
12. **Fallback references for files that are not open:** read the file from disk, cached by content hash (bounded LRU of 200 parses). Run heuristic `resolveAt` only on name-prefiltered occurrences, capped at 500 per request. Code lens resolve uses **snapshot data only**, plus "N+" when any candidate pod is stale. Never run heuristic re-resolution in code lens.
13. **Certainty:** add `unique` (exactly one heuristic candidate) as distinct from `proven` (compiler-backed, or a declaration or local under the cursor). Definition jumps on proven or unique. Rename requires proven.
14. **Lifecycle:**
    - `didClose`: re-read the file from disk into the index, clear its doc version, and request a compile of the pod if the buffer was dirty.
    - A watched-file delete removes the file's entries and marks its pod for recompile.
    - A watched `build.fan` change rebuilds that registry entry and requests a compile.
15. **Protocol:**
    - Add `codeLens/resolve` to `LspDispatcher.isKnownRequest` (`:53-96`).
    - `Position`/`LspRange` are already `const` (`server/fan/protocol/LspMessages.fan:1-29`); use them directly.
    - The client already syncs the `fantom` configuration section (`configurationSection`), so new settings arrive in `didChangeConfiguration` automatically. Do not add manual notifications for them.
16. **Remaining URI emitters:** `WorkspaceSymbolProvider`, `DocumentLinkProvider`, `CodeActionProvider`, and `documentSymbol` switch to `clientUri` in T11.

### 7.11 Compatibility
- Capability change: `codeLensProvider.resolveProvider: true`. Request added: `codeLens/resolve`.
- New settings, passed via `initializationOptions` and honoured on `workspace/didChangeConfiguration`:
  - `fantom.codeLens.enabled` (default true);
  - `fantom.semanticIndex.backgroundCompile` (default true).
- Compiler diagnostics now also cover `test/` files (AS1). The diagnostics source stays `fantomCompiler`.
- Completion and semantic tokens keep using the existing `SymbolTable` APIs. Those APIs remain, now main-thread-only.

---

## 8. Task checklist

**Conventions (apply to every task):**
- Server commands run from `C:\Code\monoRepos\fantomLsp\server`. Tests are compiled into the pod (`build.fan` srcDirs include `test/`), so **always rebuild first**: `fan build.fan`. Then run focused tests with `fant fantomLsp::<TestClass>` and the full suite with `fant fantomLsp`.
- Client commands run from `C:\Code\monoRepos\fantomLsp\client`: `npm run compile` and `npx tsc --noEmit -p .`.
- A task is done only if the full suite is green, apart from failures T00 recorded as pre-existing.
- Tests that need the real compiler build temporary pod trees under `Env.cur.tempDir` (`build.fan` with `podName`, `srcDirs = [`fan/`]`, `depends = ["sys 1.0"]`) and delete them in `teardown`.
- **Builds/tests are serialized** across tasks. Every `fan build.fan` installs into the shared `FAN_HOME/lib/fan/fantomLsp.pod` (`server/build.fan:33-37`), so worktrees do not isolate verification. Implementation work may proceed in parallel worktrees, but only one task at a time builds and tests. The coordinator merges one task at a time and re-runs the full suite after each merge.
- **Multi-pod test harness (needed by T03b, T04b, T07b, T08–T12):** a shared helper `server/test/TestWorkspace.fan`, created by T03b. It writes temp pod source trees under `Env.cur.tempDir/fantomLsp-test-<uuid>/` using **unique pod names per test run** (e.g. `alpha<uuid8>`). It builds dependency pods to a temp `lib/fan` with `CompilerInputMode.file` + `CompilerOutputMode.podFile` (`outDir` = temp lib), and points `LspNamespace` (§7.12.1) at that temp root. Nothing is installed into `FAN_HOME`, and nothing is loaded through JVM reflection. Temp dirs are deleted in `teardown`.
- §7.12 amendments are binding on every task.
- "Owns" lists the only files a task may modify. Files not listed are read-only for that task.

### Phase A: foundations

- [x] **T00: Baseline and evidence capture**
  - Agent: implementer; reason: mechanical run-and-record.
  - Depends on: none
  - Owns: no files. Report only.
  - Contract:
    - Run the server build and full test suite, plus the client compile and typecheck. Report pass/fail counts and the names of failing tests.
    - Report the installed compiler pod version (`fan -version` or `Pod.find("compiler").version`).
    - The coordinator asks the user for:
      - the code-lens toast text and the matching "Fantom Language Server" output/stack trace (Q1);
      - the folder(s) that hold their workspace-built pods (e.g. `analytics/lib/fan`) and whether a `fan.props` exists there (input to T03b).

      Both are non-blocking.
  - Accept when: baseline results are recorded in §10.
  - Verify: `fan build.fan` and `fant fantomLsp` from `server/`; `npm run compile` and `npx tsc --noEmit -p .` from `client/`.
  - Reviewer: none (coordinator checks the output).
  - State: done; evidence: §10 baseline commands all PASS.

- [x] **T00c: Shared resolution contracts**
  - Agent: implementer; reason: types are fully specified in §7.5.
  - Depends on: T00
  - Owns: `server/fan/analysis/ResolutionTypes.fan` (new), `server/test/ResolutionTypesTest.fan` (new)
  - Contract: Implement the §7.5 types: `SymbolKey` helpers, `OccKind`, `Occurrence`, `SymbolDecl`, `SemanticSnapshot`, `Certainty`, `SymbolTarget`, `Resolution`, `RefResult`. Use `const` classes with immutable collections so values can cross actor boundaries. Ranges use the existing `LspRange`/`Position` classes. If those are not const, store line/col ints and add `toLspRange()`.
  - Accept when: tests cover:
    - key round trips: `sys::Str.size` → pod `sys`, type `sys::Str`, simple name `size`;
    - local key parse;
    - `dyn:` keys;
    - snapshot immutability (`isImmutable`).
  - Verify: `fan build.fan`, then `fant fantomLsp::ResolutionTypesTest` from `server/`.
  - Reviewer: reviewer
  - State: pending; evidence: none

- [x] **T01: Canonical URI keys (RC3, A8)**
  - Agent: implementer-senior; reason: cross-cutting Windows URI integration.
  - Depends on: T00
  - Owns:
    - `server/fan/analysis/UriKey.fan` (new)
    - `server/fan/server/WorkspaceManager.fan`
    - `server/fan/server/TextDocumentManager.fan`
    - `server/fan/server/FantomLanguageServer.fan` (URI intake in did*/watched-files; add the `clientUri(key)` helper; route every outgoing URI that the server builds through it)
    - `server/fan/analysis/CompilerDiagnostics.fan` (`filterErrorsForFile` only)
    - `server/fan/analysis/SymbolTable.fan` (`preferredFolder` comparison only)
    - `server/test/UriKeyTest.fan` (new), `server/test/WorkspaceManagerTest.fan`, `server/test/DidChangeWatchedFilesTest.fan`
  - Excludes: feature providers. They keep emitting `entry.uri`; T08–T11 switch them to `clientUri`.
  - Contract:
    - Implement §7.2.
    - Map keys are canonical everywhere in the owned files. Open docs remember the client URI. `publishDiagnostics` uses `clientUri`.
    - `filterErrorsForFile` compares the full normalized OS path, case-insensitive on Windows.
  - Accept when:
    - `canonical` is idempotent.
    - `file:///c%3A/A%20b/x.fan`, `file:///C:/A b/x.fan`, and `file://C:/A%20b/x.fan` all yield the same key.
    - A file indexed via `fileToUri` and then opened with a `c%3A` URI produces exactly one set of entries.
    - Folder preference works with mixed encodings.
    - Diagnostics for an open doc carry the client's original URI string.
    - A compiler error in `other/dir/Foo.fan` is not attributed to `this/dir/Foo.fan`.
  - Verify: `fan build.fan`, then `fant fantomLsp::UriKeyTest`, `fant fantomLsp::WorkspaceManagerTest`, `fant fantomLsp::DidChangeWatchedFilesTest`, and `fant fantomLsp` from `server/`.
  - Reviewer: reviewer
  - State: pending; evidence: none

- [x] **T02: Main-thread state ownership with a background mailbox (RC4, A7)**
  - Agent: implementer-expert; reason: concurrency invariants, generation handling, and ordering.
  - Depends on: T01
  - Owns:
    - `server/fan/server/FantomLanguageServer.fan` (mailbox actor, `applyBackgroundResults`, `IndexActor` as a pure producer, index generations, folder-removal cleanup, `docVersions` ConcurrentMap, compile actor input made immutable)
    - `server/fan/server/WorkspaceManager.fan` (split into `collectWorkspaceFiles()` (pure) and a main-thread apply; keep a synchronous `indexWorkspace` for tests)
    - `server/fan/protocol/LspDispatcher.fan` (call `server.applyBackgroundResults` at the start of `dispatch`)
    - `server/fan/Main.fan` (reader actor + 200 ms poll loop, §7.12.10; remove the `drainOutgoing` path)
    - `server/fan/protocol/JsonRpc.fan` (only if needed for the reader actor)
    - `server/fan/features/DiagnosticsProvider.fan` (pure `computeParserDiagnosticsFor(DocumentState, ParseResult)`; no `docManager` use from background code; main-thread compiler-diagnostics cache + merge, §7.12.9)
    - `server/fan/server/TextDocumentManager.fan` (document that it is main-thread only)
    - lifecycle per §7.12.14 for `didClose` and watched-file delete (owned in `FantomLanguageServer.fan`)
    - `server/test/WorkspaceStateTest.fan` (new), `server/test/ConcurrencyStressTest.fan` (new)
  - Excludes: feature providers, parser, `SymbolTable`/`ReferenceIndex` internals (their APIs are unchanged; they become main-thread-only).
  - Contract:
    - Implement §7.3 exactly.
    - Background code never touches `SymbolTable`, `ReferenceIndex`, `TypeResolver`, `TextDocumentManager`, or `WorkspaceManager.folders`.
    - The existing `CompileDiagnosticsActor` receives an immutable overlay (`key → text`, `key → version`) and must not call `docManager`. A pure parser-diagnostics path is allowed here, as a minimal precursor to T04b.
    - Index entries for open keys are ignored.
    - Batches from a superseded generation are dropped.
    - Removing a folder drops its entries.
    - Put the invariant in a header comment in `FantomLanguageServer.fan`.
  - Accept when:
    - The stress test does the following against a temp tree of 300 generated files: starts indexing via the `initialized` notification, then, while indexing runs, issues 500 interleaved `textDocument/codeLens`, `definition`, `references`, and `didChange` messages through `LspDispatcher`. Zero responses contain `error`. It passes on 5 consecutive runs.
    - Open-buffer precedence: an open doc whose index batch arrives later keeps its buffer symbols.
    - Folder removal drops entries.
    - A stale compile result for an older doc version is not published.
    - After `didChange`, compiler diagnostics from the last compile are still published, merged with the parser diagnostics.
    - Each notification is written exactly once.
    - A background result is applied within about 300 ms with no further client messages.
    - `didClose` restores the disk-content index entries.
  - Verify: `fan build.fan`, then `fant fantomLsp::WorkspaceStateTest`, then `fant fantomLsp::ConcurrencyStressTest` five times, then `fant fantomLsp` from `server/`.
  - Reviewer: reviewer-expert
  - State: pending; evidence: none

- [x] **T03: Pod registry and structured usings**
  - Agent: implementer; reason: explicit spec using existing build.fan parsing.
  - Depends on: T02
  - Owns:
    - `server/fan/analysis/PodRegistry.fan` (new)
    - `server/fan/parser/PartialAst.fan` (usingDef fields)
    - `server/fan/parser/RecoveringParser.fan` (`parseUsing` only)
    - `server/fan/analysis/TypeResolver.fan`
    - `server/fan/analysis/CompilerDiagnostics.fan` (make `parseSrcDirs`/`extractDependenciesFromBuildFan` reusable; add `parsePodName`)
    - `server/fan/server/FantomLanguageServer.fan` (registry construction in `applyBackgroundResults` when an index generation completes; `podRegistry` field)
    - `server/test/PodRegistryTest.fan` (new), `server/test/ParserTest.fan`
  - Contract: Implement §7.4: registry API, deterministic ranking for duplicate pod names, and using fields (`using a::B as C`, `using [java] x.y::Z`, `using a`).
  - Accept when:
    - `podForFile` resolves files in nested srcDirs.
    - Duplicate pod names rank the same folder first.
    - Parser tests cover the three using forms and alias lookup in `TypeResolver`.
    - Existing parser tests stay green.
  - Verify: `fan build.fan`, then `fant fantomLsp::PodRegistryTest`, `fant fantomLsp::ParserTest`, and `fant fantomLsp` from `server/`.
  - Reviewer: reviewer
  - State: pending; evidence: none

- [x] **T03b: Workspace pod environment and compiler namespace (RC8)**
  - Agent: implementer-expert; reason: compiler namespace internals, pod caching semantics, and environment/launch integration. This is the fix for "wrong library".
  - Depends on: T03
  - Owns:
    - `server/fan/analysis/LspNamespace.fan` (new; includes the `PodLookup` service)
    - `server/fan/analysis/LspUtils.fan` (route `findType`/`findTypeInAnyPod` pod access through `PodLookup`; additive, signatures unchanged)
    - `server/fan/server/FantomLanguageServer.fan` (namespace construction from env roots plus the `envPath` init option; startup logging)
    - `client/src/extension.ts`, `client/package.json` (`fantom.envPath` setting; `FAN_ENV_PATH` composition per §7.12.1)
    - `server/test/TestWorkspace.fan` (new shared harness, see Conventions)
    - `server/test/LspNamespaceTest.fan` (new)
  - Contract:
    - Implement §7.12.1.
    - The namespace resolves the newest workspace-root `.pod` before the installed copy, and reloads when the file's modified time changes.
    - `PodLookup` exposes type/slot lookup (signature, doc, declaring type, params) for both namespace-loaded and reflection pods.
    - Record the chosen upstream namespace base class, and the evidence for that choice, in a header comment.
  - Accept when:
    - With the harness: pod `alpha<id>` v1 is built to a temp lib and resolved via the namespace. It is rebuilt with an added slot (v2), and the next lookup sees the new slot without a restart.
    - An installed pod of the same name as a workspace pod loses to the workspace build.
    - Startup logs show the effective env path and the per-pod resolved files.
    - The client compiles and typechecks.
  - Verify: `fan build.fan`, then `fant fantomLsp::LspNamespaceTest` and `fant fantomLsp` from `server/`; `npm run compile` and `npx tsc --noEmit -p .` from `client/`.
  - Reviewer: reviewer-expert
  - State: pending; evidence: none

### Phase B: resolution engines (T04a, T05, and T07a can run in parallel with T01–T03)

- [x] **T04a: Semantic indexer (compiler AST → occurrences/decls)**
  - Agent: implementer-expert; reason: compiler internals, token-range derivation, version feature detection.
  - Depends on: T00c, T01 (`UriKey` to convert compiler file paths into canonical file keys)
  - Additional binding rules: §7.12 items 5 (synthetic bodies walked), 6 (local binding), 7 (type references).
  - Owns: `server/fan/analysis/SemanticIndexer.fan` (new), `server/test/SemanticIndexerTest.fan` (new)
  - Contract:
    - Implement the §7.5 extraction: `SemanticIndexer.extract(Compiler c, Str:Str textByFileKey) -> SemanticSnapshot`.
    - Verify the installed compiler's API by reading the installed compiler pod's reflection (`Type.find("compiler::TypeRef", false)` etc.). Record findings in a header comment: TypeRef present? how closures/it-blocks are reachable? `Loc.col` semantics with tabs?
    - Tests compile temp pods with a test-local helper (`Compiler` with `CompilerInputMode.file`, run `frontend` in a try/catch). They must not depend on T04b.
  - Accept when: in a temp workspace with pod `alpha` (types `A` and `B : A`, both having `close()`; `B` inherits `run()` from `A`; a mixin `M` with `close()`; and a type `Util` with static `make()`) and pod-local callers, extracted occurrences give the exact declaring key for:
    - `b.close()` → `alpha::B.close`
    - `b.run()` → `alpha::A.run`
    - `Util.make()`, `alpha::Util.make()`
    - chained `x.foo().close()`
    - a call inside `list.each |v| { v.close() }` and inside an it-block
    - `Str#size` slot literal
    - local `x` read → `local:` key of its declaration
    - parameter read → param key
    - `Foo()` ctor shorthand (key/altKey per §7.5)
    - field read without parens

    Also:
    - Ranges cover exactly the identifier token, including declarations preceded by facets/doc/modifiers and lines with tabs.
    - A type error raised during ResolveExpr elsewhere in the pod (e.g. calling an undefined method on a known type) still yields occurrences.
    - An error raised before ResolveExpr (a syntax error, or an unknown type in a signature) yields no snapshot, and no crash.
    - Calls inside closures and field initializers have `enclosingSlotKey` equal to the real source method or field.
    - A closure-captured local resolves to its original declaration.
  - Verify: `fan build.fan`, then `fant fantomLsp::SemanticIndexerTest` from `server/`.
  - Reviewer: reviewer-expert
  - State: pending; evidence: none

- [x] **T05: Position mapper**
  - Agent: implementer; reason: small pure algorithm with a spec.
  - Depends on: T00c
  - Owns: `server/fan/analysis/PositionMapper.fan` (new), `server/test/PositionMapperTest.fan` (new)
  - Contract: implement §7.6 (`toNew`, `toOld`, `rangeToNew`) on line arrays. CRLF and LF are equivalent.
  - Accept when:
    - Identical text maps to identity.
    - An insertion above shifts lines.
    - An edit on the target line → null.
    - Edits below → unchanged.
    - The mapping round-trips where defined.
    - Mixed CRLF works.
  - Verify: `fan build.fan`, then `fant fantomLsp::PositionMapperTest` from `server/`.
  - Reviewer: reviewer
  - State: pending; evidence: none

- [x] **T06: Scope-aware heuristic resolver**
  - Agent: implementer-senior; reason: bounded subsystem with many rules on top of the existing parser.
  - Depends on: T00c, T03b (uses `PodLookup` for installed-type inheritance; serialized after T03b because both touch `LspUtils.fan`)
  - Additional binding rule: §7.12.13. One surviving candidate is `unique`, not `proven`.
  - Owns:
    - `server/fan/analysis/HeuristicResolver.fan` (new)
    - `server/fan/analysis/LspUtils.fan` (additive helpers only; existing signatures unchanged)
    - `server/test/HeuristicResolverTest.fan` (new)
  - Contract: implement §7.7 steps 1–8 over a read-only context (SymbolTable, TypeResolver, PodRegistry, the current doc's ParseResult/DocumentState). It returns keys in the same format as the semantic index (`pod::Type.slot`), with the pod from the PodRegistry for workspace files.
  - Accept when:
    - Two pods both define `close()`. `conn.close()`, with `conn` declared as `alpha::Conn`, is proven `alpha::Conn.close`.
    - An unknown receiver gives an ambiguous result with a deterministic ranked list. Two runs with different index insertion orders give identical output.
    - Local `x` never resolves outside its method. A same-named field resolves only when no local is in scope.
    - An inherited bare call resolves to the base type's declaring key.
    - An aliased using resolves.
    - `->` gives ambiguous.
    - The declaration under the cursor gives proven self.
  - Verify: `fan build.fan`, then `fant fantomLsp::HeuristicResolverTest` from `server/`.
  - Reviewer: reviewer-expert
  - State: pending; evidence: none

- [x] **T07a: External source locator (installed pods)**
  - Agent: implementer; reason: explicit file-format spec (§7.8).
  - Depends on: T00c
  - Owns: `server/fan/analysis/ExternalSourceLocator.fan` (new), `server/test/ExternalSourceLocatorTest.fan` (new)
  - Contract: implement §7.8: apidoc `loc` parsing, source lookup order, temp extraction, token range, and a pod-restricted fallback. No CWD, no first-substring search.
  - Accept when:
    - The apidoc parser handles `loc=Str.fan:20/12` for types and `loc=45` for slots (unit test with a literal apidoc string).
    - A **synthetic pod zip** built in-test (with entries `src/Widget.fan` and `doc/Widget.apidoc` containing `loc=Widget.fan:3` and a slot `loc=7`) resolves `pod::Widget.run` to `src/Widget.fan` line 7 (0-based 6) at the `run` token. The locator must accept an injected pod-file resolver so this test needs no install. The installed `sys` pod has no `src/` here, so `sys::Str.size` returns null without error.
    - An unknown pod returns null.
  - Verify: `fan build.fan`, then `fant fantomLsp::ExternalSourceLocatorTest` from `server/`.
  - Reviewer: reviewer
  - State: pending; evidence: none

- [x] **T04b: Semantic compile pipeline and diagnostics integration**
  - Agent: implementer-expert; reason: compiler pipeline control, actor coalescing, version-guarded publication.
  - Depends on: T02, T03b, T04a
  - Additional binding rules: §7.12 items 2 (real pod name), 3 (real overlays via Tokenize), 4 (pre-ResolveExpr retry), 8 (snapshots keyed by build key), 9 (diagnostics posted to the mailbox, not published), 10 (code-lens refresh), 11 (`ensureFresh` + priority). Compile with `LspNamespace` from T03b.
  - Owns:
    - `server/fan/analysis/SemanticCompile.fan` (new: `LspCompiler`, `SemanticCompileActor`)
    - `server/fan/analysis/CompilerDiagnostics.fan`
    - `server/fan/features/DiagnosticsProvider.fan` (compiler-diagnostic conversion only)
    - `server/fan/server/FantomLanguageServer.fan` (compile triggers, warm-up queue, snapshot store, `ensureFresh`, the `backgroundCompile` init option and configuration handling, removal of `CompileDiagnosticsActor`)
    - `server/test/SemanticCompileTest.fan` (new), `server/test/CompilerDiagnosticsTest.fan`, `server/test/DiagnosticsProviderTest.fan`
  - Contract:
    - Implement the §7.5 pipeline.
    - Use frontend only (AS4) with snapshot extraction before closure rewriting, falling back as described. Overlays cover all open docs of the pod. Include test dirs (AS1).
    - Coalesce with latest-wins.
    - Publish diagnostics for all open docs of the pod, guarded by version.
    - Snapshots go through the T02 mailbox. Parse failure is marked.
    - Warm-up runs after indexing.
    - When the client advertises `workspace.codeLens.refreshSupport`, send a `workspace/codeLens/refresh` request via the stdio writer with unique string ids, debounced to 1/s.
  - Accept when:
    - Opening a doc in a temp pod produces a snapshot whose keys use the real pod name.
    - Editing two open docs in the same pod compiles both overlays together: an error caused by unsaved text in doc A is reported, and doc B's unsaved text is seen. This proves the overlay is real, not read from disk.
    - An unknown type typed into an open buffer still yields a snapshot via the disk-text retry.
    - Compiler diagnostics still appear for a type error, with the same messages as before for an existing CompilerDiagnosticsTest fixture.
    - No transient pod is created (`Pod.list` size unchanged after 3 compiles).
    - Ten rapid save requests produce ≤ 2 compiles.
    - A stale version's diagnostics are not published.
    - `backgroundCompile=false` disables warm-up.
  - Verify: `fan build.fan`, then `fant fantomLsp::SemanticCompileTest`, `fant fantomLsp::CompilerDiagnosticsTest`, `fant fantomLsp::DiagnosticsProviderTest`, and `fant fantomLsp` from `server/`.
  - Reviewer: reviewer-expert
  - State: pending; evidence: none

- [x] **T07b: SymbolResolver facade and request plumbing**
  - Agent: implementer-senior; reason: integration of the engines behind one interface.
  - Depends on: T04b, T05, T06, T07a
  - Owns:
    - `server/fan/analysis/SymbolResolver.fan` (new)
    - `server/fan/protocol/LspDispatcher.fan` (add `codeLens/resolve` to `isKnownRequest` and route it to `server.codeLensResolve`; add `RequestFailedErr` (code `-32803`), mapped to an error response)
  - Additional binding rule: §7.12.12 (bounded disk-read fallback; code lens uses snapshot data only).
    - `server/fan/server/FantomLanguageServer.fan` (`resolver()` accessor; a `codeLensResolve` stub returning params unchanged)
    - `server/test/SymbolResolverTest.fan` (new)
  - Contract:
    - Implement §7.9: `resolveAt`, `targetLocation`, `signatureOf`/`docOf`, `references` with `complete`/`uncoveredPods`.
    - Freshness and mapping rules follow §7.6.
    - Workspace-pod keys map to workspace source; installed keys go to T07a.
    - Every location is returned as (fileKey, range); conversion to client URIs happens in providers via `server.clientUri`.
  - Accept when, with a temp two-pod workspace (`alpha` and `beta` depending on `alpha`, both built/compiled in-test):
    - Snapshot-backed `resolveAt` on `beta`'s call `alpha::Util.make()` returns proven `alpha::Util.make` with its location in `alpha`'s source file.
    - After inserting lines above the call in the open buffer (no recompile), the result is still correct via mapping.
    - Editing the call's own line falls back to the heuristic.
    - `references(alpha::A.close)` includes `beta`'s call sites but excludes `beta::Other.close` calls, with `complete=true` once all pods are compiled and `complete=false` plus `uncoveredPods` when a pod's snapshot is stale.
  - Verify: `fan build.fan`, then `fant fantomLsp::SymbolResolverTest` and `fant fantomLsp` from `server/`.
  - Reviewer: reviewer-expert
  - State: pending; evidence: none

### Phase C: feature migration (T08–T11 can run in parallel after T07b, in separate worktrees; each edits only the listed `FantomLanguageServer` methods)

- [x] **T08: Definition, declaration, typeDefinition, implementation, hover, signature help**
  - Agent: implementer; reason: wiring providers to an established resolver API.
  - Depends on: T07b
  - Owns:
    - `server/fan/features/DefinitionProvider.fan`, `server/fan/features/HoverProvider.fan`, `server/fan/features/SignatureHelpProvider.fan`
    - `FantomLanguageServer.fan` methods `definition`, `declaration`, `typeDefinition`, `implementation`, `hover`, `signatureHelp` only
    - `server/test/DefinitionProviderTest.fan`, `server/test/HoverProviderTest.fan`, `server/test/SignatureHelpProviderTest.fan`
  - Contract:
    - Behavior per §7.10.
    - Delete the bare-name fallbacks in `DefinitionProvider` (`findByName`, `allEntries` child scan, CWD/substring pod-source code) in favour of `SymbolResolver` and `ExternalSourceLocator`.
    - Hover keeps local formatting.
    - Outputs use `clientUri`.
    - Existing tests may be updated only where they encoded the old first-match behavior; record each such change in the PR notes.
  - Accept when, in new collision tests:
    - Two files each define `class Foo` with `close()`; a call through a typed receiver goes to the right one.
    - A local `x` with a same-named param in another file stays local.
    - An unknown receiver returns a ranked `Location[]`.
    - `sys` type/slot definition works when source is available.
    - Hover on `b.run()` shows `A.run`'s signature.
    - Signature help on `conn.close(` shows `alpha::Conn.close`'s params, not another `close`.
  - Verify: `fan build.fan`, then `fant fantomLsp::DefinitionProviderTest`, `fant fantomLsp::HoverProviderTest`, `fant fantomLsp::SignatureHelpProviderTest`, and `fant fantomLsp` from `server/`.
  - Reviewer: reviewer
  - State: pending; evidence: none

- [x] **T09: References, rename, document highlight, linked editing**
  - Agent: implementer-senior; reason: correctness-sensitive edit semantics (rename safety and refusal paths).
  - Depends on: T07b
  - Owns:
    - `server/fan/features/ReferencesProvider.fan`, `RenameProvider.fan`, `DocumentHighlightProvider.fan`, `LinkedEditingRangeProvider.fan`
    - `FantomLanguageServer.fan` methods `references`, `rename`, `prepareRename`, `documentHighlight`, `linkedEditingRange` only
    - `server/test/RenameProviderTest.fan`, `server/test/DocumentHighlightProviderTest.fan`, `server/test/ReferencesProviderTest.fan` (new)
  - Contract:
    - Behavior per §7.10.
    - Rename refuses with `RequestFailedErr` when the target is unproven, external, or incomplete after `ensureFresh`.
    - Local rename is scope-bounded.
    - `WorkspaceEdit` keys use `clientUri`.
  - Accept when:
    - Renaming `alpha::A.close` does not touch `beta::Other.close` or an unrelated local `close`.
    - Renaming local `x` in method m1 does not touch `x` in m2 of the same file.
    - Rename on an ambiguous target is refused with a message.
    - References exclude same-named unrelated symbols.
    - Highlight marks only same-key occurrences.
  - Verify: `fan build.fan`, then `fant fantomLsp::RenameProviderTest`, `fant fantomLsp::ReferencesProviderTest`, `fant fantomLsp::DocumentHighlightProviderTest`, and `fant fantomLsp` from `server/`.
  - Reviewer: reviewer-expert
  - State: pending; evidence: none

- [x] **T10: Code lens (lazy, precise, clickable) and client wiring**
  - Agent: implementer; reason: explicit LSP shapes and a small client change.
  - Depends on: T07b
  - Owns:
    - `server/fan/features/CodeLensProvider.fan`
    - `server/fan/protocol/Serialization.fan` (code lens capability only)
    - `FantomLanguageServer.fan` methods `codeLens`, `codeLensResolve`, plus the `codeLens.enabled` handling in `initialize`/`didChangeConfiguration`
    - `client/src/extension.ts`, `client/package.json`
    - `server/test/CodeLensProviderTest.fan` (new), `server/test/LspSessionTest.fan`
  - Contract:
    - Behavior per §7.10 code lens.
    - Client:
      - register `fantom.showReferences`;
      - add settings `fantom.codeLens.enabled` and `fantom.semanticIndex.backgroundCompile` (descriptions included);
      - pass both in `initializationOptions`;
      - on change, send `workspace/didChangeConfiguration` with `{fantom: {codeLens: {enabled}, semanticIndex: {backgroundCompile}, formatting: {...}}}`;
      - keep the existing bracket-style behavior.
  - Accept when:
    - `codeLens` returns lenses without a `command` but with `data`.
    - `codeLens/resolve` returns a lens whose `command.command == "fantom.showReferences"` and whose count equals the precise references (collision fixture: `alpha::A.close` shows 2 when `beta` has 2 calls and 3 calls to an unrelated `close`).
    - Disabled → `[]`.
    - The capability advertises `resolveProvider: true`.
    - The client compiles and typechecks.
  - Verify: `fan build.fan`, then `fant fantomLsp::CodeLensProviderTest`, `fant fantomLsp::LspSessionTest`, and `fant fantomLsp` from `server/`; `npm run compile` and `npx tsc --noEmit -p .` from `client/`.
  - Reviewer: reviewer
  - State: pending; evidence: none

- [x] **T11: Call hierarchy and type hierarchy**
  - Agent: implementer; reason: wiring to resolver occurrences per spec.
  - Depends on: T07b
  - Owns:
    - `server/fan/features/CallHierarchyProvider.fan`, `server/fan/features/TypeHierarchyProvider.fan`
    - `FantomLanguageServer.fan` methods `prepareCallHierarchy`, `callHierarchyIncoming`, `callHierarchyOutgoing`, `prepareTypeHierarchy`, `typeHierarchySupertypes`, `typeHierarchySubtypes` only
    - `server/test/CallHierarchyProviderTest.fan`, `server/test/TypeHierarchyProviderTest.fan` (new)
    - remaining URI emitters (§7.12.16): `server/fan/features/WorkspaceSymbolProvider.fan`, `DocumentLinkProvider.fan`, `CodeActionProvider.fan` (URI emission only), and `FantomLanguageServer.fan` methods `workspaceSymbol`, `documentLink`, `codeAction`, `documentSymbol`
  - Contract: behavior per §7.10. Items carry `data: {key}`. Callers and callees are grouped by key. All URIs these providers emit go through `clientUri`.
  - Accept when:
    - Incoming calls for `alpha::A.close` list only callers of that slot, with the caller method as `from`.
    - Outgoing calls of a method list resolved callees by key.
    - Subtypes of mixin `alpha::M` exclude an unrelated `beta::M`.
  - Verify: `fan build.fan`, then `fant fantomLsp::CallHierarchyProviderTest`, `fant fantomLsp::TypeHierarchyProviderTest`, and `fant fantomLsp` from `server/`.
  - Reviewer: reviewer
  - State: pending; evidence: none

### Phase D: integration and acceptance

- [x] **T12: End-to-end acceptance suite and docs**
  - Agent: implementer-senior; reason: cross-feature integration through the real protocol path.
  - Depends on: T08, T09, T10, T11
  - Owns:
    - `server/test/NavigationAcceptanceTest.fan` (new)
    - `README.md` (Features/Known Limitations/Settings)
    - `CHANGELOG.md`
    - `PLAN.md` (add a pointer to this plan and mark A2/R1 status)
  - Contract:
    - Using `LspDispatcher` with real `initialize`/`initialized`/`didOpen`/`didSave` against a temp two-pod workspace on disk, assert acceptance A1–A8 through JSON-RPC responses, with a test for each:
      - collision matrix (typed receiver, inherited, chained, closure, it-block, ctor shorthand, static, qualified);
      - locals;
      - unknown receiver → ranked list;
      - cross-pod → workspace source;
      - installed pod → source or null;
      - references/rename/code lens counts;
      - client-URI round trip with `c%3A` URIs;
      - concurrency (re-run the T02 stress test against the full feature set).
    - Document behavior, settings, and limitations (dynamic `->`, unparseable files, unbuilt deps).
  - Accept when: all acceptance tests pass, and the full suite and client checks are green.
  - Verify: `fan build.fan`, then `fant fantomLsp::NavigationAcceptanceTest` and `fant fantomLsp` from `server/`; `npm run compile` and `npx tsc --noEmit -p .` from `client/`.
  - Reviewer: reviewer-expert
  - State: pending; evidence: none

- [ ] **T13: Final independent review and manual smoke test**
  - Agent: reviewer-expert (review), then the user (manual smoke)
  - Depends on: T12
  - Owns: no files.
  - Contract:
    - Review the full diff against §1 acceptance and the §7 invariants (single-owner state, immutable cross-thread data, canonical keys, no bare-name first-match in navigation paths: grep for `findByName(`, `findTypeInAnyPod(`, `allEntries` in `features/`).
    - Then the user runs the extension (F5 or VSIX via `scripts\build.bat`) on their real workspace and checks: no code-lens toasts during startup indexing; F12 on previously wrong calls; the code-lens click opens the references peek; rename on a colliding name; `fantom.codeLens.enabled=false`.
  - Accept when: the reviewer verdict is approve (or all findings are resolved), and the user confirms the smoke results.
  - Verify: the review report plus the user's confirmation recorded in the ledger.
  - Reviewer: n/a
  - State: pending; evidence: none

### Dependency graph and parallelism
```
T00 ─┬─ T00c ─┬─ T05 ───────────────────────────────┐
     │        └─ T07a ──────────────────────────────┤
     └─ T01 ─┬─ T02 ── T03 ── T03b ─┬─ T06 ─────────┤
             └─ T04a (also needs T00c) ─┐           │
                                    T04b (T02,T03b,T04a)
                                        └─ T07b (T04b,T05,T06,T07a) ─┬─ T08 ─┐
                                                                     ├─ T09 ─┤
                                                                     ├─ T10 ─┼─ T12 ── T13
                                                                     └─ T11 ─┘
```
- Parallel implementation (separate worktrees; builds/tests serialized): T05 and T07a after T00c; T04a after T00c+T01. These run alongside the chain T02→T03→T03b.
- Group 2 (after T07b): T08, T09, T10, T11. They share `FantomLanguageServer.fan`, but each owns distinct methods; merges are serialized.
- Shared-file order:
  - `FantomLanguageServer.fan`: T01 → T02 → T03 → T03b → T04b → T07b → group 2.
  - `CompilerDiagnostics.fan`: T01 → T03 → T04b.
  - `LspDispatcher.fan`: T02 → T07b.
  - `DiagnosticsProvider.fan`: T02 → T04b.
  - `LspUtils.fan`: T03b → T06.
  - `client/*`: T03b → T10.

---

## 9. Follow-ups (not in scope)
- An idle-debounced background compile of dirty open buffers (e.g. 1.5 s after the last change) would extend exact resolution to unsaved edits.
- Migrating completion and semantic tokens to the resolver.
- Workspace-source mapping for installed pods that are also present in the workspace under a different version.

---

## 10. Execution ledger (coordinator-owned; the coordinator is the only writer)

| Task | State | Attempts | Evidence (commands/results) | Review verdict | Notes |
|---|---|---|---|---|---|
| T00 | done | 1 | fan build.fan PASS; fant fantomLsp PASS (27 types, 408 methods, 1232 verifies); npm run compile PASS; npx tsc --noEmit -p . PASS. | Coordinator verified handoff | implementer ses_ec9c86c59ffe0Qt9zOJWJ94jjM; no source ownership. |
| T00c | done | 1 | Build PASS; focused 7 methods/125 verifies PASS; combined suite 425 methods/1444 verifies PASS. | PASS reviewer ses_ec9bf32a3ffe6kNN6RmB3tqzrx | implementer ses_ec9c6d85affeBYa3zaNbw84Tuy; ResolutionTypes.fan, ResolutionTypesTest.fan. |
| T01 | done | 1 | Build PASS; UriKey 5/42, Workspace 8/31, Watched 7/44 PASS; combined suite 425/1444 PASS. | PASS reviewer ses_ec9be06c8ffezxZz22FSfkLhlL; independent URI runtime probes PASS | implementer-senior ses_ec9c6d837ffeBe0y2sXxcGXzs3; §8 owned paths. Nullable rootUri list repaired. |
| T02 | done | 2 | Build PASS; WorkspaceState 18/130 PASS; stress x5 each 5 mid-loop batch applies PASS; full 465/3240 PASS. Reviewer independently repeated focused/stress x5/full PASS. | PASS re-review after stress/lifecycle repairs | expert ses_ec9bb0cfaffeLgqKwcHEyZypE6; §8 owned paths; review ses_ec9502e62ffeU9kBsYkBjo4OCg. |
| T03 | done | 2 | Build PASS registry5/36 parser58/264 full472/3297 PASS. | PASS reviewer ses_ec8f36e05ffe7KQB59hRzP6KJh after comment/string podName parser repair | implementer ses_ec9135345ffeZjEt0njhEei5TX; §8 owned paths. |
| T03b | done | 4 | D6 separate paths; build PASS namespace10/66 full497/4033; clientcompile/typecheckPASS. Production PathEnv child confirms no workspace JVM load/lock, delete/rebuild v2 and config lifecycle; corrupt docs/cache regression PASS. | PASS expert ses_ec8660fbcffesKDGlBmFmN01Jv after launch/cache repairs | author senior ses_ec87079ddffe7l0F1oup4Skkuj; §8 owned paths. |
| T04a | done | 6 | Build/full494/4016 PASS; coordinator focused15/670 PASS; reviewer private15 PASS1500methods~100ms. | PASS reviewer ses_ec8ea81aaffe0Gqt9UT5IpHo4z after range/owner/accessor/literal/enum repairs | author senior ses_ec8f1467effeZM7HD6STmMYGuM; only SemanticIndexer.fan/SemanticIndexerTest.fan. Empty expert sessions produced no changes. |
| T05 | done | 1 | Build/full suite 465/3240 PASS; coordinator focused 11/1554 PASS. | PASS reviewer ses_ec9502e3affegrrhcub0DmdcGA | implementer ses_ec9bb0ccdffeWNuVrRORSsnGv3; PositionMapper.fan/PositionMapperTest.fan. |
| T06 | done | 4 | BuildPASS focused14/251 parser59/275 full536/4443PASS; closures/catch/for incl unbraced scope and safe literal inference repaired. | PASS expert ses_ec83aa62fffeaaYBfIPa0TqhxP, independently focused/probes/fullPASS | senior ses_ec84922f7ffe43APOOudtMD0Qh; §8 plus narrow param parser correction. |
| T07a | done | 2 | Build/full suite 465/3240 PASS; coordinator focused 10/95 PASS. | PASS re-review ses_ec9502e3affegrrhcub0DmdcGA after basename ambiguity repair | implementer ses_ec9bb0cb7ffedgfSHGvB1IX4cA; locator + tests. |
| T04b | done | 5 | BuildPASS Semantic21/132 Compiler26/69 Diags16/42; cancellation3 methods31verifies PASS actual midwait ~250ms inprocess/child; full539/4476PASS. | PASS artifact expert ses_ec8139b16ffe9HgykT8ZdFpYuk; cancellation expert ses_ec7d04487ffesOMiJTIafe2qid private current-source build/fullPASS | pipeline senior ses_ec83aa61cffe04gAitfPf5JUy3; cancellation senior ses_ec7d739c2ffeTjYVIZQFx64FHA; design ses_ec7f59865ffeEw3309vbkpeeQ1. |
| T07b | done | 3 | BuildPASS focused11/111 full550/4587PASS; expert independently focused/full/probesPASS. | PASS expert ses_ec7b4ef1affeS5B7B3P4wTBsj8 after local identity/transitive/constructor coverage repairs | senior ses_ec7bcb78fffe9p4n62L3d5Nh0i; §8 owned paths. |
| T08 | done | 6 | BuildPASS Signature25/126 Definition8/79 (111s to431ms), A7/2963PASS; combined full44types610methods9144verifiesPASS. | Hover/navigation PASS ses_ec5607ccbffeRaSIIXQopYqA6C; signature PASS ses_ec4f5bdc3ffe1DIL17RaNDluni; heritage PASS ses_ec4cfc28cffe8owvehX1NLfR4t | hover ses_ec5693c8bffeGGdzdiYBB1ydFo; signature expert ses_ec50a0c5effejhIbVXGnwlJSrj; heritage expert ses_ec4e2853dffelZbKAP5ADXEntp; owned provider/tests per task; no blocker. |
| T09 | done | 4 | Conservative subtype refusal + whole-workspace freshness audit; Rename31/389, refs/highlightsPASS; combined full44types610methods9144verifiesPASS. | PASS expert ses_ec5607cb7ffepnn5f6Y1vsHL5a | senior ses_ec5693c77ffeBCxRocjiILzJ6K; RenameProvider/Test; no blocker. |
| T10 | done | 3 | BuildPASS focused9types112methods673verifies full43types585methods5029verifiesPASS; clientcompile/typecheckPASS. | PASS reviewer ses_ec5607ccbffeRaSIIXQopYqA6C | implementer ses_ec5693c61ffel43q8Koxc3U85v; CodeLensProvider/Test plus narrow SymbolResolver/Test API; no blocker. |
| T11 | done | 2 | Build/full571/4795PASS; independent navigation/hierarchy focused59/233 and completion/actions42/161PASS; URI wiring inspected. | PASS reviewer ses_ec76d375bffesnXtPuPjfVSueF | provider ses_ec77a466bffe3ptiSSelTJsKIB; integration ses_ec77429e7ffeNsNgQvse1H8lzF. |
| T12 | done | 3 | All10 acceptance methodsPASS in full44types610methods9144verifiesPASS (4m40s); clientcompile/typecheckPASS. A7 real300files500messages22methods with partial-index/snapshot/compile overlap; docs updated. | PASS expert ses_ec50a0b46ffevWPs7klN9KSfer after A7/docs repairs | senior ses_ec54e48ddffe4dKvepawh1xLke; NavigationAcceptanceTest, README/CHANGELOG/PLAN; no blocker. |
| T13 | blocked | 3 | SmokeFAIL repaired: samefile highlight/nameindex/interactivecancel, dependency literal parser, quietwarmup+finalrefresh. Build/full46types643methods9604verifiesPASS1m39(tool_13cf423990016A3n7Ef7OXNFX4); clientcompile/typecheckPASS. FullC:/Code581request100sec replayPASS2924verifies p95196ms/max423ms/drain48ms/immediateprobe49ms. Bundled0.3runtime hashverified. | Automated final PASS ses_ec3230328ffeqw3Ga7p4JtHXmK; core/test PASS ses_ec35482beffejVO6Ryi9pMJLFL; deps PASS ses_ec32c50a8ffeIzCRmOK9K6zdYr | core expert ses_ec3bf39edffe8BOUyvwpkF4B30; deps senior ses_ec354830bffeDvcFt9Up05lkeT; refresh senior ses_ec35482d2ffe2B2PjioRSPHrZS; recoverytest senior ses_ec316f7e2ffe3aQJ0ZVhI6RS2C. Sole blocker user manual retry; no activewriters. |

- Baseline (T00): HEAD dbffa8d matches the plan; substantial pre-existing dirty/untracked application, tests, docs and build artifacts are input state, not delivery changes. No AGENTS.md found. All checks PASS, no pre-existing failures. Fantom 1.0.83.4006, home C:\Skyspark\skyspark-4.0.6, Java Corretto 21.0.9. Full test output: C:\Users\Francis.Mahony\.local\share\opencode\tool-output\tool_1363825300014uR27rdUuT7Q59.
- Q1 code-lens toast evidence: not yet provided by the user.
- Blocked questions: none. User approved D6 separate runtime and file-backed lookup paths; T03b repair resumes.
- Local contract choices (T00c): declaration/target kind is LSP SymbolKind Int; source is Str (semantic/heuristic/reflection); RefResult reuses Occurrence[]. SymbolKey adds localFile/localPosition parsing helpers, simpleName(localKey) returns the key (local identifier validation must use declaration text rather than this helper). These are implementation details, not product changes.
- URI detail (T01): literal percent signs retain %25 internally for idempotence and to avoid percent-encoded filename collisions; UNC authority is preserved. Review must verify this edge-case refinement.
- T04a integration contract: extract accepts explicit resolveExprComplete (default false); T04b passes true only when ResolveExpr actually ran, including its CompilerErr, never an internal crash. Extract before ClosureVars. Exact tokenized text/UTF-8 SHA-1 required; pipeline fills generation, overlay provenance/openText and parseFailedFiles. Interpolation occurrences must be indexed (not silently complete omitted references).
- Local ownership adjustment: T04b may migrate WorkspaceStateTest's obsolete CompileDiagnosticsActor structural reference/assertions to SemanticCompileActor without weakening them. T06 may fix RecoveringParser.addParamLocalDefs exact token offsets and add ParserTest regression; its parser writes do not overlap T04b. These are required integration/correctness repairs, not behavior scope changes.
- T04b cancellation follow-up owns Main.fan continuous reader/Future FIFO, server cancelledIds/cancelKey/retireCancel only, LspDispatcher protected request hook/context, new CancelDeliveryTest.fan. Reader may touch only shared ConcurrentMap cancellation tokens, never mutable analysis state. Production cancellation must be verified while ensureFresh waits, not merely pre-cancelled.
- T07b correctness refinement: reference candidate pods include transitive dependents, not just direct dependents, to satisfy A5. Constructor prefilter includes the declaring type name. Heuristic local identities must reconcile current declaration coordinates with snapshot coordinates or remain isolated from snapshot keys; no position-only aliasing. Duplicate-build uncertainty must cause safe refusal/incompleteness for rename, never merged edits presented as proven.
- Provider batch scheduling adjustment: T08–T11 initially edit disjoint providers/tests/client paths only; no worker edits FantomLanguageServer concurrently. One serialized integration owner subsequently wires all listed server methods/settings. Builds held until provider writers finish; then required focused/full/client checks and independent per-task acceptance.
- Provider writers finished: T08 ses_ec77a46b2ffe3wzesG5oZuz7QC; T09 ses_ec77a4696ffe0oEsihO7s7EP97; T10 ses_ec77a4683ffeVDvV3KdN0gAZCM; T11 ses_ec77a466bffe3ptiSSelTJsKIB. Server integration ses_ec77429e7ffeNsNgQvse1H8lzF wired requests including rename real request ID; initial build failed chained Elvis in CallHierarchyProvider. Integration owner now owns union of T08–T11 server/provider/test paths for bounded compile/test repairs; all original workers inactive. Client checks PASS; server migrations remain unverified.
- Plan review: reviewer-expert, 2026-10-13, verdict FAIL → all findings incorporated (§7.12, T03b, task amendments). Its read-only probes found:
  - installed compiler 1.0.83;
  - `Env.cur.path = [skyspark-4.0.6]` under the extension launch;
  - workspace pods built in `analytics/lib/fan` are not visible, while stale `nv5*` copies exist in `skyspark-4.0.6/lib/fan`;
  - the current overlay compile reads disk, not the buffer;
  - `sys` has an apidoc but no `src/`.
- **Next step:** Repair T08 semantic hover, T09 override-family rename safety, T10 incomplete-zero label and compact declaration coverage; then re-review/combined tests. Accepted 13/18 tasks including T11. T12 acceptance/docs and T13 final independent review/manual smoke follow. User requested visible todo list; keep tool todos synchronized with this ledger.

### Resumption notes
- Reconciled 2026-10-14: HEAD dbffa8d; substantial dirty/untracked input preserved; no AGENTS.md found, CONTRIBUTING.md read. Latest prior build/full: 43 types/571 methods/4795 verifies PASS, focused providers/session 11 types/106 methods/405 verifies PASS, client compile/typecheck PASS. Thirteen tasks accepted. T08/T09/T10 focused repairs now implemented by sessions in ledger, no active writers; serialized build/tests and fresh independent reviews next. T12 acceptance/docs then T13 final review; manual smoke remains user-dependent and unchecked. No commits/reset/revert.
- T10 local ownership adjustment: additive read-only SymbolResolver.fileDeclarations and focused resolver tests authorized to expose freshly mapped snapshot declarations without server-wiring changes or parser rewrites. D6 remains binding.
- Latest 2026-10-14 batch: build/focused9types112methods673/full43types585methods5029 PASS (tool_13a9f3f57001t0274Tf20qvQ5j, tool_13aa06f2f0015akCQdCpYk4r0i); client compile/typecheck PASS. T10 independently accepted (14/18). T08 compact signature and T09 inherited mixin repairs implemented, T12 tests/docs implemented; no active writers; next build and reviews. T09 uses approved conservative refusal, including owners with any workspace subtype and unavailable hierarchy coverage; does not expand family rename scope.
- Constructor integration repair accepted by expert ses_ec5206589ffe6zAo6VQOf5Y5sI: cross-pod explicit constructor key/alias spelling fixed in SemanticIndexer and SymbolResolver plus tests by expert ses_ec541dac1ffeC2ZfHrAP0sYV53. BuildPASS SemanticIndexer16/723 Resolver13/140 and related focused suites; prior T04a/T07b acceptance retained after review. No workspace JVM loading.
- Current next step: final full suite with extended timeout (prior120sec timeout was duration, not test failure; current A7 alone takes190sec), client checks; fresh heritage algorithm review and T12 re-review, then T13 final integration review. No active writers. Accepted14/18 until remaining full/review gates pass; manual smoke unchecked. Shared latest build includes all repairs; preserve original dirty state.
- Latest authoritative state: 17/18 accepted; T08/T09/T12 marked done only after independent PASS plus full suite PASS44types610methods9144verifies (4m40s, tool_13b3139ef0014lI7RD9nuTw5JZ); npm run compile and npx tsc --noEmit -p . PASS. All source writers inactive. Next T13 fresh full-diff/invariants integration review; do not rerun unchanged expensive suite for ceremony. Manual smoke remains user-dependent; T13 stays unchecked until user confirms.
- T13 final review reopened combined integration gate (not prior correctness claims): large-file per-occurrence text/mapping work caused dispatch starvation. Expert ses_ec4a2f1b8ffeLXrFUsnJZ35u7A implemented request-scoped bounded caches, binary line selection, name-prefiltered500-cap hierarchy fallback, rebuild-invalidated registry metadata caches, and cancellation for references/lenses/call hierarchy using actual JSON-RPC IDs. New ResolverPerformanceTest and production midrequest cancellation tests PASS; fresh independent review/full required before automated acceptance. Common-name heuristic references remain bounded500 and cancellable (about10s real worst probe), no cap policy change. Packaging prerequisite: client/server pod stale; refresh bundled runtime before user F5/VSIX smoke. No commits; no source writers active.
- **FINAL RESUMPTION STATE (supersedes all earlier next-step notes): automated delivery accepted,17/18 checkboxes complete. T13 automated final expert PASS; sole outstanding criterion is actual user smoke confirmation.** Latest full45types617methods9354verifiesPASS1m25sec, buildPASS, client compile/typecheckPASS; evidence tool_13ba72223001PuvsbtaFNToxto. No active agents/writers. No commits/push/reset/revert. Bundled client/server runtime refreshed and independently hash-verified against server/lib/fan: SHA256998B69FFEA1E2C74E3801594D9D552CD3552B116B9ECA3A5FA28589A65A26E7F. Existing VSIX remains old; use F5 after restarting prior development server, or rebuild VSIX via scripts/build.bat.
- Manual instructions: launch refreshed F5 extension on real workspace; verify no startup code-lens toasts, F12 on previously wrong calls, lens click references peek and zero plain label, collision rename precise or clear safe refusal, codeLens.enabled=false removes lenses, completion/hover responsive. Record user's actual results before checking T13. Known nonblocking limits: very common-name fallback references can take~11s (500cap/cancellable); conservative slot rename rejects any workspace subtype or incomplete whole-workspace hierarchy; fallback imports with no workspace source can still consult installed Pod.find copies; old VSIX not refreshed. No manual success claimed.
- User requested minor release bump after first F5 reported0.2.0: client/server now0.3.0; serverInfo derives actual pod version. Author implementer ses_ec3c6d81affeA5Dz7iKfXf49mY, independent reviewer ses_ec3c581efffeOVn0JcVvMbT7f3 PASS. BuildPASS LspSession8methods30verifiesPASS clientcompile/typecheckPASS; no full suite rerun for mechanical metadata change. Bundled/source/installed0.3.0 pod SHA256 EBCFCA51D6B8A0A3EB7875FFD286CCBAB8D42727EEA85239FF19CB5517E6E98A (supersedes prior deployment hash). Launch schema0.2.0 and JSON-RPC2.0 unchanged. Existing VSIX remains old; restart F5 to see0.3.0. User has not confirmed smoke criteria; T13 still unchecked. Same-ID installed extension normally replaced by development extension in F5 host; disabling installed copy in test workspace is optional isolation, other competing Fantom extensions should be disabled there.
- **CURRENT STATE supersedes FINAL notes above: user smoke FAILED; T13 reopened.** Full C:/Code workspace173pods/2034files differs from prior small nv5Ai probes. User log confirms repeated hover/cancellation/highlight and refresh cycles plus Invalid Depend ext.depends/metadata strings. Expert diagnosis/implementation ses_ec3bf39edffe8BOUyvwpkF4B30: file-scoped highlight/linked refs, indexed name lookups, per-resolution caches, lexical function-type arrow disambiguation, real-ID interactive cancellation; focused suitesPASS plus production-loop realworkspace581requests100sec replayPASS(p95182ms/max399ms/recovery0ms) during174warmupcompiles. Await independent review/full. New InteractiveRecoveryTest real fixture machine-specific; default test policy to reconcile. No real workspace writes or processkills. Bundled F5 pod NOT refreshed since new repairs; do not claim deployed yet.
- Scout ses_ec39d44dfffeYVNRhjnmgvaQEq: CompilerDiagnostics substring depends parser enters meta ext.depends and consumes NV5/Commercial/etc as dependencies. Repair actual static depends assignment with token/comment awareness; preserve macro handling and existing sys fallback for unsupported dynamic expressions (no build-script execution). Refresh choice should avoid unrelated warmup snapshots while keeping explicit/open-document updates; ownership serialized after interactive handler writer completed. Next review R1-R3, implement dependency/refresh repairs, combined sustained/full/client checks, refresh bundled runtime, user retry. Preserve dirty baseline and D6.
- **LATEST RESUMPTION (supersedes prior next steps): automated repairs complete; wait for user F5 retry, T13 remains unchecked.** Samefile highlighting no global filesystem scan; indexed names/percall heuristic caches; functiontype arrow lexicalfix; actual-ID interactive cancellation. Metadata ext.depends no longer parsed as compiler deps; this.depends and typed Str/sys::Str literal lists/macros supported, dynamic fallback unchanged. Unrelated warmup quiet; relevant updates plus one final completion refresh retained. All slices independently PASS and combined automated final PASS ses_ec3230328ffeqw3Ga7p4JtHXmK. Full46types643methods9604verifiesPASS1m39; client0.3compile/typecheckPASS. Optin realfullC:/Code581requests100sec during174compiles: p95196ms max423ms13afterstartcancelsnone>100ms drain48ms immediateprobe49ms,2924verifiesPASS. Recovery test now requires FANTOM_LSP_RECOVERY_ROOT=C:/Code/ and FANTOM_LSP_RECOVERY_FILE=C:/Code/monoRepos/analytics/src/conn/nv5Ai/fan/core/Nv5AiFuncs.fan; defaults explicit skip. Old smallworkspace evidence never overrides user failure.
- Bundled F5 runtime refreshed by ses_ec4596ad9ffeTLMou1LCcgceO8 and coordinator hashes independently matched: source/bundle/installed SHA256085E332A13FB6D21CB055B3D18E966A690DC5EC4C842543878256D4FD39F2139, version0.3.0. No sourcewriter active, no commits/push/reset/revert. Ask user stop old F5 and restart then repeat hover/clicks fullworkspace; no success claimed until actual confirmation. Existing VSIX remains old. Nonblocking knowns: cancellation burst assertion primarily latency/source proof rather than deterministic null for every interactive method; lastdocclose finalrefresh epoch invalidates nextidle<=200ms; watchedmanyfilechange refreshes still throttled1sec; realfixture tests optin. Preserve original dirtywork.
- Start a new conversation with the coordinator and give it this file path. Run tasks in dependency order, mark `[x]` only after independent review passes, and record evidence in §10.
- If T04a finds that the installed compiler lacks a needed API (R1), record which occurrence classes are skipped. Those cases go through T06's heuristic; do not block the rest of the plan.
- If T04b cannot override `frontend` (AS4), use the documented fallback and note in §10 that closure-captured locals use the heuristic.
- If the T02 stress test is flaky, treat that as a real defect, not a test problem.
