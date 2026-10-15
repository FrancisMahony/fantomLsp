# Contributing

This guide covers building, running and testing the extension. For how the server works internally, see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Repository layout

```
fantomLsp/
├── client/                 VS Code extension (TypeScript)
│   ├── src/extension.ts    Locates Fantom, launches the server, wires the LSP client
│   ├── syntaxes/           TextMate grammar
│   └── package.json        Extension manifest and settings
├── server/                 Language server (Fantom pod "fantomLsp")
│   ├── build.fan
│   ├── fan/                Server source (protocol, server, parser, analysis, features)
│   └── test/               Tests (compiled into the pod)
├── scripts/                build.bat / build.sh: build server + client and package the VSIX
└── docs/                   Architecture and release notes for maintainers
```

## Prerequisites

| Tool | Notes |
|---|---|
| Java 11+ | Runs `fan` and the server. |
| Fantom or SkySpark | `FAN_HOME` set, with `fan` and `fant` on `PATH`. |
| Node.js 18+ and npm | Builds the client. |

## Building

### Server

```bash
cd server
fan build.fan
```

This installs `fantomLsp.pod` into `$FAN_HOME/lib/fan/` and copies it to `server/lib/fan/`. Both are build outputs and are not committed.

### Client

```bash
cd client
npm install
npm run compile          # bundle to client/out/
npx tsc --noEmit -p .    # type-check
```

### Everything, including the VSIX

```bash
scripts/build.sh         # macOS / Linux
scripts\build.bat        # Windows
```

Both scripts build the server and copy the pod into `client/server/lib/fan/` (the extension loads it from there). They then compile the client and produce `client/fantom-lsp-<version>.vsix`.

## Running in development

1. Build the server, then copy the pod into the client so the extension loads your build:
   ```bash
   cd server && fan build.fan
   mkdir -p ../client/server/lib/fan && cp lib/fan/fantomLsp.pod ../client/server/lib/fan/
   ```
   On Windows, `copy server\lib\fan\fantomLsp.pod client\server\lib\fan\` does the same. Running the build script also works.
2. Open the repository root in VS Code and press **F5** (**Run Fantom LSP Extension**). An Extension Development Host window opens with the extension loaded from `client/`.
3. After changing server code, rebuild, copy the pod again, and click **Fantom LS** in the status bar to restart the server. Launch settings (`fantom.home`, `fantom.javaOpts`, `fantom.maxFiles`, `fantom.excludeDirs`) are read once at activation; reload the window to apply changes to them.

Logs:
- **Fantom LSP Launch**: how the server was launched (installation, Java, lookup roots).
- **Fantom Language Server**: server output and, when `fantom.trace.server` is enabled, LSP traffic.

## Testing

Tests live in `server/test/` and are compiled into the pod, so **always rebuild before testing**:

```bash
cd server
fan build.fan
fant fantomLsp                      # full suite (a few minutes)
fant fantomLsp::RenameProviderTest  # one test class
fant fantomLsp::RenameProviderTest.testLocalRenameOnlyM1AndClientUri   # one test method
```

Tests that need the real compiler create temporary pods under `Env.cur.tempDir` and delete them afterwards. They never install anything into `FAN_HOME`.

`NavigationAcceptanceTest` drives the server end-to-end over JSON-RPC. The concurrency and performance tests (`ConcurrencyStressTest`, `ResolverPerformanceTest`) enforce responsiveness under load. If one of them fails intermittently, treat it as a real bug.

### Optional real-workspace test

`InteractiveRecoveryTest` replays a sustained interactive session against a real workspace. It's a maintainer tool: the fixture file must contain the identifiers listed in the test's `spots` table, and the test fails fast if it doesn't. It's skipped unless you opt in:

| Variable | Meaning |
|---|---|
| `FANTOM_LSP_RECOVERY_ROOT` | Workspace directory to index. |
| `FANTOM_LSP_RECOVERY_FILE` | A `.fan` file inside that workspace to exercise. |
| `FANTOM_LSP_RECOVERY_POD` | Optional. Pod name for code-lens keys; defaults to the nearest `build.fan`. |

## Guidelines

- **Threading.** All mutable analysis state belongs to the main dispatch thread. Background actors may only take immutable inputs and post immutable results to the mailbox. See the threading section of [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
- **No guessing.** Navigation features must go through `SymbolResolver`. Return a `proven` result only when the compiler (or a declaration or local under the cursor) proves it. Otherwise return a ranked list or nothing.
- **Tests with fixes.** Every bug fix needs a regression test. Run the full suite before submitting.
- **Comments.** Explain *why* code is the way it is, in terms that make sense without outside context.
- **Changelog.** Add user-visible changes to [CHANGELOG.md](CHANGELOG.md).

## Reporting issues

Open an issue at <https://github.com/FrancisMahony/fantomLsp/issues>. Include:
- your Fantom/SkySpark and VS Code versions;
- the **Fantom LSP Launch** output;
- the **Fantom Language Server** output, captured with `fantom.trace.server` set to `"verbose"`.

## Releasing

See [docs/RELEASING.md](docs/RELEASING.md).

## License

This project is licensed under the [MIT License](LICENSE). By submitting a contribution, you agree that it is licensed under the same terms.
