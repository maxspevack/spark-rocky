#!/usr/bin/env bash
# fetch.sh — reproduce the spark-arena data pulls used in this repo.
#
# Given a leaderboard entry's submission id (the `benchmarkId` field in the snapshot, e.g. sub1772533296511),
# this resolves its recipe-permalink UUID via public Firestore, then pulls the full published benchmark
# matrix and the exact serve recipe. These are the same pulls documented in docs/benchmark/reproduce-pipeline.md.
#
# Usage:   ./fetch.sh <sub-id>            e.g. ./fetch.sh sub1772533296511   (Qwen3.5-35B-A3B-FP8)
#                                              ./fetch.sh sub1777989095056   (LFM2.5-350M)
# Output:  raw-<sub-id>.md  (the published llama-benchy matrix)  and  recipe-<sub-id>.yaml
#
# Note on the snapshot: spark-arena-snapshot-*.json is a *point-in-time* capture of the live leaderboard
# (the board changes as people submit). Treat it as a dated reference, not a live feed. The per-entry pulls
# below ARE reproducible against the live site for as long as the entry exists.
set -euo pipefail

SUB="${1:?usage: ./fetch.sh <sub-id>   (a benchmarkId from the snapshot, e.g. sub1772533296511)}"

# spark-arena's own public Firebase web apiKey (embedded in the site's JS bundle — not a secret of ours).
KEY="AIzaSyDy4gDrfBr0LnXdN7N2CT7IUq7oIQCBrpI"
FS="https://firestore.googleapis.com/v1/projects/spark-arena/databases/(default)/documents/benchmarks"

echo "resolving recipe permalink for $SUB ..."
UUID=$(curl -fsSL "$FS/$SUB?key=$KEY" \
  | grep -A1 '"recipePermalinkId"' | grep stringValue \
  | sed -E 's/.*"stringValue": *"([^"]+)".*/\1/')
[ -n "$UUID" ] || { echo "could not resolve recipePermalinkId for $SUB" >&2; exit 1; }
echo "  -> $UUID"

echo "pulling published benchmark matrix -> raw-$SUB.md"
curl -fsSL "https://spark-arena.com/api/benchmarks/$UUID/raw" -o "raw-$SUB.md"

echo "pulling serve recipe -> recipe-$SUB.yaml"
curl -fsSL "https://spark-arena.com/api/recipes/$UUID/raw" -o "recipe-$SUB.yaml"

echo "done. (raw-$SUB.md = the published matrix we compare against; recipe-$SUB.yaml = the verbatim serve config)"
