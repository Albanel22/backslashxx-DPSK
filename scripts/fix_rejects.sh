#!/bin/bash
# scripts/fix_rejects.sh
# Small helper to fix common .rej hunks by pulling upstream copies for fs/open.c and fs/proc/task_mmu.c
# Usage: bash scripts/fix_rejects.sh

set -euo pipefail

echo "[fix_rejects] running in: $(pwd)"

# Upstream commit to pull files from (LineageOS android_kernel_motorola_sm8250)
UPSTREAM_COMMIT="217104287f99519fb701eb66d28ea8a3cfb2ba60"
UPSTREAM_RAW_BASE="https://raw.githubusercontent.com/LineageOS/android_kernel_motorola_sm8250/${UPSTREAM_COMMIT}"

fix_file() {
    local localpath="$1" upstreampath="$2"
    if [ -f "${localpath}.rej" ]; then
        echo "[fix_rejects] Detected ${localpath}.rej — attempting to replace ${localpath} from upstream"
        if [ -f "$localpath" ]; then
            cp -a "$localpath" "${localpath}.bak.$(date +%s)" || true
            echo "[fix_rejects] Backup saved: ${localpath}.bak.*"
        fi
        url="${UPSTREAM_RAW_BASE}/${upstreampath}"
        echo "[fix_rejects] Fetching $url"
        if curl -fsS --retry 3 "$url" -o "${localpath}.new"; then
            mv "${localpath}.new" "$localpath"
            chmod 644 "$localpath" || true
            rm -f "${localpath}.rej" || true
            echo "[fix_rejects] Replaced $localpath with upstream copy and removed .rej"
        else
            echo "[fix_rejects] ERROR: failed to fetch $url — leaving ${localpath}.rej as-is" >&2
            rm -f "${localpath}.new" || true
            return 1
        fi
    else
        echo "[fix_rejects] No ${localpath}.rej found — skipping"
    fi
}

# Files commonly rejected by susfs patches
fix_file "fs/open.c" "fs/open.c"
fix_file "fs/proc/task_mmu.c" "fs/proc/task_mmu.c"

# Clean any leftover rejected hunks list
find . -name "*.rej" -print -exec rm -f {} \; || true

echo "[fix_rejects] Done. Please re-run your build (DRY_RUN=1 ./build.sh) to verify."