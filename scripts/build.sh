#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== Building Fantom LSP Server ==="
cd "$ROOT_DIR/server"
fan build.fan

echo "=== Copying pod to client/server/ ==="
if [ -z "$FAN_HOME" ]; then
  echo "ERROR: FAN_HOME is not set. Cannot locate compiled pod."
  exit 1
fi
mkdir -p "$ROOT_DIR/client/server/lib/fan"
cp "$FAN_HOME/lib/fan/fantomLsp.pod" "$ROOT_DIR/client/server/lib/fan/fantomLsp.pod"
echo "Copied fantomLsp.pod to client/server/lib/fan/"

echo "=== Building VS Code Client ==="
cd "$ROOT_DIR/client"
npm install
npm run compile

echo "=== Build complete ==="
