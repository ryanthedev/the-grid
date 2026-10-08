#!/bin/bash
# Embed skills/thegrid/SKILL.md into the CLI as a Swift raw string so
# `thegrid mcp install` can write it without shipping a resource bundle.
set -euo pipefail

SRC="${1:-skills/thegrid/SKILL.md}"
OUT="${2:-grid-server/Sources/GridCLI/EmbeddedSkill.swift}"

if grep -q '"""##' "$SRC"; then
    echo "generate-skill: $SRC contains the raw-string terminator \"\"\"## — pick another delimiter" >&2
    exit 1
fi

{
    echo "// Auto-generated from $SRC by scripts/generate-skill.sh - do not edit"
    echo "import Foundation"
    echo ""
    echo "enum EmbeddedSkill {"
    echo "    static let sourcePath = \"$SRC\""
    echo "    static let markdown = ##\"\"\""
    cat "$SRC"
    # Swift drops the newline before the closing delimiter; keep the file's.
    echo ""
    echo "\"\"\"##"
    echo ""
    echo "    static func write(to url: URL) throws {"
    echo "        try markdown.write(to: url, atomically: true, encoding: .utf8)"
    echo "    }"
    echo "}"
} > "$OUT"
