#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== Building Fantom LSP Server ==="
cd "$ROOT_DIR/server"
fan build.fan

echo "=== Building VS Code Client ==="
cd "$ROOT_DIR/client"
npm install
npm run compile

echo "=== Build complete ==="
