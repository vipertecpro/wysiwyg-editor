#!/usr/bin/env bash
#
# Run the Android HtmlCoder round-trip tests.
#
# The coder lives inside resources/android/WysiwygEditorFunctions.kt alongside
# Compose/Android code that can't compile on the JVM, so this slices out the
# pure-Kotlin document model + HtmlCoder section (delimited by the
# "── Document model" and "── Toolbar icons" banners) and compiles it together
# with the test file.
#
# Needs a Kotlin compiler. Either:
#   • kotlinc on PATH            (brew install kotlin), or
#   • gradle on PATH, or
#   • GRADLE_CMD=/path/to/gradlew — e.g. the wrapper inside any NativePHP
#     Android project: <app>/nativephp/android/gradlew
#
# Usage: tests/native/android/run.sh
#
set -euo pipefail

plugin_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source_file="$plugin_root/resources/android/WysiwygEditorFunctions.kt"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

start="$(grep -n '^// ── Document model' "$source_file" | head -1 | cut -d: -f1)"
end="$(grep -n '^// ── Toolbar icons' "$source_file" | head -1 | cut -d: -f1)"

if [[ -z "$start" || -z "$end" ]]; then
    echo "Could not locate the document model / toolbar icon banners in $source_file." >&2
    echo "The section markers moved — update this script to match." >&2
    exit 1
fi

sed -n "${start},$((end - 1))p" "$source_file" > "$work_dir/Coder.kt"
cp "$plugin_root/tests/native/android/HtmlCoderTests.kt" "$work_dir/HtmlCoderTests.kt"

# The slice must not have picked up any Android imports, or it won't run on
# the plain JVM — fail loudly rather than emitting a confusing compiler error.
if grep -qE '^import (android|androidx)\.' "$work_dir/Coder.kt"; then
    echo "The sliced coder references the Android framework — it is no longer pure Kotlin." >&2
    exit 1
fi

if command -v kotlinc >/dev/null 2>&1; then
    kotlinc "$work_dir/Coder.kt" "$work_dir/HtmlCoderTests.kt" -include-runtime -d "$work_dir/tests.jar" 2>/dev/null
    java -jar "$work_dir/tests.jar"
    exit $?
fi

gradle_cmd="${GRADLE_CMD:-}"
if [[ -z "$gradle_cmd" ]] && command -v gradle >/dev/null 2>&1; then
    gradle_cmd="gradle"
fi

if [[ -z "$gradle_cmd" ]]; then
    echo "No Kotlin compiler found." >&2
    echo "Install one with 'brew install kotlin', or point GRADLE_CMD at a Gradle wrapper:" >&2
    echo "  GRADLE_CMD=/path/to/app/nativephp/android/gradlew tests/native/android/run.sh" >&2
    exit 1
fi

# Fall back to a throwaway Kotlin/JVM Gradle project.
mkdir -p "$work_dir/project/src/main/kotlin"
mv "$work_dir/Coder.kt" "$work_dir/HtmlCoderTests.kt" "$work_dir/project/src/main/kotlin/"

cat > "$work_dir/project/settings.gradle.kts" <<'GRADLE'
rootProject.name = "htmlcoder-tests"
GRADLE

cat > "$work_dir/project/build.gradle.kts" <<'GRADLE'
plugins {
    kotlin("jvm") version "2.0.21"
    application
}
repositories { mavenCentral() }
application { mainClass.set("HtmlCoderTestsKt") }
GRADLE

# A wrapper only runs from its own project unless pointed elsewhere; -p does that.
out_file="$work_dir/output.txt"
"$gradle_cmd" -p "$work_dir/project" run -q --console=plain 2>&1 \
    | grep -v "^e: The daemon" | tee "$out_file"

# A harness that compiles nothing must not look like a harness that passed.
# Its iOS twin once sliced out a region that no longer compiled, and a
# truncated view of the output still read as green.
minimum=60
ran="$(grep -c '✓' "$out_file" || true)"

if [[ "$ran" -lt "$minimum" ]]; then
    echo "" >&2
    echo "Only $ran checks ran (expected at least $minimum) — the harness is not exercising the coder." >&2
    exit 1
fi
