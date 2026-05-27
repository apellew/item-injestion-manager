# item-ingestion-manager

A small, extensible zsh-based media ingestion pipeline. Files dropped into local "ingest" directories are validated, normalised, and moved into a media library elsewhere (often a NAS).

A parent orchestrator script runs continuously and discovers per-media-type child scripts on a fixed loop. Currently shipped children target [Jellyfin](https://jellyfin.org/) (video `.m4v`) and [AudioBookShelf](https://www.audiobookshelf.org/) (audiobooks `.mp3`), but the orchestrator is media-agnostic — see [Adding a new child](#adding-a-new-child).

## Contents

| Script | Role |
|---|---|
| [`scripts/ingest.zsh`](scripts/ingest.zsh) | Parent orchestrator. Runs each `ingest-*.zsh` child every 120 s. If `LIBRARY_ROOT` is set in .env, waits when the directory is unreachable (e.g. NAS off-network); otherwise skips that probe. |
| [`scripts/ingest-video.zsh`](scripts/ingest-video.zsh) | Video child. Validates `.m4v` files (HEVC/H.265, minimum duration), classifies each as TV episode or Movie, and moves into `JELLYFIN_TV_DIR` or `JELLYFIN_MOVIES_DIR`. Conflict resolution by resolution + file size. |
| [`scripts/ingest-audiobooks.zsh`](scripts/ingest-audiobooks.zsh) | Audiobook child for AudioBookShelf. Per-mp3 quality comparison via `ffprobe` with coupled metadata refresh. Writes to `ABS_LIBRARY_DIR`. Uses a sibling staging directory so ABS doesn't pick up half-copied files. |
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

# Create your local config from the template, then fill in the paths.
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

Each script validates its own required keys at startup. Missing required keys produce a clear stderr error and a non-zero exit (so launchd / cron register the failure rather than silently no-opping).

### Required keys

All values are full absolute paths. No fallbacks, no derived defaults.

| Key | Required by | Purpose |
|---|---|---|
| `INGEST_ROOT` | every script | Root of the local "ingest" directory tree. Each child watches a subdirectory under this. |
| `JELLYFIN_MOVIES_DIR` | `ingest-video.zsh` | Where movies land. |
| `JELLYFIN_TV_DIR` | `ingest-video.zsh` | Where TV episodes land. |
| `ABS_LIBRARY_DIR` | `ingest-audiobooks.zsh` | The AudioBookShelf live library directory itself (NOT a parent). The staging directory is derived as a sibling with a ` zzz` suffix. |

### Optional convenience: `LIBRARY_ROOT`

`LIBRARY_ROOT` is **not read directly by any script**. It's provided as a convenience for users whose libraries all live under a single root — you can set it in `.env` and reference it in your other key definitions:

```zsh
export LIBRARY_ROOT="/Volumes/nas/media"
export JELLYFIN_MOVIES_DIR="${LIBRARY_ROOT}/Movies"
export JELLYFIN_TV_DIR="${LIBRARY_ROOT}/TV"
export ABS_LIBRARY_DIR="${LIBRARY_ROOT}/ABS Audiobooks"
```

Users with libraries on different volumes can leave `LIBRARY_ROOT` unset and write absolute paths directly. There's one side effect of setting it: the orchestrator uses it as an "is the NAS reachable?" probe and waits when the directory is unavailable. If `LIBRARY_ROOT` is unset, the probe is skipped and individual children fail if their library is unreachable.

## Directory layout

Each script watches its own ingest subdirectory and writes to its own configured library directory:

```
$INGEST_ROOT/
├── ingest-video/                       (video child watches this)
├── ingest-video_rejected/
├── ingest-audiobook/                   (audiobook child watches this)
└── ingest-audiobook_rejected/
```

Library destinations are each configured independently — they can live on the same volume as each other or different ones. A typical "everything on one NAS" layout might look like:

```
$JELLYFIN_MOVIES_DIR        → /Volumes/nas/media/Movies
$JELLYFIN_TV_DIR            → /Volumes/nas/media/TV
$ABS_LIBRARY_DIR            → /Volumes/nas/media/ABS Audiobooks
                              (staging at /Volumes/nas/media/ABS Audiobooks zzz)
```

…while a split-volume layout might look like:

```
$JELLYFIN_MOVIES_DIR        → /Volumes/jellyfin/Movies
$JELLYFIN_TV_DIR            → /Volumes/jellyfin/TV
$ABS_LIBRARY_DIR            → /Volumes/audiobookshelf/Audiobooks
                              (staging at /Volumes/audiobookshelf/Audiobooks zzz)
```

The `zzz` suffix on the audiobook staging dir is deliberate: it sorts to the bottom in file managers and signals to humans "not part of the live library".

## Orchestrator behaviour

Run `ingest.zsh [DEBUG]` as a long-lived foreground process. Ctrl-C to stop.

On each 120-second tick it:

1. **If `LIBRARY_ROOT` is set in `.env`,** verifies it's reachable as a directory. If not, sleeps an hour and rechecks (intended for laptops that roam off the home network). If `LIBRARY_ROOT` is unset, this probe is skipped and each child is run regardless — they'll fail individually if their library is unreachable.
2. Globs siblings matching `ingest-*.zsh` and runs each in turn, forwarding only the `DEBUG` flag if present. Children inherit the full `.env` environment from the orchestrator.
3. A child failing logs a warning but does not abort the other children.

### Adding a new child

Drop an `ingest-<type>.zsh` next to the orchestrator and `chmod +x` it. The orchestrator picks it up on its next loop with no config change. The contract for a child is:

- The filename must match `ingest-*.zsh` (the dash after `ingest` is load-bearing — it's what prevents the orchestrator from matching its own glob and recursively running itself).
- Accept `[DEBUG]` as the only positional argument.
- Source `scripts/.env` at startup (so standalone testing works) and validate that its own required keys are set.
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

- **TV episode** if the filename contains `SxxEyy` or `NxNN` (case-insensitive). Year is parsed from `(YYYY)` in the filename, or inferred by fuzzy-matching the show name against existing `JELLYFIN_TV_DIR` subdirectories.
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

For each `.mp3` in the source book, matched by filename against `$ABS_LIBRARY_DIR/<Author>/<Book>/`:

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

AudioBookShelf scans its library aggressively. Copying directly into the live library risks ABS picking up a half-copied file. The script copies each file into a sibling `<ABS_LIBRARY_DIR> zzz/` directory first (ABS doesn't watch it); once on disk, files are `mv`'d into the live library — a same-filesystem rename that's atomic and instant. This is why the staging dir is always a sibling of the live dir, not a separately-configurable path: the rename has to stay on one filesystem.

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

- The audiobook live directory name must match what AudioBookShelf is configured to watch — whatever you point `ABS_LIBRARY_DIR` at, make sure ABS knows about it.
- Always run with `DEBUG` first when testing against a real library root.
- Follow the child-script contract documented above.
- If you add a new required configuration key, document it in `scripts/.env.template` and validate its presence in the script's startup block.

## License

[MIT](LICENSE).
