#!/usr/bin/env bash
# convert_formats.sh — Convert ebook files between PDF, DJVU, and EPUB.
# Creates sibling files in the same directory as the source.
# Skips conversions where the target file already exists (idempotent).
# Also creates/updates JSON sidecars for newly converted files.
#
# Usage:
#   ./convert_formats.sh [--dry-run] <library_dir>
#
# Required tools:
#   pdf2djvu      — PDF → DJVU        (apt install pdf2djvu)
#   ddjvu         — DJVU → PDF        (apt install djvulibre-bin)
#   ebook-convert — PDF/DJVU ↔ EPUB   (apt install calibre)
#   jq            — JSON manipulation  (apt install jq)
#
# Crontab example (run every night at 02:00):
#   0 2 * * * /opt/scripts/convert_formats.sh /srv/schach >> /var/log/chess_convert.log 2>&1

set -euo pipefail

# ── Args ──────────────────────────────────────────────────────────────────────
DRY_RUN=false
LIBRARY_DIR=""

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        *)         LIBRARY_DIR="$arg" ;;
    esac
done

if [[ -z "$LIBRARY_DIR" ]]; then
    echo "Usage: $0 [--dry-run] <library_dir>" >&2
    exit 1
fi

if [[ ! -d "$LIBRARY_DIR" ]]; then
    echo "ERROR: Directory not found: $LIBRARY_DIR" >&2
    exit 1
fi

# ── Lock file (prevent concurrent runs) ───────────────────────────────────────
LOCK_FILE="/tmp/convert_formats_$(echo "$LIBRARY_DIR" | md5sum | cut -c1-8).lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "Another instance is already running (lock: $LOCK_FILE). Exiting." >&2
    exit 0
fi

# ── Logging ───────────────────────────────────────────────────────────────────
LOG_FILE="$LIBRARY_DIR/convert_formats.log"
STATS_CONVERTED=0
STATS_SKIPPED=0
STATS_FAILED=0

log() {
    local level="$1"; shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" | tee -a "$LOG_FILE"
}
info()  { log "INFO " "$@"; }
warn()  { log "WARN " "$@"; }
error() { log "ERROR" "$@"; }

# ── Dependency check ──────────────────────────────────────────────────────────
MISSING_TOOLS=()
for tool in pdf2djvu ddjvu ebook-convert jq; do
    command -v "$tool" &>/dev/null || MISSING_TOOLS+=("$tool")
done

