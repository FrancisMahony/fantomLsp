# Fantom LSP Feature Implementation Plan

## Current State Review (as of code review)

### ✅ Implemented & Enabled Features
These features are fully working and enabled in `FantomLanguageServer.fan`:

1. **Hover** (`HoverProvider.fan`)
   - Shows type signatures and documentation
   - Handles local types, pod types, slots, and variables
   - Test coverage: `HoverProviderTest.fan` (9 test methods)

2. **Completion** (`CompletionProvider.fan`)
   - Keyword completion
   - Using statement pod name completion
   - Dot completion (this., super., receiver.)
   - Plain identifier completion (local types, pod types, keywords)
   - Test coverage: `CompletionProviderTest.fan` (multiple test scenarios)

3. **Signature Help** (`SignatureHelpProvider.fan`)
   - Parameter hints for method calls
   - Constructor signature help
   - Active parameter highlighting
   - Test coverage: `SignatureHelpProviderTest.fan`

### 🔨 Implemented but NOT Enabled Features
These providers exist with working implementations but are commented out in `FantomLanguageServer.fan`:

1. **DiagnosticsProvider** (12 lines - SIMPLE)
   - Converts parser errors to LSP diagnostics
   - **Dependency**: Parser (✅ exists)

2. **DefinitionProvider** (26 lines - SIMPLE)
   - Go-to-definition for symbols
   - **Dependencies**: SymbolTable (✅ exists), TypeResolver (✅ exists)

3. **ReferencesProvider** (24 lines - SIMPLE)
   - Find all references to a symbol
   - **Dependencies**: SymbolTable (✅ exists), ReferenceIndex (✅ exists)

4. **FormattingProvider** (45 lines - MEDIUM)
   - Basic code formatting with indentation
   - **Dependency**: DocumentState only

5. **RenameProvider** (29 lines - MEDIUM)
   - Rename symbols across files
   - **Dependencies**: SymbolTable (✅ exists), ReferenceIndex (✅ exists)

6. **CodeActionProvider** (45 lines - MEDIUM)
   - Quick fixes (add using, uncomment)
   - **Dependencies**: SymbolTable (✅ exists), TypeResolver (✅ exists)

7. **WorkspaceSymbolProvider** (19 lines - SIMPLE)
   - Workspace-wide symbol search
   - **Dependency**: SymbolTable (✅ exists)

8. **SemanticTokensProvider** (106 lines - COMPLEX)
   - Semantic highlighting tokens
   - **Dependencies**: SymbolTable (✅ exists), TypeResolver (✅ exists)
   - **Status**: Partial implementation, needs completion

9. **CallHierarchyProvider** (47 lines - MEDIUM)
   - Incoming/outgoing call hierarchy
   - **Dependencies**: SymbolTable (✅ exists), ReferenceIndex (✅ exists)
   - **Status**: Partial implementation (outgoingCalls returns empty)

### 🏗️ Infrastructure Components (All Present)
- ✅ **RecoveringParser**: Error-recovering parser
- ✅ **SymbolTable**: Per-file + workspace symbol indexing
- ✅ **TypeResolver**: Type resolution with using imports
- ✅ **ReferenceIndex**: Cross-file reference tracking
- ✅ **TextDocumentManager**: Document lifecycle management
- ✅ **WorkspaceManager**: Workspace folder management

### 📊 Test Infrastructure
Existing test files:
- ✅ `HoverProviderTest.fan` (188 lines)
- ✅ `CompletionProviderTest.fan` (276 lines)
- ✅ `SignatureHelpProviderTest.fan`
- ✅ `JsonRpcTest.fan`
- ✅ `LspMessagesTest.fan`
- ✅ `SerializationTest.fan`
- ✅ `ParserTest.fan`
- ✅ `TextDocumentManagerTest.fan`
- ✅ `LspUtilsTest.fan`

---

## Feature Implementation Order

### Priority Levels
- **P0**: Core editor experience (already done)
- **P1**: Essential navigation features (high impact, low risk)
- **P2**: Quality of life features (medium impact)
- **P3**: Advanced features (lower priority)

