#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== Building fantomLsp pod ==="
cd "$ROOT_DIR/server"
fan build.fan

echo ""
echo "=== Running all tests ==="
echo ""

fan fantomLsp::HoverProviderTest
fan fantomLsp::CompletionProviderTest
fan fantomLsp::SignatureHelpProviderTest
fan fantomLsp::JsonRpcTest
fan fantomLsp::LspMessagesTest
fan fantomLsp::SerializationTest
fan fantomLsp::ParserTest
fan fantomLsp::TextDocumentManagerTest
fan fantomLsp::LspUtilsTest

echo ""
echo "=== All tests passed ==="
