# Fantom Language Support

Rich language support for [Fantom](https://fantom.org) in Visual Studio Code, powered by a full Language Server Protocol implementation.

## Features

### Code Intelligence

- **Hover** -- type signatures, documentation, and constructor details for types and slots from your code and compiled pods.
- **Go to Definition** -- jump to the definition of any type, field, or method across your workspace.
- **Find References** -- locate every usage of a symbol throughout the project.
- **Rename Symbol** -- rename types, fields, and methods across all files at once.
- **Call Hierarchy** -- browse incoming and outgoing calls for any method or constructor.

### Editing

- **Completion** -- context-aware autocomplete: pod names in `using` statements, dot-completion on receivers, keywords, local variables, and types. Method snippets include parameter placeholders.
- **Signature Help** -- parameter hints while typing function calls, with the active parameter highlighted.
- **Code Actions** -- quick fixes including *Add missing using*, *Remove unused using*, and *Uncomment line*.

### Navigation

- **Document Symbols** -- outline and breadcrumb navigation for the current file.
- **Workspace Symbol Search** -- `Ctrl+T` fuzzy search across all indexed symbols.

### Diagnostics

- **Real-time parser errors** on every keystroke.
- **Compiler diagnostics** on save, with automatic cross-file refresh.

### Formatting

- Full-file code formatting with **Allman** (default) or **K&R** bracket style.
- Correctly handles triple-quoted multiline strings and list literal indentation.
- Respects your editor tab size and spaces/tabs preference.

### Syntax Highlighting

- Semantic token support that goes beyond the bundled TextMate grammar, distinguishing classes, methods, fields, enums, and mixins with modifiers like `declaration`, `readonly`, `static`, and `abstract`.

## Getting Started

### Prerequisites

- **Java 11+** on your `PATH`.
- **Fantom** or **[SkySpark](https://skyfoundry.com/product)** installed locally.

### Setup

1. Install the extension from the Marketplace.
2. Open **Settings** (`Ctrl+,`) and set `fantom.home` to your Fantom or SkySpark installation directory (e.g. `C:\Skyspark\skyspark-4.0.5`). If you already have the `FAN_HOME` environment variable set, you can skip this step.
3. Open a `.fan` file. The language server starts automatically.

## Settings

| Setting | Default | Description |
|---|---|---|
| `fantom.home` | `""` | Path to the Fantom / SkySpark installation directory. Falls back to the `FAN_HOME` environment variable. |
| `fantom.javaOpts` | `"-Xmx1024m"` | JVM options for the language server. Increase `-Xmx` for large codebases. |
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

### Diagnostics are missing or stale

- Compiler diagnostics refresh on **save**. Parser diagnostics update on every keystroke.

### Formatting produces unexpected results

- Check that `fantom.formatting.bracketStyle` matches your preference.
- The formatter uses your editor's **Tab Size** and **Insert Spaces** settings.

### High memory usage or crashes

- Increase the heap: set `fantom.javaOpts` to `"-Xmx2048m"`.
- Enable `fantom.trace.server` at `"verbose"` to capture logs, then file an issue.

## Known Limitations

- **Rename** and **Find References** work for types, fields, and methods but not for local variables or method parameters.

## License

[AFL-3.0](https://opensource.org/licenses/AFL-3.0)