### Dependency Graph
```
RecoveringParser ─┐
                  ├─► DiagnosticsProvider (P1)
                  └─► TextDocumentManager (exists)

SymbolTable ──────┬─► DefinitionProvider (P1)
                  ├─► ReferencesProvider (P1)
                  ├─► WorkspaceSymbolProvider (P2)
                  ├─► RenameProvider (P2)
                  ├─► CallHierarchyProvider (P3)
                  └─► SemanticTokensProvider (P3)

ReferenceIndex ───┬─► ReferencesProvider (P1)
                  ├─► RenameProvider (P2)
                  └─► CallHierarchyProvider (P3)

TypeResolver ─────┬─► CodeActionProvider (P2)
                  └─► SemanticTokensProvider (P3)

DocumentState ────┴─► FormattingProvider (P2)
```

---

## Implementation Plan by Phase

## Phase 1: Core Navigation (P1 - Foundation Features)
**Goal**: Enable basic navigation that makes the LSP immediately more useful than syntax highlighting alone.

### Feature 1.1: Diagnostics Provider ⭐ START HERE
**Complexity**: ⭐☆☆☆☆ (Trivial - 1-2 hours)  
**Impact**: ⭐⭐⭐⭐⭐ (Critical for developer feedback)  
**Dependencies**: None (parser already integrated)

**Implementation Steps**:
1. Enable `DiagnosticsProvider` in `FantomLanguageServer.fan` (uncomment lines 5, 92-93, 112-113, 135-136)
2. Ensure diagnostics are published on `didOpen`, `didChange`, `didSave`
3. Clear diagnostics on `didClose`

**Testing Strategy**:
```fan
// New file: server/test/DiagnosticsProviderTest.fan
class DiagnosticsProviderTest : Test
{
  Void testSyntaxError()
  Void testMissingCloseBrace()
  Void testMultipleErrors()
  Void testClearOnClose()
}
```

**Acceptance Criteria**:
- ✅ Red squiggles appear for syntax errors
- ✅ Error messages are accurate
- ✅ Diagnostics update on file changes
- ✅ Diagnostics clear when file is closed

**Build & Test Command**:
```bash
# Rebuild server
cd server
fan build.fan

# Run tests
fan -version  # Verify Fantom is available
fan fantomLsp::DiagnosticsProviderTest
```

---

### Feature 1.2: Definition Provider (Go-to-Definition)
**Complexity**: ⭐⭐☆☆☆ (Simple - 2-4 hours)  
**Impact**: ⭐⭐⭐⭐⭐ (Essential navigation)  
**Dependencies**: SymbolTable (✅ exists)

**Implementation Steps**:
1. Enable `DefinitionProvider` in `FantomLanguageServer.fan` (uncomment line 7)
2. Enable capability flag (line 52)
3. Wire up handler method (uncomment and implement)
4. Enhance to handle:
   - Local type definitions
   - Local slot definitions (methods, fields)
   - Pod type definitions (jump to source if available)
   - Cross-file definitions

**Current Limitations to Address**:
- Only searches by name (no context awareness)
- Doesn't handle qualified names (`MyType.method`)
- No support for jumping to pod source files

**Testing Strategy**:
```fan
// New file: server/test/DefinitionProviderTest.fan
class DefinitionProviderTest : Test
{
  Void testGoToLocalClass()
  Void testGoToLocalMethod()
  Void testGoToLocalField()
  Void testGoToSysType()  // Should handle gracefully
  Void testGoToMethodParameter()
  Void testGoToVariable()
  Void testNoDefinitionFound()
}
```

**Acceptance Criteria**:
- ✅ Ctrl+Click on type name jumps to definition
- ✅ Ctrl+Click on method/field jumps to definition
- ✅ Ctrl+Click on variable jumps to declaration
- ✅ Works across files in the same workspace
- ✅ Gracefully handles pod types (no definition or show hover)

**Build & Test**:
```bash
cd server && fan build.fan && fan fantomLsp::DefinitionProviderTest
```

---

### Feature 1.3: References Provider (Find All References)
**Complexity**: ⭐⭐☆☆☆ (Simple - 2-4 hours)  
**Impact**: ⭐⭐⭐⭐☆ (Important for refactoring)  
**Dependencies**: SymbolTable (✅), ReferenceIndex (✅)

**Implementation Steps**:
1. Enable `ReferencesProvider` in `FantomLanguageServer.fan`
2. Enable capability flag
3. Wire up handler method
4. Enhance ReferenceIndex to track:
   - Method calls
   - Field accesses
   - Type references (not just in signatures)
   - Variable usage

**Current Limitations to Address**:
- ReferenceIndex only tracks type references in field/parameter declarations
- Doesn't track actual usage in method bodies

