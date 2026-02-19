# Details

Date : 2026-02-19 10:42:52

Directory c:\\Code\\monoRepos\\fantomLsp\\server

Total : 39 files,  4903 codes, 290 comments, 768 blanks, all 5961 lines

[Summary](results.md) / Details / [Diff Summary](diff.md) / [Diff Details](diff-details.md)

## Files
| filename | language | code | comment | blank | total |
| :--- | :--- | ---: | ---: | ---: | ---: |
| [fantomLsp/server/build.fan](/fantomLsp/server/build.fan) | Fantom | 25 | 0 | 2 | 27 |
| [fantomLsp/server/fan/Main.fan](/fantomLsp/server/fan/Main.fan) | Fantom | 41 | 0 | 10 | 51 |
| [fantomLsp/server/fan/analysis/LspUtils.fan](/fantomLsp/server/fan/analysis/LspUtils.fan) | Fantom | 197 | 19 | 23 | 239 |
| [fantomLsp/server/fan/analysis/ReferenceIndex.fan](/fantomLsp/server/fan/analysis/ReferenceIndex.fan) | Fantom | 59 | 0 | 7 | 66 |
| [fantomLsp/server/fan/analysis/SymbolTable.fan](/fantomLsp/server/fan/analysis/SymbolTable.fan) | Fantom | 110 | 0 | 13 | 123 |
| [fantomLsp/server/fan/analysis/TypeResolver.fan](/fantomLsp/server/fan/analysis/TypeResolver.fan) | Fantom | 78 | 0 | 10 | 88 |
| [fantomLsp/server/fan/features/CallHierarchyProvider.fan](/fantomLsp/server/fan/features/CallHierarchyProvider.fan) | Fantom | 42 | 0 | 6 | 48 |
| [fantomLsp/server/fan/features/CodeActionProvider.fan](/fantomLsp/server/fan/features/CodeActionProvider.fan) | Fantom | 42 | 0 | 4 | 46 |
| [fantomLsp/server/fan/features/CompletionProvider.fan](/fantomLsp/server/fan/features/CompletionProvider.fan) | Fantom | 347 | 27 | 47 | 421 |
| [fantomLsp/server/fan/features/DefinitionProvider.fan](/fantomLsp/server/fan/features/DefinitionProvider.fan) | Fantom | 23 | 0 | 4 | 27 |
| [fantomLsp/server/fan/features/DiagnosticsProvider.fan](/fantomLsp/server/fan/features/DiagnosticsProvider.fan) | Fantom | 12 | 0 | 1 | 13 |
| [fantomLsp/server/fan/features/FormattingProvider.fan](/fantomLsp/server/fan/features/FormattingProvider.fan) | Fantom | 39 | 0 | 7 | 46 |
| [fantomLsp/server/fan/features/HoverProvider.fan](/fantomLsp/server/fan/features/HoverProvider.fan) | Fantom | 73 | 4 | 8 | 85 |
| [fantomLsp/server/fan/features/ReferencesProvider.fan](/fantomLsp/server/fan/features/ReferencesProvider.fan) | Fantom | 20 | 0 | 5 | 25 |
| [fantomLsp/server/fan/features/RenameProvider.fan](/fantomLsp/server/fan/features/RenameProvider.fan) | Fantom | 25 | 0 | 5 | 30 |
| [fantomLsp/server/fan/features/SemanticTokensProvider.fan](/fantomLsp/server/fan/features/SemanticTokensProvider.fan) | Fantom | 91 | 0 | 15 | 106 |
| [fantomLsp/server/fan/features/SignatureHelpProvider.fan](/fantomLsp/server/fan/features/SignatureHelpProvider.fan) | Fantom | 142 | 7 | 11 | 160 |
| [fantomLsp/server/fan/features/WorkspaceSymbolProvider.fan](/fantomLsp/server/fan/features/WorkspaceSymbolProvider.fan) | Fantom | 18 | 0 | 2 | 20 |
| [fantomLsp/server/fan/parser/PartialAst.fan](/fantomLsp/server/fan/parser/PartialAst.fan) | Fantom | 86 | 0 | 12 | 98 |
| [fantomLsp/server/fan/parser/RecoveringParser.fan](/fantomLsp/server/fan/parser/RecoveringParser.fan) | Fantom | 407 | 0 | 54 | 461 |
| [fantomLsp/server/fan/protocol/JsonRpc.fan](/fantomLsp/server/fan/protocol/JsonRpc.fan) | Fantom | 91 | 0 | 13 | 104 |
| [fantomLsp/server/fan/protocol/LspDispatcher.fan](/fantomLsp/server/fan/protocol/LspDispatcher.fan) | Fantom | 121 | 14 | 13 | 148 |
| [fantomLsp/server/fan/protocol/LspMessages.fan](/fantomLsp/server/fan/protocol/LspMessages.fan) | Fantom | 239 | 0 | 17 | 256 |
| [fantomLsp/server/fan/protocol/Serialization.fan](/fantomLsp/server/fan/protocol/Serialization.fan) | Fantom | 80 | 0 | 12 | 92 |
| [fantomLsp/server/fan/server/FantomLanguageServer.fan](/fantomLsp/server/fan/server/FantomLanguageServer.fan) | Fantom | 174 | 75 | 30 | 279 |
| [fantomLsp/server/fan/server/TextDocumentManager.fan](/fantomLsp/server/fan/server/TextDocumentManager.fan) | Fantom | 144 | 0 | 30 | 174 |
| [fantomLsp/server/fan/server/WorkspaceManager.fan](/fantomLsp/server/fan/server/WorkspaceManager.fan) | Fantom | 94 | 0 | 11 | 105 |
| [fantomLsp/server/test/CompletionProviderTest.fan](/fantomLsp/server/test/CompletionProviderTest.fan) | Fantom | 216 | 23 | 37 | 276 |
| [fantomLsp/server/test/DiagnosticsProviderTest.fan](/fantomLsp/server/test/DiagnosticsProviderTest.fan) | Fantom | 68 | 0 | 7 | 75 |
| [fantomLsp/server/test/DocumentSymbolTest.fan](/fantomLsp/server/test/DocumentSymbolTest.fan) | Fantom | 92 | 0 | 34 | 126 |
| [fantomLsp/server/test/HoverProviderTest.fan](/fantomLsp/server/test/HoverProviderTest.fan) | Fantom | 145 | 19 | 24 | 188 |
| [fantomLsp/server/test/JsonRpcTest.fan](/fantomLsp/server/test/JsonRpcTest.fan) | Fantom | 118 | 6 | 18 | 142 |
| [fantomLsp/server/test/LspMessagesTest.fan](/fantomLsp/server/test/LspMessagesTest.fan) | Fantom | 232 | 10 | 37 | 279 |
| [fantomLsp/server/test/LspUtilsTest.fan](/fantomLsp/server/test/LspUtilsTest.fan) | Fantom | 343 | 22 | 64 | 429 |
| [fantomLsp/server/test/ParserTest.fan](/fantomLsp/server/test/ParserTest.fan) | Fantom | 298 | 20 | 56 | 374 |
| [fantomLsp/server/test/SerializationTest.fan](/fantomLsp/server/test/SerializationTest.fan) | Fantom | 102 | 5 | 18 | 125 |
| [fantomLsp/server/test/SignatureHelpProviderTest.fan](/fantomLsp/server/test/SignatureHelpProviderTest.fan) | Fantom | 178 | 23 | 30 | 231 |
| [fantomLsp/server/test/TextDocumentManagerTest.fan](/fantomLsp/server/test/TextDocumentManagerTest.fan) | Fantom | 196 | 16 | 40 | 252 |
| [fantomLsp/server/test/WorkspaceSymbolTest.fan](/fantomLsp/server/test/WorkspaceSymbolTest.fan) | Fantom | 95 | 0 | 31 | 126 |

[Summary](results.md) / Details / [Diff Summary](diff.md) / [Diff Details](diff-details.md)