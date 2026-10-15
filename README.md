# Fantom Language Support

Language support for [Fantom](https://fantom.org) in Visual Studio Code, backed by a language server that uses the real Fantom compiler to work out what each name in your code refers to.

## Features

### Navigation that follows the compiler

When two pods or types declare the same name (`close()`, `make`, `Foo`), **Go to Definition** goes to the declaration the Fantom compiler actually binds to. This takes into account:
- typed and inferred receivers;
- inheritance and `super`;
- `using` imports and aliases;
- chained calls, closures and it-blocks.

If the target can't be proven (for example a dynamic `->` call, or code you're in the middle of editing), you get a ranked list to choose from rather than a guess.

- **Go to Definition / Declaration / Type Definition / Implementation.** Calls into other workspace pods open their source. Calls into installed pods open the source packed in the pod, when it's available.
- **Find References, Document Highlight, Linked Editing.** Only occurrences bound to the same symbol, not every word with the same spelling. Locals and parameters stay within their scope.
- **Rename Symbol.** Precise workspace edits. Renames that can't be proven safe are refused with an explanation.
- **Call Hierarchy and Type Hierarchy.** Incoming/outgoing calls, supertypes and subtypes.
- **Code Lens.** Reference counts on methods, constructors and fields. Click a count to open the references peek. `N+` means some pods haven't been analysed yet.
- **Document Symbols and Workspace Symbol Search** (`Ctrl+T`).

### Editing

- **Completion.** `using` pod and type names, dot-completion on receivers, locals, keywords and types. Method snippets include parameter placeholders. Accepting a type from another pod adds the missing `using`.
- **Hover and Signature Help.** Signatures and documentation, with the active parameter highlighted.
- **Code Actions.** Add missing using, remove unused using, organize usings, uncomment line.
- **Formatting.** Whole document, selection, and on-type indent after `}`. Allman (default) or K&R braces. Handles triple-quoted strings and list literals, and respects your tab settings.
- **Inlay Hints** for inferred local types, **Folding**, **Selection Range**, and **Document Links** on `using` statements.

### Diagnostics

- Parser errors as you type.
- Compiler errors on open and save, covering every source directory in `build.fan` (including tests). Pods are also analysed in the background after the workspace is indexed.
- Warnings for unused locals and unused usings.

### Syntax highlighting

A TextMate grammar, plus semantic tokens that tell classes, mixins, enums, methods and fields apart.

## Getting started

### Requirements