**Testing Strategy**:
```fan
// New file: server/test/ReferencesProviderTest.fan
class ReferencesProviderTest : Test
{
  Void testFindTypeReferences()
  Void testFindMethodReferences()
  Void testFindFieldReferences()
  Void testFindLocalVariableReferences()
  Void testNoReferencesFound()
  Void testReferencesAcrossFiles()
}
```

**Acceptance Criteria**:
- ✅ Right-click → Find All References shows all usages
- ✅ Finds references in same file
- ✅ Finds references across workspace files
- ✅ Includes definition location in results
- ✅ Handles no references gracefully

**Build & Test**:
```bash
cd server && fan build.fan && fan fantomLsp::ReferencesProviderTest
```

---

## Phase 2: Quality of Life (P2 - Productivity Features)
**Goal**: Add features that improve code editing experience.

### Feature 2.1: Document Symbols (Outline View)
**Complexity**: ⭐☆☆☆☆ (Trivial - 1 hour)  
**Impact**: ⭐⭐⭐☆☆ (Nice to have for navigation)  
**Dependencies**: SymbolTable (✅ already has `getDocumentSymbols` method!)

**Implementation Steps**:
1. Enable document symbols capability in `initialize` response
2. Add handler for `textDocument/documentSymbol` request
3. Call `symbolTable.getDocumentSymbols(uri)`

**Testing Strategy**:
```fan
// Extend: server/test/SymbolTableTest.fan (if not exists, create)
class SymbolTableTest : Test
{
  Void testGetDocumentSymbols()
  Void testNestedSymbols()
  Void testEmptyDocument()
}
```

**Acceptance Criteria**:
- ✅ Outline view shows types and their members
- ✅ Breadcrumb navigation works
- ✅ Symbols are nested correctly (methods under classes)

---

### Feature 2.2: Workspace Symbol Search
**Complexity**: ⭐☆☆☆☆ (Trivial - 1-2 hours)  
**Impact**: ⭐⭐⭐☆☆ (Useful for large projects)  
**Dependencies**: SymbolTable (✅)

**Implementation Steps**:
1. Enable `WorkspaceSymbolProvider` in `FantomLanguageServer.fan`
2. Enable capability flag
3. Wire up handler for `workspace/symbol` request
4. Ensure SymbolTable is populated for all open files

**Testing Strategy**:
```fan
// New file: server/test/WorkspaceSymbolProviderTest.fan
class WorkspaceSymbolProviderTest : Test
{
  Void testSearchByName()
  Void testSearchPartialMatch()
  Void testSearchCaseInsensitive()
  Void testEmptyQuery()
  Void testNoResults()
}
```

**Acceptance Criteria**:
- ✅ Ctrl+T opens workspace symbol search
- ✅ Search works across all open files
- ✅ Results show type and location
- ✅ Fuzzy matching works

**Build & Test**:
```bash
cd server && fan build.fan && fan fantomLsp::WorkspaceSymbolProviderTest
```

---

### Feature 2.3: Code Formatting
**Complexity**: ⭐⭐⭐☆☆ (Medium - 4-8 hours to improve)  
**Impact**: ⭐⭐⭐⭐☆ (Important for consistency)  
**Dependencies**: DocumentState only

