# Changelog

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
