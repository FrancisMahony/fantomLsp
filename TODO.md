# Fantom LSP — Remaining Work

_Last updated: 2026-02-19. Reflects actual code state, supersedes FEATURE_IMPLEMENTATION_PLAN.md._

---

## What Is Already Working

All items below are enabled end-to-end in `FantomLanguageServer.fan` and have passing tests.

| Feature | Provider | Notes |
|---------|----------|-------|
| Hover | `HoverProvider` | Type signatures, doc comments, slot details |
| Completion | `CompletionProvider` | Keywords, using-pods, dot completion, identifier completion |
| Signature Help | `SignatureHelpProvider` | Parameter hints, active-param highlighting |
| Diagnostics | `DiagnosticsProvider` + `CompilerDiagnostics` | Structural (parser) + full compiler errors; cross-file refresh on save; `@{macro}` deps resolved from `etc/build/config.props` |
| Go-to-Definition | `DefinitionProvider` | Finds types and slots in the SymbolTable |
| Find References | `ReferencesProvider` | Finds structural references (field types, param types, return types) |
| Document Symbols | via `SymbolTable` | Outline view, breadcrumb navigation |
| Workspace Symbol Search | `WorkspaceSymbolProvider` | `Ctrl+T` search across all open files |
| Code Formatting | `FormattingProvider` | Indentation, bracket styles (preserve / allman / k&r) |
| Rename Symbol | `RenameProvider` | Works for definitions, field types, method signatures — **see bug below** |

---

## Remaining Work

### 1. Rename — Method Body References Not Tracked (Critical Bug)

**File**: `server/fan/features/RenameProvider.fan`, `server/fan/parser/RecoveringParser.fan`, `server/fan/analysis/ReferenceIndex.fan`

**Problem**: Renaming a type renames its definition and any declaration-site usages (field types, parameter types, return types) but leaves usages inside method bodies untouched.

```fantom
class Example {
  static Void main() {
    user := User("test")        // NOT renamed
    list := User[,]             // NOT renamed
    if (val is User) { }        // NOT renamed
  }
}
class User { }                  // IS renamed
```

**Root cause**: `RecoveringParser` skips method-body content (anything at `braceDepth > 1`). `ReferenceIndex` therefore never sees type references that appear only inside method bodies.

**Fix needed**:
1. In `RecoveringParser.parseMethodOrCtor()`, scan body lines for type-name tokens and emit them as `AstNodeKind.typeRef` nodes (or add a simpler separate pass).
2. In `ReferenceIndex.update()`, index those type references so `RenameProvider` and `ReferencesProvider` can find them.
3. Extend `ReferencesProviderTest` / `RenameProviderTest` to cover method-body usages.

---

### 2. Variable & Parameter Tracking — Not Implemented

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

This is a substantial parser extension — estimate 2–3 days of work.

---

### 3. Code Actions — Complete

**File**: `server/fan/features/CodeActionProvider.fan`
**Status**: Done — wired up and tested

Implemented actions:
- **Add missing `using`**: When compiler reports an unknown type, suggests the pod that contains it.
- **Remove unused `using`**: Detects `using` statements whose pod/type is not referenced in the file. `using sys` is always exempt.
- **Uncomment line**: When cursor is on a `//`-prefixed line, offers to uncomment it.

`CodeActionProviderTest.fan` added with 10 tests covering all three actions, edit structure, `extractUnknownTypeName`, and the `sys` exemption. Unused `symbolTable`/`typeResolver` params removed from `codeActions()` signature.

---

### 4. Semantic Tokens — Complete

**File**: `server/fan/features/SemanticTokensProvider.fan` (106 lines)
**Status**: Enabled and tested

The implementation is fully enabled. `provideTokens()` and `addToken()` are wired up, LSP encoding is in place. It maps AST node kinds to token types (class, method, property, etc.) and encodes modifier bits (static, const, abstract, declaration).

