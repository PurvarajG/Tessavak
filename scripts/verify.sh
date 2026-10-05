#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

echo "==> swift package resolve"
swift package resolve

echo "==> swift build --build-tests"
swift build --build-tests

echo "==> swift test --parallel"
swift test --parallel

echo "==> swift format lint --recursive --strict Sources Tests Package.swift"
swift format lint --recursive --strict Sources Tests Package.swift

echo "==> checking TessavakCore for forbidden framework imports"
if rg -n 'import (SwiftUI|AppKit|SwiftData|CoreData|AVFoundation|CoreML)' Sources/TessavakCore; then
    echo "TessavakCore contains a forbidden framework import" >&2
    exit 1
fi

# TessavakCore imports Foundation only: any other import is a third-party or
# framework dependency creeping into the engine core.
echo "==> checking TessavakCore imports nothing but Foundation"
if rg -n --no-heading '^\s*import\s+' Sources/TessavakCore | grep -v 'import Foundation$'; then
    echo "TessavakCore imports a module other than Foundation" >&2
    exit 1
fi

# whisper.cpp arrives in Task 7 and must stay confined to the TessavakWhisper
# target; nothing else may link a recogniser implementation.
echo "==> checking whisper stays out of the core, adapters, packs, and bench"
if rg -n -i 'import (whisper|SwiftWhisper|whisper_cpp)' \
    Sources/TessavakCore Sources/TessavakAdapters Sources/TessavakPacks Sources/TessavakBench; then
    echo "found a whisper import outside the TessavakWhisper target" >&2
    exit 1
fi

# The benchmark report is written to VERIFY_REPORT_DIR when the caller sets
# it (CI sets this to a stable path so it can upload the report as a build
# artifact after this script exits). Otherwise a temporary directory is
# created and removed on exit, since local runs have nothing to collect it.
REPORT_DIR="${VERIFY_REPORT_DIR:-}"
CLEANUP_REPORT_DIR=0
if [[ -z "${REPORT_DIR}" ]]; then
    REPORT_DIR="$(mktemp -d)"
    CLEANUP_REPORT_DIR=1
    trap 'rm -rf "${REPORT_DIR}"' EXIT
fi
mkdir -p "${REPORT_DIR}"

echo "==> running release smoke benchmark into ${REPORT_DIR}"
swift run -c release tessavak-bench run \
    --manifest Fixtures/replay/smoke.json \
    --output "${REPORT_DIR}" \
    --baseline Fixtures/baseline/smoke-baseline.json

echo "==> scanning generated report and diagnostics for transcript/audio leakage"
if rg -n '"(text|transcript|audio|rawCandidate)"\s*:' "${REPORT_DIR}/report.json" Sources/TessavakCore/Types/Diagnostics.swift; then
    echo "found a forbidden transcript/audio field in the generated report or diagnostics" >&2
    exit 1
fi

echo "==> scanning tracked files for private corpus or generated report artifacts"
if git ls-files | rg '\.(wav|WAV|m4a|M4A|mp3|MP3|flac|FLAC|caf|CAF|aiff|AIFF|aac|AAC)$|^Reports/|Corpus/[Pp]rivate/'; then
    echo "found tracked private corpus or generated report files" >&2
    exit 1
fi

if [[ "${CLEANUP_REPORT_DIR}" -eq 0 ]]; then
    echo "==> benchmark report preserved at ${REPORT_DIR}"
fi

echo "verify.sh: all checks passed"
