# Known Issues and Limitations

## Critical Issues

### 1. Rename Symbol - BROKEN (Phase 2.4)

**Status:** Incomplete - Critical Bug

**Problem:** When renaming a type (class/mixin/enum), only the class definition gets renamed. Type usages inside method bodies are NOT renamed.

**Example:**
```fantom
class Example {
  static Void main() {
    user1 := User("test")      // ❌ NOT renamed when clicking "User" here
    user2 := User.make("test") // ❌ NOT renamed
  }
}
class User { }                 // ✅ IS renamed
```

**Root Cause:**
- `RecoveringParser.fan` lines 187-191 skip all code inside method bodies (`braceDepth > 1`)
- `ReferenceIndex` only tracks type references from:
  - Field declarations: `User myField`
  - Method parameters: `make(User param)`
  - Method return types: `User getName()`
- Type constructor calls like `User(...)` inside methods are never indexed

**What Works:**
- ✅ Renaming class/mixin/enum definitions
- ✅ Renaming types in field declarations
- ✅ Renaming types in method signatures (params, return types)
- ✅ Renaming fields and methods (slots)

**What Doesn't Work:**
- ❌ Renaming type usages inside method bodies (constructor calls, static calls)
- ❌ Renaming local variables (not tracked at all)
- ❌ Renaming parameters (not tracked)

**To Fix:**
The parser must scan method body lines and extract type references:
1. Constructor calls: `User(...)`, `User.make(...)`
2. Static method calls: `User.staticMethod(...)`
3. Type checks: `val is User`, `val as User`
4. Add these references to `ReferenceIndex`

**Location:** `server/fan/features/RenameProvider.fan` (documented in file header)

---

## Parser Limitations

### 2. Method Bodies Not Fully Parsed

**Impact:** Affects rename, references, and potentially other features

The parser currently uses a brace-depth tracking approach that skips detailed parsing of method body contents. Only top-level declarations (classes, fields, methods) are fully parsed.

**Affected Features:**
- Rename Symbol (see issue #1 above)
- Find References (only finds type refs in signatures, not usages in code)
- Future: Variable tracking, local symbol resolution

**Location:** `server/fan/parser/RecoveringParser.fan` lines 187-191

---

### 3. Variable Tracking Not Implemented

**Status:** Not implemented

Local variables, method parameters, and their usages are not tracked by the parser.

**Impact:**
- Cannot rename variables
- Cannot find all references to a variable
- Cannot provide variable-specific hover information

**To Implement:**
Would require significant parser changes to:
1. Track variable declarations (`x := 5`, `Str name`, etc.)
2. Track variable usages throughout scope
3. Implement scope analysis (local vs field vs parameter)

---

## Test Coverage

All current tests pass (240 tests, 591 verifications), but tests do not cover:
- ❌ Renaming type usages inside method bodies
- ❌ Variable operations (not supported)
- ✅ All other features have comprehensive test coverage

---

## Priority

**High Priority:**
1. Fix Rename Symbol to track type usages in method bodies

**Medium Priority:**
2. Implement variable tracking for rename/references

**Low Priority:**
3. Full AST parsing of method bodies (for future features)
