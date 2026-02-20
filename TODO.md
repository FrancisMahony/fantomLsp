# Fantom LSP — Remaining Work

_Last updated: 2026-02-20. Reflects actual code state._

---

## What Is Already Working

All items below are enabled end-to-end in `FantomLanguageServer.fan` and have passing tests.

| Feature | Provider | Notes |
|---------|----------|-------|
| Hover | `HoverProvider` | Type signatures, doc comments, slot details |
| Completion | `CompletionProvider` | Keywords, using-pods, dot completion, identifier completion |
| Signature Help | `SignatureHelpProvider` | Parameter hints, active-param highlighting |
| Diagnostics | `DiagnosticsProvider` + `CompilerDiagnostics` | Structural (parser) + full compiler errors; cross-file refresh on save; `@{macro}` deps resolved from `etc/build/config.props` |
| Go-to-Definition | `DefinitionProvider` | Finds types and slots in the SymbolTable; cross-file via workspace indexing |
| Find References | `ReferencesProvider` | Structural refs (field types, param types, return types) **and method-body type refs** |
| Document Symbols | via `SymbolTable` | Outline view, breadcrumb navigation |
| Workspace Symbol Search | `WorkspaceSymbolProvider` | `Ctrl+T` search across all open files |
| Code Formatting | `FormattingProvider` | Indentation, bracket styles (preserve / allman / k&r) |
| Rename Symbol | `RenameProvider` | Definitions, field types, method signatures, **and method-body type refs** |
| Code Actions | `CodeActionProvider` | Add missing using, remove unused using, uncomment line |
| Semantic Tokens | `SemanticTokensProvider` | Full syntax highlighting; classes, methods, fields, modifiers |
| Call Hierarchy | `CallHierarchyProvider` | Prepare, incoming calls, **and outgoing calls** |
| Workspace Indexing | `WorkspaceManager` | Indexes all `.fan` files on startup; populates symbol table, type resolver, reference index |

---

## Remaining Work

### 1. Variable & Parameter Tracking — Not Implemented

**Files**: `RecoveringParser.fan`, `ReferenceIndex.fan`

Local variables (`x := 5`, `Str name := ...`) and method parameters are not parsed, not indexed, and not exposed anywhere. This blocks:

- Rename local variable / parameter
- Find all references to a local variable
- Accurate hover on a local variable (currently shows nothing or wrong type)
- Future: type inference inside method bodies

**Fix needed**:
1. Parse variable declarations (`:=`, typed declaration, loop variables) within method bodies.
2. Track parameter names from already-parsed `AstNode.params`.
3. Add scope-aware lookup to `SymbolTable` / `TypeResolver`.

This is a substantial parser extension.

---

## Summary Checklist

### Completed
- [x] **1. Rename + Find References body refs**: Parse type refs in method bodies; update ReferenceIndex — done
- [x] **2. Call hierarchy outgoing**: Scan method bodies for call refs, wire up outgoingCalls — done
- [x] **3. Code actions**: Add-missing-using, remove-unused-using, uncomment — done
- [x] **4. Semantic tokens**: Enabled with comprehensive test coverage — done
- [x] **5. Call hierarchy incoming**: Enabled and tested — done
- [x] **6. Find References completeness**: Method-body type refs now indexed — done
- [x] **7. Go-to-Definition cross-file**: Works via workspace indexing — done
- [x] **8. Workspace indexing on startup**: Implemented and enabled — done

### Remaining (requires significant parser work)
- [ ] **Variable/parameter tracking**: Full scope analysis in method bodies — local vars and params not yet indexed