**Completed**:
1. ✅ `semanticTokens: true` in `Serialization.serverCapabilities()` call.
2. ✅ `case "textDocument/semanticTokens/full"` enabled in `LspDispatcher.handleRequest`.
3. ✅ `semanticTokensFull()` method body enabled in `FantomLanguageServer.fan`.
4. ✅ `SemanticTokensProviderTest.fan` added with 13 test methods covering classes, methods, fields, enums, mixins, modifiers, and LSP encoding format.

---

### 5. Call Hierarchy — Disabled / Stub

**File**: `server/fan/features/CallHierarchyProvider.fan` (47 lines)
**Status**: Commented out in `FantomLanguageServer.fan`

`prepare()` and `incomingCalls()` have real implementations. `outgoingCalls()` returns an empty array (explicit stub).

`outgoingCalls` cannot be implemented without parsing method bodies to find call expressions — this is blocked by the same root cause as item 1 (method bodies not parsed).

**Steps to enable incoming calls** (partial value without outgoing):
1. Uncomment the three call-hierarchy handlers in `LspDispatcher` and `FantomLanguageServer`.
2. Set `callHierarchy: true` in server capabilities.
3. Verify `incomingCalls` works with current `ReferenceIndex`.
4. Add `CallHierarchyProviderTest.fan`.

**To complete outgoing calls**: requires method-body parsing (item 1 above).

---

### 6. Find References — Only Structural, Not Method-Body Usages

**File**: `server/fan/features/ReferencesProvider.fan`
**Status**: Enabled, but results are incomplete.

`ReferencesProvider` is wired up and returns results, but `ReferenceIndex` only contains references from field declarations and method signatures. References to a type that appear as local variable types, constructor calls, `is`/`as` expressions etc. inside method bodies are invisible.

This is the same root cause as item 1. Fixing item 1 automatically improves Find References.

---

### 7. Go-to-Definition — No Cross-File Jump for Unopened Files

**File**: `server/fan/features/DefinitionProvider.fan`
**Status**: Enabled. Works for any file that has been opened in the editor session.

The `SymbolTable` is populated per-file as documents are opened. If the file defining a type has never been opened in VS Code, `DefinitionProvider` returns nothing.

**Fix options**:
- On `initialize`, proactively scan all `.fan` files reachable via `build.fan` srcDirs and populate the symbol table (background indexing). The `WorkspaceManager` already has a commented-out `indexWorkspace()` call in `FantomLanguageServer.initialized()`.
- Re-enable that call and implement `WorkspaceManager.indexWorkspace()` to walk srcDirs and parse every `.fan` file.

---

### 8. Workspace Indexing Not Triggered on Startup

**File**: `server/fan/server/FantomLanguageServer.fan` line 82

```fan
// workspaceManager.indexWorkspace(symbolTable, typeResolver, referenceIndex)
```

This line is commented out. Without it, the symbol table only reflects files the user has opened, so workspace symbol search, definition jumping, and find-references are all limited to opened files.

**Fix**: Implement and enable `WorkspaceManager.indexWorkspace()`. Walk each workspace folder's `build.fan` srcDirs, parse every `.fan` file with `RecoveringParser`, and update the symbol table and reference index. Run this in the `initialized` handler (after the client handshake completes) so it doesn't block startup.

---

## Summary Checklist

### High Priority (core correctness)
- [ ] **1. Rename + Find References**: Parse type refs in method bodies; update ReferenceIndex
- [ ] **8. Workspace indexing on startup**: Enable proactive symbol table population

### Medium Priority (features that are almost there)
- [x] **4. Semantic tokens**: Enabled with comprehensive test coverage — done
- [ ] **5. Call hierarchy (incoming only)**: Enable the existing partial implementation
- [x] **3. Code actions**: Wired up, add-missing-using, remove-unused-using, uncomment — done

### Lower Priority (requires significant parser work)
- [ ] **2. Variable/parameter tracking**: Full scope analysis in method bodies
- [ ] **5. Call hierarchy outgoing**: Blocked by variable/parser work above

### Not blocking (limitations to document)
- [ ] **6. Find References completeness**: Improves automatically when item 1 is fixed
- [ ] **7. Go-to-Definition for unopened files**: Improves when item 8 is fixed
