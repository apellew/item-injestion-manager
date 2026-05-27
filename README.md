# item-ingestion-manager

A small, extensible zsh-based media ingestion pipeline. Files dropped into local "ingest" directories are validated, normalised, and moved into a media library elsewhere (often a NAS).

A parent orchestrator script runs continuously and discovers per-media-type child scripts on a fixed loop. Currently shipped children target [Jellyfin](https://jellyfin.org/) (video `.m4v`) and [AudioBookShelf](https://www.audiobookshelf.org/) (audiobooks `.mp3`), but the orchestrator is media-agnostic — see [Adding a new child](#adding-a-new-child).

## Contents

| Script | Role |
|---|---|
| [`scripts/ingest.zsh`](scripts/ingest.zsh) | Parent orchestrator. Runs each `ingest-*.zsh` child every 120 s. Sleeps for an hour and rechecks when the library root is unreachable (e.g. NAS off-network). |
| [`scripts/ingest-video.zsh`](scripts/ingest-video.zsh) | Video child. Validates `.m4v` files (HEVC/H.265, minimum duration), classifies each as TV episode or Movie, and moves into a Jellyfin-style library layout. Conflict resolution by resolution + file size. |
| [`scripts/ingest-audiobooks.zsh`](scripts/ingest-audiobooks.zsh) | Audiobook child for AudioBookShelf. Per-mp3 quality comparison via `ffprobe` with coupled metadata refresh. Uses a staging directory so ABS doesn't pick up half-copied files. |
| [`scripts/.env.template`](scripts/.env.template) | Annotated configuration template. Copy to `scripts/.env` and edit. |

## Requirements

- **zsh** (the scripts use zsh-specific features like `EXTENDED_GLOB`, `zstat`, and parameter expansion modifiers).
- **ffprobe** (part of [ffmpeg](https://ffmpeg.org/), e.g. `brew install ffmpeg`).
- Optional: **lsof** — used for mid-copy detection. Falls back to size-stability sampling if not present.
- macOS or Linux. Developed primarily on macOS; should work on Linux unchanged but is not regularly tested there.

## Quick start

```sh
git clone https://github.com/<your-account>/item-ingestion-manager.git
cd item-ingestion-manager
chmod +x scripts/*.zsh

# Create your local config from the template, then fill in the two paths.
cp scripts/.env.template scripts/.env
$EDITOR scripts/.env

# Dry-run first — see what it would do without touching any files.
./scripts/ingest.zsh DEBUG
```

`DEBUG` is an optional positional flag. When passed, every `mkdir`, `cp`, `mv`, `rm`, and `rmdir` is logged as `[DEBUG] would …` and **not** performed. Always run with `DEBUG` first against a new library root to verify the planned operations look right.

Once you're happy with the dry-run output, run without the flag:

```sh
./scripts/ingest.zsh
```

## Configuration

All runtime configuration lives in `scripts/.env`, which is gitignored. Ship a fresh checkout with no `.env` and the scripts will exit immediately with instructions to copy the template:

```
FATAL: configuration file not found at .../scripts/.env

A template is shipped at .../scripts/.env.template
Copy it and fill in your paths, then re-run this script:

    cp '.../scripts/.env.template' '.../scripts/.env'
    $EDITOR '.../scripts/.env'
```

The template documents each key. The required minimum:

```zsh
export INGEST_ROOT="/path/to/your/ingest"
export LIBRARY_ROOT="/path/to/your/library"
```

Optional keys override defaults:

```zsh
# Audiobook library lives somewhere other than <LIBRARY_ROOT>/ABS Audiobooks
# (e.g. a different volume, or the default ABS "Audiobooks" folder name).
export ABS_LIBRARY_DIR="/path/to/your/audiobookshelf/Audiobooks"
```

Both children read the same `.env` file (sibling of the orchestrator), so configuration is shared automatically.

## Directory layout

Children derive their working subdirectories from the configured roots:

```
$INGEST_ROOT/
├── ingest-video/                       (video child watches this)
├── ingest-video_rejected/
├── ingest-audiobook/                   (audiobook child watches this)
└── ingest-audiobook_rejected/

$LIBRARY_ROOT/
├── Movies/                             (Jellyfin)
└── TV/                                 (Jellyfin)
```

The audiobook live and staging directories default to `$LIBRARY_ROOT/ABS Audiobooks` and `$LIBRARY_ROOT/ABS Audiobooks zzz` for backwards compatibility, but if `ABS_LIBRARY_DIR` is set in `.env`, the library lives wherever you point it and the staging directory is computed as a sibling with a ` zzz` suffix:

```
# With ABS_LIBRARY_DIR=/Volumes/nas/audiobookshelf/Audiobooks
/Volumes/nas/audiobookshelf/
├── Audiobooks/                         (AudioBookShelf live library)
└── Audiobooks zzz/                     (staging — sibling of LIVE_DIR, same fs)
```

The `zzz` suffix on the staging dir is deliberate: it sorts to the bottom in file managers and signals to humans "not part of the live library".

## Orchestrator behaviour

Run `ingest.zsh [DEBUG]` as a long-lived foreground process. Ctrl-C to stop.

On each 120-second tick it:

1. Verifies `$LIBRARY_ROOT` is reachable as a directory. If not, it sleeps an hour and rechecks (intended for laptops that roam off the home network).
2. Globs siblings matching `ingest-*.zsh` and runs each in turn, forwarding only the `DEBUG` flag if present. Children inherit `INGEST_ROOT` and `LIBRARY_ROOT` from the environment.
3. A child failing logs a warning but does not abort the other children.

### Adding a new child

Drop an `ingest-<type>.zsh` next to the orchestrator and `chmod +x` it. The orchestrator picks it up on its next loop with no config change. The contract for a child is:

- The filename must match `ingest-*.zsh` (the dash after `ingest` is load-bearing — it's what prevents the orchestrator from matching its own glob and recursively running itself).
- Accept `[DEBUG]` as the only positional argument.
- Source `scripts/.env` at startup (so standalone testing works) and validate that `INGEST_ROOT` and `LIBRARY_ROOT` are set.
- Be a single-run script (run once, exit).
- Return 0 on success; non-zero is logged as a warning.

## Video child

Expects `.m4v` files in `$INGEST_ROOT/ingest-video/` (recursive).

| Validation | Action on failure |
|---|---|
| Not an `.m4v` | `wrong_type` rejection (or auto-delete for `.jpg/.png/.log/.nfo`) |
| Codec not HEVC / H.265 | `wrong_codec` rejection |
| Duration < 120 s | `corrupt` rejection (likely stub) |
| Zero-byte for > 24 h | `corrupt` rejection |
| `ffprobe` can't read for > 24 h | `corrupt` rejection |
| Filename doesn't parse | `parse_error` rejection |

Classification heuristics:

- **TV episode** if the filename contains `SxxEyy` or `NxNN` (case-insensitive). Year is parsed from `(YYYY)` in the filename, or inferred by fuzzy-matching the show name against existing `TV/` library directories.
- **Movie** otherwise. Year optional.

Conflict resolution: higher video height wins; file size is the tiebreak.

## Audiobook child

Expects strictly `Author/Book/` (depth 2) under `$INGEST_ROOT/ingest-audiobook/`. Each book directory must contain `metadata.json`, `cover.jpg`, and one-or-more `.mp3` files at the book root.

### Validation order

1. **`wrong_type`** — any non-mp3 audio extension (`m4a, m4b, mp4, flac, wav, ogg, oga, aac, wma, opus, alac, ape, dsf, dff, aiff, aif`) anywhere in the book. The whole book is rejected.
2. **`parse_error`** — author directory name has 2+ consecutive single-uppercase tokens separated by spaces. `J K Rowling` → bad; `JK Rowling` → good; `George R Martin` (one middle initial) → fine.
3. **`parse_error`** — `metadata.json` or `cover.jpg` missing at the book root.
4. **`parse_error`** — no `.mp3` at the book root (with subcase: mp3s exist only in subdirectories → "flat layout required").

### Per-mp3 conflict resolution

For each `.mp3` in the source book, matched by filename against the live library (`$ABS_LIBRARY_DIR/<Author>/<Book>/`, or `$LIBRARY_ROOT/ABS Audiobooks/<Author>/<Book>/` if `ABS_LIBRARY_DIR` isn't set):

| Situation | Decision | Action |
|---|---|---|
| No LIVE counterpart | `new` | Install fresh via staging |
| LIVE has it, new bitrate > existing **and** \|duration delta\| ≤ 5% | `winner` | Stage source, move LIVE file to `rejected/replaced/`, merge staging → LIVE |
| LIVE has it, otherwise | `loser` | Move source file to `rejected/lower_quality/<Author>/<Book>/<filename>` |

Bitrate and duration are read via `ffprobe`. If `ffprobe` can't read either side, the existing file wins (fail-safe).

**Whole-book shortcut:** if every source mp3 is a loser, the whole source book moves to `rejected/lower_quality/Author/Book/` in one piece rather than fragmenting into per-file logs plus orphaned metadata.

### Metadata coupling

If at least one mp3 is installed for a book (winner or new), the script always installs `cover.jpg` and `metadata.json` too. Existing LIVE versions move to `rejected/replaced/Author/Book/` with a log noting "metadata refresh: N mp3 file(s) installed for this book". If no mp3 is installed, metadata is not touched.

### Why a staging directory?

AudioBookShelf scans its library aggressively. Copying directly into the live library risks ABS picking up a half-copied file. The script copies each file into a sibling `<LIVE_DIR> zzz/` directory first (ABS doesn't watch it); once on disk, files are `mv`'d into the live library — a same-filesystem rename that's atomic and instant. This is why the staging dir is always a sibling of the live dir, not a separately-configurable path: the rename has to stay on one filesystem.

### Stability and resume

- Before touching a book, every file the script intends to write is checked for mid-copy state (temp extension, sibling `.part` file, `lsof` write handle, size changing across a 3-second sample, or mtime younger than 30 s). If any fails, the whole book is deferred to the next loop.
- Partially-staged files from a previous run are reused if their size matches the source. Size mismatch → re-copy.

## Reject categories (both children)

| Category | Meaning |
|---|---|
| `wrong_type` | File type doesn't match the child's contract |
| `wrong_codec` | Video only — file isn't HEVC/H.265 |
| `corrupt` | Unreadable by ffprobe, zero-byte stale, bad duration |
| `parse_error` | Couldn't determine show/movie, missing required files, bad author name |
| `lower_quality` | Lost a quality comparison vs an existing library file |
| `replaced` | An existing library file was bumped out by a higher-quality incoming file |

Each rejection writes a sibling `.log` file next to the rejected media, with the timestamp, category, original path, and reason.

## Logging

All logs share the pattern:

```
[YYYY-MM-DD HH:MM:SS] [<child>] <message>
```

`DEBUG` output is prefixed `[DEBUG]`.

## Known minor issues

- The orchestrator uses `local` at top level. Works in zsh but technically invalid outside functions. Cosmetic — left alone to keep the diff history clean.

## Contributing / extending

Pull requests welcome, especially for additional child scripts (the obvious ones being ebooks and comics). Please:

- The audiobook live directory name must match what AudioBookShelf is configured to watch — whatever you point `ABS_LIBRARY_DIR` at (or the default `ABS Audiobooks`), make sure ABS knows about it.
- Always run with `DEBUG` first when testing against a real library root.
- Follow the child-script contract documented above.
- If you add a new required configuration key, document it in `scripts/.env.template` and validate its presence in the script's startup block.

## License

[MIT](LICENSE).
