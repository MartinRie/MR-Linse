#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/.build/checks"
mkdir -p "$OUT"
swiftc "$ROOT/Sources/SoulearLupe/CameraSettings.swift" \
  "$ROOT/Sources/SoulearLupe/CameraProtocol.swift" \
  "$ROOT/Sources/SoulearLupe/BridgeReader.swift" \
  "$ROOT/Sources/SoulearLupe/PreviewPipeline.swift" \
  "$ROOT/Tests/RuntimeChecks.swift" -o "$OUT/runtime-checks"
"$OUT/runtime-checks"
