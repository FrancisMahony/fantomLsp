#!/bin/bash
# Builds the server pod, bundles it into the client, compiles the client and
# packages the VSIX. Requires fan, node/npm and FAN_HOME (or fan on PATH).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== Building Fantom LSP Server ==="
cd "$ROOT_DIR/server"
fan build.fan

echo "=== Copying pod to client/server/ ==="
mkdir -p "$ROOT_DIR/client/server/lib/fan"
cp "$ROOT_DIR/server/lib/fan/fantomLsp.pod" "$ROOT_DIR/client/server/lib/fan/fantomLsp.pod"
echo "Copied fantomLsp.pod to client/server/lib/fan/"

echo "=== Building VS Code Client ==="
cd "$ROOT_DIR/client"
npm install
npm run compile

echo "=== Packaging VSIX ==="
cleanup() { rm -f "$ROOT_DIR/client/README.md" "$ROOT_DIR/client/CHANGELOG.md" "$ROOT_DIR/client/LICENSE"; }
trap cleanup EXIT
cp "$ROOT_DIR/README.md" "$ROOT_DIR/CHANGELOG.md" "$ROOT_DIR/LICENSE" "$ROOT_DIR/client/"
npx --yes @vscode/vsce package

echo "=== Build complete ==="
ls "$ROOT_DIR"/client/*.vsix
