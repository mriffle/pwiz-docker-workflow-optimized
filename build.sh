#!/usr/bin/env bash
# build.sh — Build the symlink-safe, workflow-pruned pwiz/Skyline Docker image.
#
# Pipeline:
#   1. Build wine-dotnet base (WINEDISTRO=devel)         ~25–40 min first run
#   2. Extract pwiz binaries from the upstream image     ~30 s
#   3. Prune to the workflow we actually run             instant
#   4. Build the final pwiz image                        ~1 min
#
# Stages 1 and 2 are skipped if their outputs already exist locally, so the
# script is safe to re-run. To force a rebuild, delete the outputs first:
#   docker rmi local/wine-dotnet:winedevel10.6-net4.8-x64
#   rm -rf ./pwiz-artifacts
#
# Tagging and pushing are NOT done by this script — see README.md.

set -euo pipefail

UPSTREAM_IMAGE="proteowizard/pwiz-skyline-i-agree-to-the-vendor-licenses:latest"
BASE_TAG="local/wine-dotnet:winedevel10.6-net4.8-x64"
FINAL_TAG="${FINAL_TAG:-pwiz-fresh-devel:latest}"
ARTIFACTS_DIR="./pwiz-artifacts"

cd "$(dirname "$0")"

command -v docker >/dev/null || { echo "ERROR: docker not in PATH" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Stage 1: wine-dotnet base
# ---------------------------------------------------------------------------
if docker image inspect "$BASE_TAG" >/dev/null 2>&1; then
    echo ">>> [1/4] $BASE_TAG already present — skipping base build"
else
    echo ">>> [1/4] Building $BASE_TAG (long step, ~25–40 min: winetricks dotnet48 dominates)"
    docker build -t "$BASE_TAG" -f Dockerfile.wine-dotnet-devel .
fi

# ---------------------------------------------------------------------------
# Stage 2 + 3: extract and prune pwiz binaries
# ---------------------------------------------------------------------------
if [[ -d "$ARTIFACTS_DIR" ]]; then
    echo ">>> [2/4] $ARTIFACTS_DIR already present — skipping extract+prune"
else
    echo ">>> [2/4] Extracting pwiz tree from $UPSTREAM_IMAGE"
    docker pull "$UPSTREAM_IMAGE"
    cid=$(docker create "$UPSTREAM_IMAGE")
    docker cp "$cid:/wineprefix64/drive_c/pwiz" "$ARTIFACTS_DIR"
    docker rm "$cid" >/dev/null
    echo "    extracted: $(du -sh "$ARTIFACTS_DIR" | cut -f1)"

    echo ">>> [3/4] Pruning workflow-irrelevant artifacts"

    # Skyline subtree
    rm -rf "$ARTIFACTS_DIR/skyline/CachedDownloadsForTests"
    rm -rf "$ARTIFACTS_DIR/skyline/Tools_CFTKIC31_en-US"
    find "$ARTIFACTS_DIR/skyline" -maxdepth 1 -name '*.pdb'    -delete
    find "$ARTIFACTS_DIR/skyline" -maxdepth 1 -name 'Test*.dll' -delete

    # pwiz CLI tools we don't run (everything except msconvert)
    for tool in msaccess msbenchmark mscat msdiff msdir mspicture peakaboo \
                qtofpeakpicker txt2mzml chainsaw idconvert idcat msistats \
                pepcat pepsum seems MSConvertGUI; do
        rm -f "$ARTIFACTS_DIR/${tool}.exe" \
              "$ARTIFACTS_DIR/${tool}.exe.config" \
              "$ARTIFACTS_DIR/${tool}.exe.manifest"
    done

    echo "    post-prune: $(du -sh "$ARTIFACTS_DIR" | cut -f1) (expected ~395 MB)"
fi

# ---------------------------------------------------------------------------
# Stage 4: final image
# ---------------------------------------------------------------------------
echo ">>> [4/4] Building $FINAL_TAG"
docker build -t "$FINAL_TAG" -f Dockerfile.pwiz-fresh-devel .

echo ""
echo "=== Build complete ==="
docker images "$FINAL_TAG" --format "{{.Repository}}:{{.Tag}}  id={{.ID}}  size={{.Size}}"
echo ""
echo "Next: smoke-test, then tag and push. See README.md."
