# ConvertPdfEpubDjvu

Converts ebook files between **PDF**, **DJVU**, and **EPUB** formats.
For every book file found, the two missing format variants are created as siblings in the same directory.
The script is idempotent — re-running it only processes files that are not yet converted.

## What it does

| Source | Creates |
|--------|---------|
| `.pdf` | `.djvu` + `.epub` |
| `.djvu` | `.pdf` + `.epub` |
| `.epub` | `.pdf` + `.djvu` |

JSON sidecar files (same stem, `.json` extension) are copied from the source and updated with the new `format` field. If no sidecar exists for the source, a minimal stub is created.

## Requirements

```bash
sudo apt-get install djvulibre-bin pdf2djvu calibre jq
```

| Tool | Purpose |
|------|---------|
| `pdf2djvu` | PDF → DJVU |
| `ddjvu` (djvulibre) | DJVU → PDF |
| `ebook-convert` (calibre) | PDF/DJVU ↔ EPUB, EPUB → PDF |
| `jq` | JSON sidecar manipulation |

> **Note on scanned books:** Most chess books are scanned images rather than text PDFs.
> EPUB conversions of scanned files embed the pages as images — no OCR is performed.
> The files are fully usable on e-readers but won't have selectable text.

## Usage

```bash
chmod +x convert_formats.sh

# Preview what would be converted (no files written)
./convert_formats.sh --dry-run /srv/schach

# Run conversion
./convert_formats.sh /srv/schach
```

Progress and errors are logged to `<library_dir>/convert_formats.log`.

## Cronjob

To run nightly at 02:00:

```
0 2 * * * /opt/scripts/convert_formats.sh /srv/schach >> /var/log/chess_convert.log 2>&1
```

The lock file `/tmp/convert_formats_<hash>.lock` prevents concurrent runs if a previous job is still running.

## JSON sidecars

The script is designed to work alongside a sidecar-based library catalog where each book file has a matching `.json` file with the same stem:

```
Bobby Fischer Teaches Chess.pdf
Bobby Fischer Teaches Chess.json   ← {"title": "...", "format": "pdf", ...}
```

When a new format is created, its sidecar is derived from the source:

```
Bobby Fischer Teaches Chess.djvu
Bobby Fischer Teaches Chess.json   ← already exists, left untouched

Bobby Fischer Teaches Chess.epub
Bobby Fischer Teaches Chess.json   ← already exists, left untouched
```

Since all three format variants share the same filename stem, they share one sidecar. The `format` field reflects whichever format was present first; the actual file extensions on disk are the source of truth for availability.
