#!/usr/bin/env bash
#
# Run the iOS HtmlCoder round-trip tests.
#
# The coder lives inside resources/ios/WysiwygEditorFunctions.swift alongside
# UIKit/SwiftUI code that can't compile on macOS, so this slices out the
# pure-Foundation document model + HtmlCoder section (delimited by the
# "// MARK: - Document model" and "// MARK: - Styler" markers) and compiles it
# together with the test file.
#
# Usage: tests/native/ios/run.sh
#
set -euo pipefail

plugin_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source_file="$plugin_root/resources/ios/WysiwygEditorFunctions.swift"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

if ! command -v swiftc >/dev/null 2>&1; then
    echo "swiftc not found — install the Xcode command line tools to run these tests." >&2
    exit 1
fi

start="$(grep -n '^// MARK: - Document model' "$source_file" | head -1 | cut -d: -f1)"
end="$(grep -n '^// MARK: - Styler' "$source_file" | head -1 | cut -d: -f1)"

if [[ -z "$start" || -z "$end" ]]; then
    echo "Could not locate the document model / styler markers in $source_file." >&2
    echo "The section markers moved — update this script to match." >&2
    exit 1
fi

{
    echo "import Foundation"
    sed -n "${start},$((end - 1))p" "$source_file"
} > "$work_dir/Coder.swift"

cp "$plugin_root/tests/native/ios/HtmlCoderTests.swift" "$work_dir/main.swift"

swiftc -o "$work_dir/tests" "$work_dir/Coder.swift" "$work_dir/main.swift"
"$work_dir/tests"
