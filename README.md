# Fantom Language Support

Rich language support for [Fantom](https://fantom.org) in Visual Studio Code, powered by a full Language Server Protocol implementation.

## Features

### Code Intelligence

- **Hover** -- type signatures, documentation, and constructor details for types and slots from your code and compiled pods.
- **Go to Definition** -- compiler-backed bindings distinguish same-named types and slots, typed/inferred receivers, inheritance, chained calls, closures, and it-blocks. Cross-pod calls open workspace source; installed pods open source when available.
- **Go to Declaration** -- jump to the declaration of a type or slot.
- **Find References** -- find occurrences bound to the same symbol, not every matching name. Locals and parameters stay within their declaring scope.
- **Rename Symbol** -- precise workspace edits for proven bindings; unsafe, external, ambiguous, or incomplete targets are refused with an explanation.
- **Call Hierarchy** -- browse incoming and outgoing calls for any method or constructor.
- **Type Hierarchy** -- browse supertypes and subtypes for classes and mixins.

### Editing

- **Completion** -- context-aware autocomplete: pod names in `using` statements, dot-completion on receivers, keywords, method locals, and types (including nested types). Method snippets include parameter placeholders. Missing usings can be added via auto-import on accept. Resolve fills documentation.
- **Signature Help** -- parameter hints while typing function calls, with the active parameter highlighted.
- **Code Actions** -- quick fixes including *Add missing using*, *Remove unused using*, *Organize usings*, and *Uncomment line*.
- **On-type indent** -- indent when you type `}`.
- **Document links** -- `using` statements link to source when `src` is available.

### Navigation

- **Document Symbols** -- outline and breadcrumb navigation for the current file.
- **Workspace Symbol Search** -- `Ctrl+T` fuzzy search across all indexed symbols.
- **Document Highlights** -- highlight other occurrences of the symbol under the cursor.
- **Folding Ranges** -- fold types, methods, and comment blocks.
- **Selection Range** -- expand/shrink selection by AST nesting.
- **Linked Editing** -- edit same-symbol occurrences together in the current file, excluding unrelated matching names.
- **Code Lens** -- lazy, precise reference counts on methods, constructors, and fields. Click a nonzero count to open the references peek; `N+ references` means coverage is incomplete.
- **Inlay Hints** -- inferred types for local variables.

### Diagnostics

- **Real-time parser errors** on every keystroke.
- **Compiler diagnostics** on open/save, with automatic cross-file refresh (including configured `test/` source directories). Background semantic warm-up follows workspace indexing.
- **Unused local warnings** in addition to unused usings.

### Formatting

- Full-file and **range** formatting with **Allman** (default) or **K&R** bracket style.
- Correctly handles triple-quoted multiline strings and list literal indentation.
- Respects your editor tab size and spaces/tabs preference.

### Syntax Highlighting

- Semantic token support that goes beyond the bundled TextMate grammar, distinguishing classes, methods, fields, enums, and mixins with modifiers like `declaration`, `readonly`, `static`, and `abstract`. Full document and **range** tokens.
- VS Code `configurationDefaults` enable editor semantic highlighting for Fantom.

### Server control

- **Status bar restart** -- restart the language server from the status bar without reloading the window.

## Getting Started

### Prerequisites

- **Java 11+** on your `PATH`.
- **Fantom** or **[SkySpark](https://skyfoundry.com/product)** installed locally.

### Setup

1. Install the extension from the Marketplace.
2. Open **Settings** (`Ctrl+,`) and set `fantom.home` to your Fantom or SkySpark installation directory (e.g. `C:\Skyspark\skyspark-4.0.5`). If you already have the `FAN_HOME` environment variable set, you can skip this step.
3. Open a `.fan` file. The language server starts automatically.

## Settings

### Running without VS Code

Build the server from the `server` directory with `fan build.fan`.
Run it over standard input/output with `fan fantomLsp::Main`.
The process speaks JSON-RPC using the LSP stdio transport.
This is useful for protocol-level testing and other LSP clients.

| Setting | Default | Description |
|---|---|---|
| `fantom.home` | `""` | Path to the Fantom / SkySpark installation directory. Falls back to the `FAN_HOME` environment variable. |
| `fantom.javaOpts` | `"-Xmx1024m"` | JVM options for the language server. Increase `-Xmx` for large codebases. |
| `fantom.maxFiles` | `0` | Max `.fan` files to index. `0` = no limit. |
| `fantom.excludeDirs` | `.git`, `node_modules`, `lib`, … | Directory **names** skipped while discovering pods / sources. |
| `fantom.envPath` | `[]` | Additional environment roots containing `lib/fan` workspace/dependency builds. Workspace roots are also auto-detected. These are file-backed lookup roots, not JVM runtime paths. |
| `fantom.codeLens.enabled` | `true` | Show lazy reference-count lenses; can be changed without restarting. |
| `fantom.semanticIndex.backgroundCompile` | `true` | Warm up semantic indexes after workspace indexing. Disabling this does not disable open/save compilation. |
| `fantom.formatting.bracketStyle` | `"allman"` | `"allman"` places braces on a new line. `"k&r"` places braces on the same line. |
| `fantom.trace.server` | `"off"` | LSP message tracing for debugging: `"off"`, `"messages"`, or `"verbose"`. |

## Troubleshooting

### The extension does not start

1. Verify `fantom.home` points to a valid installation containing `lib/java/sys.jar`.
2. Confirm Java is available: run `java -version` in a terminal.
3. Check the **Fantom LSP Launch** output channel (`View > Output`, then select **Fantom LSP Launch**) for the exact command that was attempted.

### No completions or hover information

- Wait a few seconds after opening a `.fan` file for workspace indexing to finish.
- For large projects, increase memory: set `fantom.javaOpts` to `"-Xmx2048m"` or higher.
- Check the **Fantom Language Server** output channel for errors.
- Build/install dependency pods before expecting exact cross-pod resolution. Use `fantom.envPath` for additional roots containing their `lib/fan` builds.
- Workspace/configured lookup roots are separate from the JVM runtime path: current workspace `.pod` files are read by the compiler namespace, not loaded into the JVM. Rebuilt dependencies are picked up on subsequent lookup/compile without a server restart or workspace-pod JVM file locks. `fantom.home` / `FAN_HOME` locate the installed runtime; the extension's server and installed runtime remain on the runtime path (D6).

### Diagnostics are missing or stale

- Compiler diagnostics refresh on **save**. Parser diagnostics update on every keystroke.

### Formatting produces unexpected results

- Check that `fantom.formatting.bracketStyle` matches your preference.
- The formatter uses your editor's **Tab Size** and **Insert Spaces** settings.

### High memory usage or crashes

- Increase the heap: set `fantom.javaOpts` to `"-Xmx2048m"`.
- Enable `fantom.trace.server` at `"verbose"` to capture logs, then file an issue.

## Known Limitations

- **Fallback resolution** uses the recovering parser for dynamic `->` calls, unparseable files, unknown receivers, and regions edited since the last compile. Results are a deterministic ranked peek list or nothing, never an arbitrary first match. Unchanged lines can still use the last compiler bindings; compilation is not performed on every keystroke.
- **Unbuilt dependencies** can prevent compiler name resolution. Build/install them on the workspace lookup path; fallback navigation and reference coverage may be incomplete until then.
- **Rename** requires a proven workspace binding and complete semantic coverage (refreshing stale pods with a bounded wait). Locals/parameters remain scope-bounded. Virtual, abstract, override, and mixin slot families are conservatively refused: exact-key edits do not safely maintain dispatch families. Constructor shorthand is not a supported slot rename token.
- **Slot rename is deliberately conservative:** any workspace subtype of the declaring type blocks it, even for a nonvirtual slot and a subtype unrelated to a mixin. The subtype audit requires current coverage of the entire workspace: an unrelated pod with a stale/unresolved/missing snapshot, duplicate pod names, or a source-file hash mismatch can block all slot renames. `prepareRename` never compiles. Rename's reference refresh is bounded and does not guarantee whole-workspace hierarchy coverage; with `fantom.semanticIndex.backgroundCompile=false`, unrelated unopened pods may remain unavailable despite reference refresh. Open/save those pods or re-enable warm-up, then retry. Local rename does not require this global subtype audit.
- **Installed source** may be absent. Definition then returns nothing, while hover can still show the installed signature/documentation.
- **Compiler type-token coverage** varies with compiler APIs; type positions without source locations (such as some local/generic type annotations) use the scope-aware fallback. Completion and semantic tokens continue to use the recovering-parser indexes.
- **Inlay hints** cover inferred locals, not fields.
- **Request cancel** (`$/cancelRequest`) is best-effort (tracked ids only).
- **Compiler diagnostics** are computed asynchronously after open/save. Indexing walks folders that contain `build.fan` (works with a large multi-repo workspace).

## License

Free to use. Source code is proprietary. See the LICENSE file included with the extension for details.
