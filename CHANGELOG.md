# Changelog

## 0.3.0 Unreleased

### Symbol-resolution correctness

- Shared compiler-backed resolution for navigation, hover/signature help, references, rename, highlights, linked editing, and call/type hierarchies; collision-safe declaring-pod/type/slot identities and scope-bounded locals.
- Deterministically ranked fallback navigation for unknown/dynamic receivers and edited or unparseable regions; no arbitrary name-only jump. Rename refuses unproven/incomplete/external targets and virtual/override/abstract/mixin slot families. Slot rename also refuses any workspace subtype of its owner (even nonvirtual), and requires fresh, resolved, nonduplicate whole-workspace coverage; unrelated stale pods can block it. Preparation never compiles, and reference refresh alone may not restore hierarchy coverage when background warm-up is disabled.
- Lazy `codeLens/resolve` reference counts with clickable references peek, incomplete-coverage `N+` labels, and `fantom.codeLens.enabled` (default true).
- `fantom.semanticIndex.backgroundCompile` (default true) controls post-index warm-up; open/save compiles use real open-buffer overlays and configured test source directories.
- `fantom.envPath` and auto-detected workspace roots use a file-backed compiler namespace separate from JVM runtime lookup (D6), so rebuilt workspace dependencies can reload without restart.
- Canonical Windows file identities preserve client URI encodings in locations/edits and avoid duplicate physical indexing. Background producers publish immutable results to the dispatch-thread mailbox.
- Protocol acceptance coverage in `NavigationAcceptanceTest` for A1–A8, including real two-pod initialization/open/save lifecycle and a 300-file/500-message mixed-feature stress test with real lens/hierarchy items, successful scoped-local renames, and separately asserted unsafe-rename refusals.

Earlier 0.2.0 implementation notes below are historical; the symbol-resolution behavior above supersedes name-based navigation and implementer-count lens descriptions.

- **Stdio write actor** — JSON-RPC writes serialized on `StdioWriteActor`; idle compiler diagnostics can flush without waiting on the next request.
- **`fantom.maxFiles`** — index file cap; default `0` (unlimited). Heap via `fantom.javaOpts`.
- **Workspace index** — discovers pods by `build.fan` under the workspace (large folders like `C:\Code` work).
- **URI `%3A`** — Windows `file:///c%3A/...` folders decode so indexing and `build.fan` compile succeed.
- **Parser** — facet classes, closures, and static blocks parse more reliably (nested types still line-oriented).
- **Go to Definition** — fixed slot/type lookup (closure return bug); jump into compiled pod `src` when available.
- **Diagnostics split** — parser diagnostics on change; compiler diagnostics on open/save (async actor).
- **CRLF** — document model preserves `\r\n`; offsets stay aligned with the editor.
- **Watched files** — `workspace/didChangeWatchedFiles` indexes add/remove; `.fwt` indexed with `.fan`.
- **Cross-file intelligence** — hover, completion, and definition use the workspace `SymbolTable`.
- **Call hierarchy** — incoming/outgoing from `bodyCallRefs`.
- **Inlay hints** — inferred types (not fields).
- **Document highlights** and **folding ranges**.
- **Async index/compile** — workspace index and compiler diagnostics run off the request loop; compile notifications write via `StdioWriteActor`.
- **Rename** — in-file locals/params; qualified type/slot rename with dedupe.
- **Semantic tokens** for references; completion snippets and `using` additionalTextEdits.
- **Compiler `srcDirs`** recurse nested directories.
- **Mixins** — implementation lookup for mixin implementers.
- **Code lens** — mixin implementer counts and similar inline hints.
- **Linked editing** — matching identifiers in the current file.
- **Selection range** — expand/shrink selection by AST nesting.
- **Preferred-uri definition** — `findType` / `findSlot` prefer the current file on duplicate names.
- **Param `localDefs`** — method parameters recorded as local defs for in-scope rename/completion.
- **Nested types** — parser/index support for types nested in other types.
- **Method locals** — improved local variable capture for completion, rename, and highlights.
- **Organize usings** — code action to sort and clean `using` statements.
- **Type hierarchy** — supertypes and subtypes for classes and mixins.
- **Go to Declaration** — jump to declarations (alongside Go to Definition).
- **Status bar restart** — restart the language server from the status bar.
- **Semantic highlighting defaults** — `configurationDefaults` enable editor semantic highlighting for Fantom.
- **Unused local warnings** — diagnostics for unused locals in addition to unused usings.
- **Range formatting** — format a selection, not only the whole file.
- **On-type indent** — indent on `}` while typing.
- **Document links** — `using` statements link to source when `src` is available.
- **Completion resolve docs** — `completionItem/resolve` fills documentation on accept/hover of an item.
- **Semantic tokens range** — `semanticTokens/range` in addition to full-document tokens.
- **Multi-root folder preference** — workspace folders prefer the current root when resolving types/slots.

## 0.1.1

### Formatting improvements

- **Triple-quoted strings**: multiline `"""` string content is now indented so the first character aligns with the column after the opening triple quotes.
- **List literal indentation**: items inside `[...]` list and map literals are indented one level deeper than the opening bracket.
- **Allman is now the default bracket style**, matching the convention used by the Fantom language creator. The `preserve` option has been removed; choose `allman` or `k&r`.

## 0.1.0

Initial release.

- Hover, Go to Definition, Find References, Rename Symbol
- Completion with dot-completion, using-completion, and keyword/type completion
- Signature Help with active parameter highlighting
- Document Symbols and Workspace Symbol Search
- Diagnostics from the recovering parser and the Fantom compiler
- Code Actions: add missing using, remove unused using, uncomment line
- Code Formatting with bracket style configuration
- Semantic Tokens for rich syntax highlighting
- Call Hierarchy (incoming and outgoing calls)
