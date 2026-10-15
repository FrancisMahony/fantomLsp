# Changelog

All notable user-visible changes to this extension are documented here.

## 0.3.0 (unreleased)

The headline change: navigation now follows the Fantom compiler. In 0.2.0, symbols were matched by name, so a click could land on a same-named method in an unrelated type or pod. 0.3.0 uses the compiler's resolution of each name, and when it can't be sure it shows a ranked list instead of guessing.

### Symbol resolution

- **Compiler-backed navigation.** Go to Definition, Declaration, Type Definition, Implementation, Hover, Signature Help, References, Rename, Document Highlight, Linked Editing, Code Lens and Call/Type Hierarchy now share one resolver. Each pod is compiled in the background, including unsaved editor changes, and every reference is bound to the declaration the compiler chose: the right slot, on the right type, in the right pod.
- **No more arbitrary jumps.** Dynamic `->` calls, unparseable files, unknown receivers and recently edited lines use a scope-aware fallback. It returns a deterministic ranked list or nothing.
- **Locals stay in scope.** Locals and parameters resolve only within their method or closure.
- **References and highlights are exact.** They include only occurrences bound to the same symbol, not every matching word.
- **Safer rename.** Rename refuses, with an explanation, when it can't prove the edit is complete and safe. This includes slots that are part of a virtual, override or mixin family, and slots whose type has workspace subtypes. Locals and parameters are renamed only within their scope.
- **Source for installed pods.** Go to Definition into an installed pod opens the source packed in that pod, at the exact line recorded by the compiler. If there's no source, it returns nothing rather than opening the wrong file.

### Workspace pods

- **Current builds are used.** The server now reads your workspace's built pods (auto-detected `lib/fan` folders plus the new `fantom.envPath` setting) in preference to older copies in the Fantom or SkySpark installation.
- **No restart after rebuilding.** Rebuilt pods are picked up automatically, and the JVM no longer locks workspace pod files.

### Code lens

- **Reference counts** are computed lazily and are precise.
- **Clicking a count** opens the references peek.
- **`N+`** means some pods haven't been analysed yet.
- **Setting:** `fantom.codeLens.enabled` (default `true`).
- **Fixed:** intermittent "Request textDocument/codeLens failed" notifications, which were caused by a threading bug.

### Diagnostics

- Compiler diagnostics now compile unsaved changes in every open file of the pod, and cover all `srcDirs`, including test directories.
- Compiler errors are matched to files by full path, so errors from a same-named file in another directory no longer leak in.
- Compiler diagnostics are no longer cleared by typing on unrelated lines.

### Reliability and performance

- **Thread safety.** All analysis state is owned by a single thread, which removes the internal errors seen during indexing.
- **Cancellation.** Long requests (references, code lens, call hierarchy) respond to cancellation and stay responsive in large workspaces.
- **No duplicate indexing on Windows.** A file is no longer indexed twice under different URI spellings (`c%3A` vs `C:`).

### Project

- **Open source under the MIT License.** The source is at <https://github.com/FrancisMahony/fantomLsp>.

### Settings

- New `fantom.envPath`: extra directories containing built workspace pods.
- New `fantom.codeLens.enabled`: show or hide reference-count lenses.
- New `fantom.semanticIndex.backgroundCompile`: analyse workspace pods in the background after indexing (default `true`).
- `fantom.trace.server` now actually enables LSP message tracing.
- Changing `fantom.home`, `fantom.javaOpts`, `fantom.maxFiles` or `fantom.excludeDirs` now offers to reload the window. The previous **Restart** button kept the old values.

## 0.2.0

- **Workspace indexing.** Discovers pods by `build.fan` anywhere under the workspace, so large multi-repo folders work. New `fantom.maxFiles` setting (default unlimited).
- **Cross-file intelligence.** Hover, completion and definition use the whole workspace, not just the current file.
- **Background work.** Indexing and compiler diagnostics run off the request thread.
- **Diagnostics.** Parser diagnostics on change, compiler diagnostics on open and save. Unused-local warnings. Nested `srcDirs` are compiled.
- **New features.**
  - Call and type hierarchy.
  - Inlay hints for inferred locals.
  - Document highlights, folding ranges, selection ranges, linked editing.
  - Document links on `using`.
  - Go to Declaration.
  - Range formatting and on-type indent.
  - Completion snippets with parameter placeholders, auto-added `using`, and documentation on resolve.
  - Semantic tokens for references and ranges.
  - Organize-usings code action.
  - Status-bar restart.
- **Editor integration.** Watched-file changes update the index; `.fwt` files are indexed.
- **Correctness.** CRLF line endings are preserved. Windows `file:///c%3A/...` URIs are decoded correctly. Go to Definition no longer fails for slots.

## 0.1.1

- **Triple-quoted strings.** Multiline `"""` string content is indented to align with the opening quotes.
- **List and map literals.** Items inside `[...]` are indented one level deeper than the opening bracket.
- **Allman braces by default**, matching the convention used by Fantom's creators. The `preserve` option was removed; choose `allman` or `k&r`.

## 0.1.0

Initial release: hover, go to definition, find references, rename, completion, signature help, document and workspace symbols, parser and compiler diagnostics, code actions, formatting, semantic tokens and call hierarchy.