**Implementation Steps**:
1. Enable `FormattingProvider` in `FantomLanguageServer.fan`
2. Enable capability flags (both `documentFormattingProvider` and `documentRangeFormattingProvider`)
3. Enhance current implementation:
   - Handle string literals properly (don't format inside strings)
   - Handle DSL blocks (backtick literals)
   - Respect existing blank lines
   - Format method chains
   - Handle comments properly

**Current Limitations to Address**:
- Very basic indentation only
- Doesn't handle all Fantom syntax (DSLs, it-blocks, closures)

**Testing Strategy**:
```fan
// New file: server/test/FormattingProviderTest.fan
class FormattingProviderTest : Test
{
  Void testBasicIndentation()
  Void testNestedBlocks()
  Void testStringLiterals()
  Void testComments()
  Void testEmptyLines()
  Void testDslBlocks()
  Void testRangeFormatting()
}
```

**Acceptance Criteria**:
- ✅ Format Document works without breaking code
- ✅ Consistent indentation (2 spaces)
- ✅ String contents preserved
- ✅ Comments preserved
- ✅ Range formatting works

**Build & Test**:
```bash
cd server && fan build.fan && fan fantomLsp::FormattingProviderTest
```

---

### Feature 2.4: Rename Symbol ⚠️ CRITICAL BUG
**Complexity**: ⭐⭐⭐☆☆ (Medium - 4-6 hours)
**Impact**: ⭐⭐⭐⭐☆ (Important for refactoring)
**Dependencies**: SymbolTable (✅), ReferenceIndex (✅)

**STATUS: INCOMPLETE - CRITICAL BUG DOCUMENTED**

See `KNOWN_ISSUES.md` for full details.

**Implementation Steps**:
1. ✅ Enable `RenameProvider` in `FantomLanguageServer.fan`
2. ✅ Enable capability flags (`renameProvider` with `prepareProvider`)
3. ✅ Implement `prepareRename` to validate rename location
4. ❌ **BROKEN**: ReferenceIndex does NOT track type usages in method bodies
5. Handle edge cases:
   - Renaming types should update `using` statements if needed
   - Validate new name is valid Fantom identifier

**CRITICAL BUG**:
When renaming a type (e.g., `User`), only the class definition is renamed. Type usages inside method bodies (like `User(...)` or `User.make(...)`) are NOT renamed because the parser skips method body contents.

**Root Cause**:
- `RecoveringParser.fan` lines 187-191 skip all code when `braceDepth > 1` (inside methods)
- `ReferenceIndex` only tracks type references in field declarations and method signatures
- Constructor calls and type usages inside methods are never indexed

**What Works**:
- ✅ Renaming class/mixin/enum definitions
- ✅ Renaming types in field declarations (`User myField`)
- ✅ Renaming types in method signatures (`make(User param)`)
- ✅ Renaming fields and methods

**What Doesn't Work**:
- ❌ Renaming type usages inside method bodies (`User(...)`, `User.make(...)`)
- ❌ Renaming local variables (not tracked)
- ❌ Renaming parameters (not tracked)

**To Fix**:
Parser must scan method body lines and extract type references to ReferenceIndex.

**Testing Strategy**:
```fan
// New file: server/test/RenameProviderTest.fan
class RenameProviderTest : Test
{
  Void testRenameLocalVariable()  // Returns nothing (not supported)
  Void testRenameMethod()         // Works ✅
  Void testRenameField()          // Works ✅
  Void testRenameType()           // PARTIAL - only definitions, not usages in methods ❌
  Void testRenameInvalidName()
  Void testRenameAcrossFiles()
}
```

**Acceptance Criteria**:
- ✅ F2 on symbol opens rename dialog
- ❌ All references are renamed atomically (BROKEN for types in method bodies)
- ⚠️ Rename works across files (only for definitions/signatures, not method body usages)
- ❌ Invalid names are rejected (not implemented)
- ⚠️ Undo works correctly (only for what was renamed)

**Build & Test**:
```bash
cd server && fan build.fan && fan fantomLsp::RenameProviderTest
```

---

### Feature 2.5: Code Actions (Quick Fixes)
**Complexity**: ⭐⭐⭐☆☆ (Medium - 6-10 hours)  
**Impact**: ⭐⭐⭐⭐☆ (Great for developer experience)  
**Dependencies**: SymbolTable (✅), TypeResolver (✅), DiagnosticsProvider (✅)

**Implementation Steps**:
1. Enable `CodeActionProvider` in `FantomLanguageServer.fan`
2. Enable capability flag with supported kinds
3. Enhance current implementation with more actions:
   - **Add missing using**: Detect unknown type errors, suggest pods
   - **Remove unused using**: Detect and remove
   - **Add override keyword**: Detect missing override on inherited methods
   - **Generate constructor**: Create `make()` with field assignments
   - **Generate getter/setter**: For fields
   - **Extract method**: Extract selection to new method
   - **Inline variable**: Replace variable with its value

**Current Implementation**: Only has uncomment line action

**Testing Strategy**:
```fan
// New file: server/test/CodeActionProviderTest.fan
class CodeActionProviderTest : Test
{
  Void testAddMissingUsing()
  Void testRemoveUnusedUsing()
  Void testAddOverride()
  Void testUncommentLine()
  Void testNoActionsAvailable()
}
```

**Acceptance Criteria**:
- ✅ Lightbulb appears on diagnostics
- ✅ Quick fix adds missing using statement
- ✅ Actions are context-appropriate
- ✅ Applied edits work correctly

**Build & Test**:
```bash
cd server && fan build.fan && fan fantomLsp::CodeActionProviderTest
```

---

## Phase 3: Advanced Features (P3 - Polish)
**Goal**: Add advanced features for power users.

### Feature 3.1: Semantic Tokens (Semantic Highlighting)
**Complexity**: ⭐⭐⭐⭐☆ (Complex - 10-15 hours)  
**Impact**: ⭐⭐⭐☆☆ (Nice to have, visual improvement)  
**Dependencies**: SymbolTable (✅), TypeResolver (✅)

**Implementation Steps**:
1. Complete the `SemanticTokensProvider` implementation
2. Implement `addToken` helper method (currently missing)
3. Enable capability with token types and modifiers
4. Map AST nodes to semantic token types
5. Handle:
   - Types (class, mixin, enum) → `class` token
   - Methods → `method` token
   - Fields → `property` token
   - Local variables → `variable` token
   - Parameters → `parameter` token
   - Keywords → `keyword` token
   - Modifiers (static, const, etc.) → modifiers

**Current Status**: Partial - data encoding exists but token generation incomplete

**Testing Strategy**:
```fan
// New file: server/test/SemanticTokensProviderTest.fan
class SemanticTokensProviderTest : Test
{
  Void testClassTokens()
  Void testMethodTokens()
  Void testFieldTokens()
  Void testVariableTokens()
  Void testStaticModifier()
  Void testConstModifier()
  Void testEncodedOutput()
}
```

**Acceptance Criteria**:
- ✅ Types colored distinctly from variables
- ✅ Static members colored differently
- ✅ Const fields have special styling
- ✅ Token data is correctly encoded

**Build & Test**:
```bash
cd server && fan build.fan && fan fantomLsp::SemanticTokensProviderTest
```

---

### Feature 3.2: Call Hierarchy
**Complexity**: ⭐⭐⭐⭐☆ (Complex - 10-15 hours)  
**Impact**: ⭐⭐☆☆☆ (Useful for large codebases)  
**Dependencies**: SymbolTable (✅), ReferenceIndex (✅) - **needs enhancement**

**Implementation Steps**:
1. Enable `CallHierarchyProvider` in `FantomLanguageServer.fan`
2. Enable capability flag
3. **Enhance ReferenceIndex** to track method calls specifically (not just references)
4. Implement `outgoingCalls` (currently returns empty array)
5. Parse method bodies to find call expressions
6. Handle:
   - Direct method calls (`obj.method()`)
   - Static method calls (`Type.method()`)
   - Constructor calls
   - Closure calls

**Current Status**: Partial - `prepare` and `incomingCalls` exist, `outgoingCalls` is stub

**Testing Strategy**:
```fan
// New file: server/test/CallHierarchyProviderTest.fan
class CallHierarchyProviderTest : Test
{
  Void testPrepareCallHierarchy()
  Void testIncomingCalls()
  Void testOutgoingCalls()
  Void testRecursiveCalls()
  Void testNoCallers()
}
```

**Acceptance Criteria**:
- ✅ Right-click → Show Call Hierarchy works
- ✅ Shows methods that call the current method
- ✅ Shows methods called by the current method
- ✅ Handles recursion gracefully

**Build & Test**:
```bash
cd server && fan build.fan && fan fantomLsp::CallHierarchyProviderTest
```

---

## Testing Strategy & CI/CD

### Test Execution Workflow
Since tests run against **compiled code**, not source:

```bash
#!/bin/bash
# scripts/test.sh

set -e

echo "=== Building fantomLsp pod ==="
cd server
fan build.fan

echo "=== Running all tests ==="
# Run all test classes
fan fantomLsp::HoverProviderTest
fan fantomLsp::CompletionProviderTest
fan fantomLsp::SignatureHelpProviderTest
fan fantomLsp::DiagnosticsProviderTest
fan fantomLsp::DefinitionProviderTest
fan fantomLsp::ReferencesProviderTest
fan fantomLsp::FormattingProviderTest
fan fantomLsp::RenameProviderTest
fan fantomLsp::CodeActionProviderTest
fan fantomLsp::WorkspaceSymbolProviderTest
fan fantomLsp::SemanticTokensProviderTest
fan fantomLsp::CallHierarchyProviderTest
fan fantomLsp::JsonRpcTest
fan fantomLsp::LspMessagesTest
fan fantomLsp::SerializationTest
fan fantomLsp::ParserTest
fan fantomLsp::TextDocumentManagerTest
fan fantomLsp::LspUtilsTest

echo "=== All tests passed ==="
```

### Regression Test Suite
**Critical**: Before enabling any new feature, run full test suite to ensure no regressions.

```bash
# Make test script executable
chmod +x scripts/test.sh

# Run before and after each feature
./scripts/test.sh
```

### Integration Testing
For each feature, create a sample `.fan` file and manually test in VS Code:

```bash
# scripts/manual_test.sh
cd client
npm run compile
code --extensionDevelopmentPath=$PWD ../test-workspace
```

### Test Coverage Goals
- **Unit Tests**: Each provider should have 5-10 test methods
- **Integration Tests**: End-to-end LSP protocol tests
- **Edge Cases**: Error conditions, empty inputs, malformed code

---

## Risk Mitigation

### Breaking Changes Prevention
1. **Always rebuild before testing**: Tests run on compiled `.pod` file
2. **Run full test suite**: Before committing any changes
3. **Test with real Fantom code**: Use actual project files, not just toy examples

### Performance Considerations
1. **Symbol indexing**: May be slow on large workspaces
   - Solution: Background indexing with progress notifications
   - Debounce file changes (already implemented: 200ms)

2. **Completion performance**: May lag with large pod count
   - Solution: Cache pod type lists
   - Limit completion results to top 100

3. **Reference finding**: May be slow across many files
   - Solution: Incremental indexing
   - Only search opened files unless explicitly requested

### Common Pitfalls
1. **Parser limitations**: Recovering parser may not handle all edge cases
   - Mitigation: Add more recovery strategies as issues are found

2. **Type inference**: Complex expressions may not resolve correctly
   - Mitigation: Fall back to syntactic analysis when semantic fails

3. **Cross-file dependencies**: Symbol table may not be fully populated
   - Mitigation: Explicitly trigger workspace indexing on initialize

---

## Summary Checklist

### Phase 1: Core Navigation (Weeks 1-2)
- [ ] 1.1 Enable Diagnostics (1-2 hours) ⭐ START HERE
- [ ] 1.2 Enable Go-to-Definition (2-4 hours)
- [ ] 1.3 Enable Find References (2-4 hours)

### Phase 2: Quality of Life (Weeks 3-5)
- [ ] 2.1 Enable Document Symbols (1 hour)
- [ ] 2.2 Enable Workspace Symbols (1-2 hours)
- [ ] 2.3 Improve Code Formatting (4-8 hours)
- [ ] 2.4 Enable Rename Symbol (4-6 hours)
- [ ] 2.5 Enhance Code Actions (6-10 hours)

### Phase 3: Advanced Features (Weeks 6-8)
- [ ] 3.1 Complete Semantic Tokens (10-15 hours)
- [ ] 3.2 Complete Call Hierarchy (10-15 hours)

### Testing & Infrastructure
- [ ] Create `scripts/test.sh` with rebuild + test all
- [ ] Add test class for each new feature
- [ ] Manual integration test in VS Code for each feature
- [ ] Document test results and edge cases

---

## Quick Start: Enabling Diagnostics (Your First Feature)

1. **Uncomment in `FantomLanguageServer.fan`**:
   ```fan
   DiagnosticsProvider diagnosticsProvider := DiagnosticsProvider()  // Line 5
   ```

2. **Enable in handlers**:
   ```fan
   // In didOpen (line 91-93)
   parseResult := docManager.parseDocument(item.uri)
   diags := diagnosticsProvider.computeDiagnostics(item.uri, parseResult)
   return Serialization.publishDiagnostics(item.uri, diags)
   ```

3. **Rebuild and test**:
   ```bash
   cd server
   fan build.fan
   
   # Test manually in VS Code or create test
   fan fantomLsp::DiagnosticsProviderTest
   ```

4. **Verify**:
   - Open a `.fan` file with syntax errors
   - Red squiggles should appear
   - Hover over squiggles shows error message

---

## Next Steps After This Plan

1. Start with Phase 1.1 (Diagnostics) - lowest risk, immediate value
2. After each feature, commit and test thoroughly
3. Update this plan with actual time taken vs. estimates
4. Document any unexpected issues or improvements
5. Consider creating a GitHub project board to track progress

Good luck! 🚀
