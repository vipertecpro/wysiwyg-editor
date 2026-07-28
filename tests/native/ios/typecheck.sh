#!/usr/bin/env bash
#
# Typecheck the whole iOS implementation against the iOS 15 simulator SDK.
#
# The plugin file references two symbols the NativePHP host app provides
# (BridgeFunction, LaravelBridge), so this compiles it alongside minimal stubs
# for them. Catches real compile errors without a full device build.
#
# Usage: tests/native/ios/typecheck.sh
#
set -euo pipefail

plugin_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source_file="$plugin_root/resources/ios/WysiwygEditorFunctions.swift"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

if ! command -v xcrun >/dev/null 2>&1; then
    echo "xcrun not found — install Xcode to run this check." >&2
    exit 1
fi

sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"

cat > "$work_dir/HostStubs.swift" <<'SWIFT'
import Foundation

// Minimal stand-ins for the symbols the NativePHP host project provides.
protocol BridgeFunction {
    func execute(parameters: [String: Any]) throws -> [String: Any]
}

final class LaravelBridge {
    static let shared = LaravelBridge()
    var send: ((String, [String: Any]) -> Void)?
}
SWIFT

swiftc -typecheck \
    -sdk "$sdk" \
    -target arm64-apple-ios15.0-simulator \
    "$work_dir/HostStubs.swift" \
    "$source_file"

echo "WysiwygEditorFunctions.swift typechecks against iOS 15."
