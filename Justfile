# Justfile pipeline to extract bbox (z=4/14/5) from PMTiles (Mapterhorn + BVMap)
#
# Tile reference: z=4, x=14, y=5
# Corresponds to 16 tiles at z=6: x=56..59, y=20..23
#
# Dependencies: go-pmtiles (pmtiles), jq, bash
#
# Usage:
#   just all          # run full pipeline
#   just bbox         # print computed bounding box
#   just bvmap        # extract BVMap (sets metadata description + last-updated)
#   just mapterhorn-base   # extract Mapterhorn base tiles
#   just mapterhorn-high   # extract all 16 high-zoom tiles
#   just mapterhorn-merge  # merge all Mapterhorn outputs (sets metadata description + last-updated)

# ── Configurable paths ────────────────────────────────────────────────────────

# Source files
bvmap_src      := "optimal_bvmap-v1.pmtiles"
mapterhorn_src := "mapterhorn.pmtiles"

# High-zoom tile directory (where 6-x-y.pmtiles files live)
high_zoom_dir  := "."

# Output directory
out_dir        := "."

# go-pmtiles binary name (override if installed under a different name)
pmtiles        := "pmtiles"

# ── Derived constants ─────────────────────────────────────────────────────────

# Tile 4/14/5 bounding box (Web Mercator)
# minLon = 14/16 * 360 - 180 = 135.0
# maxLon = 15/16 * 360 - 180 = 157.5
# maxLat = atan(sinh(π*(1 - 2*5/16))) * 180/π ≈ 55.77657301866769
# minLat = atan(sinh(π*(1 - 2*6/16))) * 180/π ≈ 40.97989806962013
bbox_coords := "135.0,40.97989806962013,157.5,55.77657301866769"

# Output filenames
bvmap_out      := out_dir / "bvmap_4_14_5.pmtiles"
mapterhorn_out := out_dir / "mapterhorn_4_14_5.pmtiles"

# Intermediate outputs
mapterhorn_base_out := out_dir / "mapterhorn_base_4_14_5.pmtiles"

# ── Default target ─────────────────────────────────────────────────────────────

default: all

# ── bbox ───────────────────────────────────────────────────────────────────────

# Print the bounding box derived from tile 4/14/5
bbox:
    @echo "Tile 4/14/5 → bbox: {{bbox_coords}}"

# ── BVMap ──────────────────────────────────────────────────────────────────────

# Extract BVMap tiles within the bbox, then stamp metadata description and last-updated date
bvmap:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "[bvmap] Extracting {{bvmap_src}} → {{bvmap_out}}"
    {{pmtiles}} extract {{bvmap_src}} {{bvmap_out}} --bbox={{bbox_coords}}
    echo "[bvmap] Applying metadata to {{bvmap_out}}"
    src_meta=$({{pmtiles}} show {{bvmap_src}} --metadata 2>/dev/null || echo '{}')
    last_updated=$(printf '%s' "$src_meta" \
      | jq -r '.last_updated // .lastModified // .modified // ""')
    [ -z "$last_updated" ] && last_updated=$(date -u +%Y-%m-%d)
    meta_tmp=$(mktemp /tmp/bvmap_4_14_5_meta.XXXXXX.json)
    printf '%s' "$src_meta" \
      | jq --arg desc \
           "BVMap (optimal_bvmap-v1) clipped to tile 4/14/5 (bbox: {{bbox_coords}})" \
           --arg upd "$last_updated" \
           '. + {description: $desc, last_updated: $upd}' \
      > "$meta_tmp"
    {{pmtiles}} edit {{bvmap_out}} --metadata="$meta_tmp"
    rm -f "$meta_tmp"
    echo "[bvmap] Done: {{bvmap_out}} (last_updated: $last_updated)"

# ── Mapterhorn ─────────────────────────────────────────────────────────────────