- Java 11 or later, on your `PATH` or set via `JAVA_HOME`.
- A Fantom or [SkySpark](https://skyfoundry.com/product) installation.

### Setup

1. Install the extension.
2. If the `FAN_HOME` environment variable isn't set, open **Settings** (`Ctrl+,`) and set **`fantom.home`** to your Fantom or SkySpark installation directory (for example `C:\SkySpark\skyspark-4.0.6`).
3. Open a folder containing Fantom code and open a `.fan` file. The language server starts automatically, and **Fantom LS** appears in the status bar. Click it to restart the server.

### Getting accurate cross-pod results

The server compiles each pod separately, the same way `fan build.fan` does. When it compiles pod `A`, it reads the pods `A` depends on from their **built `.pod` files**. So that it reads your current builds rather than older copies in the Fantom installation:

- Build your workspace pods as usual, so their `.pod` files end up in `<root>/lib/fan/`.
- `<root>` is found automatically if it's a workspace folder or one of its three nearest parent folders, and it contains `lib/fan/*.pod` or `fan.props`. Folders *below* a workspace folder aren't searched.
- Otherwise, add `<root>` (the folder that contains `lib`, not `lib/fan` itself) to **`fantom.envPath`**. For example, for pods in `D:\work\output\lib\fan\`, add `D:\work\output`.

Rebuilt pods are picked up without restarting the server. Your workspace **source** is always what you navigate to and what hover shows. After changing a pod's public API, rebuild it so the pods that depend on it see the change.

To see which installation and lookup roots are in use, open **View → Output** and select **Fantom LSP Launch**.

## Settings

| Setting | Default | Description |
|---|---|---|
| `fantom.home` | `""` | Fantom or SkySpark installation directory. Falls back to the `FAN_HOME` environment variable. |
| `fantom.envPath` | `[]` | Extra absolute root directories whose `lib/fan` contains your built workspace pods. Workspace folders and their three nearest parents are checked automatically. |
| `fantom.javaOpts` | `"-Xmx1024m"` | JVM options for the server. Increase `-Xmx` for large workspaces. |
| `fantom.maxFiles` | `0` | Maximum number of `.fan` files to index per pod. `0` means no limit. |
| `fantom.excludeDirs` | `.git`, `node_modules`, `lib`, … | Directory names skipped while indexing. |
| `fantom.codeLens.enabled` | `true` | Show reference-count code lenses. |
| `fantom.semanticIndex.backgroundCompile` | `true` | Analyse workspace pods in the background after indexing. Open and saved files are always analysed. |
| `fantom.formatting.bracketStyle` | `"allman"` | `"allman"` puts braces on a new line, `"k&r"` on the same line. |
| `fantom.trace.server` | `"off"` | Log LSP traffic to the output channel: `"off"`, `"messages"` or `"verbose"`. |

`fantom.home`, `fantom.javaOpts`, `fantom.maxFiles` and `fantom.excludeDirs` take effect after you reload the window; changing any of them offers a **Reload Window** button. Other settings apply immediately.

## Troubleshooting

**The server doesn't start**
- Check that `fantom.home` (or `FAN_HOME`) points to an installation containing `lib/java/sys.jar`.
- Run `java -version` to confirm Java is available.
- Open the **Fantom LSP Launch** output channel to see the exact command that was run.

**Navigation goes to an old version of a library, or cross-pod calls aren't resolved**
- Make sure the dependency is built, and that the root folder containing its `lib/fan` appears under "detected lookup roots" or "configured lookup roots" in **Fantom LSP Launch**. If it doesn't, add that root to `fantom.envPath`.

**No completions or hover yet**
- Indexing a large workspace takes a few seconds after startup.
- For very large workspaces, raise the heap, e.g. `"fantom.javaOpts": "-Xmx2048m"`.
- Check the **Fantom Language Server** output channel for errors.

**Rename is refused**
- The message says why. Usually a pod that might reference the symbol doesn't currently compile, or the slot is overridden or overridable. Fix the compile error (or save the file) and try again.

**Reporting a problem**
- Set `fantom.trace.server` to `"verbose"`, reproduce the problem, and include the **Fantom Language Server** output with your report.

## Known limitations

- **Code that can't be proven.** Dynamic `->` calls, files that don't parse, and lines edited since the last compile use a scope-aware fallback. It returns a single result only when there's exactly one candidate, otherwise a ranked list or nothing.
- **Unbuilt dependencies.** A pod whose dependencies aren't built, or are out of date, may not get compiler-proven results. Navigation still works through the fallback.
- **Rename is deliberately conservative.**
  - Slots that are virtual, abstract, overridden or part of a mixin are refused.
  - So is any slot whose type has a subtype in the workspace.
  - Every workspace pod must currently compile.
  - Locals and parameters can always be renamed within their scope.
- **Installed pods without packaged source.** Go to Definition returns nothing; hover still shows the signature and documentation.
- **Some type positions.** A few, such as some local and generic type annotations, aren't located by the compiler and use the fallback.
- **Completion and semantic tokens** use the fast recovering parser, not the compiler index.
- **Inlay hints** cover inferred locals only.

## Using another editor

The server is a standard LSP server over stdio. Build it with `fan build.fan` in `server/`, then run `fan fantomLsp::Main` from any LSP client.

## Contributing

Bug reports and pull requests are welcome on [GitHub](https://github.com/FrancisMahony/fantomLsp/issues). See [CONTRIBUTING.md](CONTRIBUTING.md) for building and testing, and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how the server works.

## License

[MIT](LICENSE)