if [[ ${#MISSING_TOOLS[@]} -gt 0 ]]; then
    error "Missing tools: ${MISSING_TOOLS[*]}"
    error "Install with: sudo apt-get install djvulibre-bin pdf2djvu calibre jq"
    exit 1
fi

# ── Sidecar handling ──────────────────────────────────────────────────────────
# Creates a JSON sidecar for a newly converted file.
# If a sidecar already exists (carried over from source), nothing is done.
make_sidecar() {
    local source_sidecar="$1"  # JSON of the source file (may not exist)
    local target_file="$2"     # newly converted file path
    local target_fmt="$3"      # "pdf" | "djvu" | "epub"

    local target_sidecar="${target_file%.*}.json"

    # Sidecar already exists — leave it alone
    [[ -f "$target_sidecar" ]] && return 0

    if [[ -f "$source_sidecar" ]]; then
        jq --arg fmt "$target_fmt" '.format = $fmt' "$source_sidecar" > "$target_sidecar"
        info "  Sidecar created: $(basename "$target_sidecar")"
    else
        # No source sidecar — create minimal stub
        jq -n --arg fmt "$target_fmt" \
            '{"title":null,"author":[],"year":null,"tags":[],"format":$fmt,"size":null,"targetMinElo":null,"favorite":[]}' \
            > "$target_sidecar"
        warn "  Stub sidecar (no source metadata): $(basename "$target_sidecar")"
    fi
}

# ── Conversion helpers ────────────────────────────────────────────────────────
run_cmd() {
    # Run command, append stdout+stderr to log, return exit code
    "$@" >> "$LOG_FILE" 2>&1
}

_do_convert() {
    local label="$1"  # e.g. "PDF→DJVU"
    local src="$2"
    local dst="$3"
    local sidecar="$4"
    local fmt="$5"
    shift 5
    # remaining args: the actual conversion command

    if [[ -f "$dst" ]]; then
        (( STATS_SKIPPED++ )) || true
        return 0
    fi

    info "$label: $(basename "$src")"

    if $DRY_RUN; then
        (( STATS_CONVERTED++ )) || true
        return 0
    fi

    if run_cmd "$@"; then
        make_sidecar "$sidecar" "$dst" "$fmt"
        (( STATS_CONVERTED++ )) || true
    else
        error "  FAILED: $(basename "$src")"
        rm -f "$dst"
        (( STATS_FAILED++ )) || true
    fi
}

# ── Per-format conversions ────────────────────────────────────────────────────
convert_pdf_to_djvu() {
    local src="$1"
    _do_convert "PDF→DJVU" "$src" "${src%.*}.djvu" "${src%.*}.json" "djvu" \
        pdf2djvu --quiet -o "${src%.*}.djvu" "$src"
}

convert_pdf_to_epub() {
    local src="$1"
    _do_convert "PDF→EPUB" "$src" "${src%.*}.epub" "${src%.*}.json" "epub" \
        ebook-convert "$src" "${src%.*}.epub"
}

convert_djvu_to_pdf() {
    local src="$1"
    _do_convert "DJVU→PDF" "$src" "${src%.*}.pdf" "${src%.*}.json" "pdf" \
        ddjvu -format=pdf -quality=85 "$src" "${src%.*}.pdf"
}

convert_djvu_to_epub() {
    local src="$1"
    _do_convert "DJVU→EPUB" "$src" "${src%.*}.epub" "${src%.*}.json" "epub" \
        ebook-convert "$src" "${src%.*}.epub"
}

convert_epub_to_pdf() {
    local src="$1"
    _do_convert "EPUB→PDF" "$src" "${src%.*}.pdf" "${src%.*}.json" "pdf" \
        ebook-convert "$src" "${src%.*}.pdf"
}

convert_epub_to_djvu() {
    local src="$1"
    local dst="${src%.*}.djvu"
    local tmp="${src%.*}._converting_.pdf"

    if [[ -f "$dst" ]]; then
        (( STATS_SKIPPED++ )) || true
        return 0
    fi

    info "EPUB→DJVU: $(basename "$src")"
    $DRY_RUN && { (( STATS_CONVERTED++ )) || true; return 0; }

    if run_cmd ebook-convert "$src" "$tmp" && \
       run_cmd pdf2djvu --quiet -o "$dst" "$tmp"; then
        rm -f "$tmp"
        make_sidecar "${src%.*}.json" "$dst" "djvu"
        (( STATS_CONVERTED++ )) || true
    else
        error "  FAILED: $(basename "$src")"
        rm -f "$dst" "$tmp"
        (( STATS_FAILED++ )) || true
    fi
}

# ── Main loop ─────────────────────────────────────────────────────────────────
info "=== Starting format conversion ==="
info "Library : $LIBRARY_DIR"
info "Dry run : $DRY_RUN"

while IFS= read -r -d '' file; do
    # Skip leftover temp files from interrupted runs
    [[ "$file" == *"._converting_."* ]] && continue

    ext_lower="${file##*.}"
    ext_lower="${ext_lower,,}"

    case "$ext_lower" in
        pdf)
            convert_pdf_to_djvu "$file"
            convert_pdf_to_epub "$file"
            ;;
        djvu|djv)
            convert_djvu_to_pdf  "$file"
            convert_djvu_to_epub "$file"
            ;;
        epub)
            convert_epub_to_pdf  "$file"
            convert_epub_to_djvu "$file"
            ;;
    esac

done < <(find "$LIBRARY_DIR" \
    -not -path "*/\.*" \
    -type f \( \
        -iname "*.pdf"  -o \
        -iname "*.djvu" -o \
        -iname "*.djv"  -o \
        -iname "*.epub" \
    \) -print0 | sort -z)

info "=== Done ==="
info "Converted : $STATS_CONVERTED"
info "Skipped   : $STATS_SKIPPED (already existed)"
info "Failed    : $STATS_FAILED"