# Extract base (low–mid zoom) Mapterhorn tiles within the bbox
mapterhorn-base:
    @echo "[mapterhorn-base] Extracting {{mapterhorn_src}} → {{mapterhorn_base_out}}"
    {{pmtiles}} extract {{mapterhorn_src}} {{mapterhorn_base_out}} --bbox={{bbox_coords}}
    @echo "[mapterhorn-base] Done: {{mapterhorn_base_out}}"

# Extract all 16 high-zoom tiles (z=6, x=56..59, y=20..23) within the bbox
# Tiles are processed in parallel; script waits for all to finish.
mapterhorn-high:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "[mapterhorn-high] Processing 16 high-zoom tiles in parallel…"
    pids=()
    for x in 56 57 58 59; do
      for y in 20 21 22 23; do
        src="{{high_zoom_dir}}/6-${x}-${y}.pmtiles"
        dst="{{out_dir}}/6-${x}-${y}_extract.pmtiles"
        echo "  extract ${src} → ${dst}"
        {{pmtiles}} extract "${src}" "${dst}" --bbox={{bbox_coords}} &
        pids+=($!)
      done
    done
    for pid in "${pids[@]}"; do
      wait "$pid"
    done
    echo "[mapterhorn-high] All high-zoom extractions complete."

# Merge base extract + all 16 high-zoom extracts → final mapterhorn output,
# then stamp metadata description and latest last-updated date from all 17 sources
mapterhorn-merge: mapterhorn-base mapterhorn-high
    #!/usr/bin/env bash
    set -euo pipefail
    echo "[mapterhorn-merge] Collecting inputs…"
    inputs=("{{mapterhorn_base_out}}")
    for x in 56 57 58 59; do
      for y in 20 21 22 23; do
        inputs+=("{{out_dir}}/6-${x}-${y}_extract.pmtiles")
      done
    done
    echo "[mapterhorn-merge] Merging ${#inputs[@]} files → {{mapterhorn_out}}"
    {{pmtiles}} merge {{mapterhorn_out}} "${inputs[@]}"
    echo "[mapterhorn-merge] Scanning 17 source files for latest last-updated date…"
    all_srcs=("{{mapterhorn_src}}")
    for x in 56 57 58 59; do
      for y in 20 21 22 23; do
        all_srcs+=("{{high_zoom_dir}}/6-${x}-${y}.pmtiles")
      done
    done
    latest_date=""
    for src in "${all_srcs[@]}"; do
      d=$({{pmtiles}} show "$src" --metadata 2>/dev/null \
          | jq -r '.last_updated // .lastModified // .modified // ""' \
          2>/dev/null || true)
      # ISO 8601 (YYYY-MM-DD) dates compare correctly as strings
      [[ "$d" > "$latest_date" ]] && latest_date="$d"
    done
    [ -z "$latest_date" ] && latest_date=$(date -u +%Y-%m-%d)
    echo "[mapterhorn-merge] Applying metadata to {{mapterhorn_out}} (last_updated: $latest_date)"
    meta_tmp=$(mktemp /tmp/mapterhorn_4_14_5_meta.XXXXXX.json)
    {{pmtiles}} show {{mapterhorn_out}} --metadata 2>/dev/null \
      | jq --arg desc \
           "Mapterhorn clipped to tile 4/14/5 (bbox: {{bbox_coords}}), merged from base and 16 z=6 high-zoom tiles" \
           --arg upd "$latest_date" \
           '. + {description: $desc, last_updated: $upd}' \
      > "$meta_tmp"
    {{pmtiles}} edit {{mapterhorn_out}} --metadata="$meta_tmp"
    rm -f "$meta_tmp"
    echo "[mapterhorn-merge] Done: {{mapterhorn_out}}"

# ── all ────────────────────────────────────────────────────────────────────────

# Run the full pipeline
all: bvmap mapterhorn-merge
    @echo "Pipeline complete."
    @echo "  BVMap output       : {{bvmap_out}}"
    @echo "  Mapterhorn output  : {{mapterhorn_out}}"
