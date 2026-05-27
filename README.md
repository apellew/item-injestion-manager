# item-ingestion-manager

A small, extensible zsh-based media ingestion pipeline. Files dropped into local "ingest" directories are validated, normalised, and moved into a media library elsewhere (often a NAS).

A parent orchestrator script runs continuously and discovers per-media-type child scripts on a fixed loop. Currently shipped children handle TV episodes (`.m4v`), movies (`.m4v`), and audiobooks (`.mp3`). The orchestrator is media-agnostic — see [Adding a new child](#adding-a-new-child).

Source-filename parsing and destination-naming are user-configurable per child via Python-style regexes and `%NAME%` templates in `.env` — see [Filename parsing](#filename-parsing-regex--template) below.

## Contents

| Script | Role |
|---|---|
| [`scripts/ingest.zsh`](scripts/ingest.zsh) | Parent orchestrator. Runs each `ingest-*.zsh` child every 120 s. If `LIBRARY_ROOT` is set in .env, waits when the directory is unreachable (e.g. NAS off-network); otherwise skips that probe. |
| [`scripts/ingest-tv.zsh`](scripts/ingest-tv.zsh) | TV episode child. Validates `.m4v` files (HEVC/H.265, minimum duration), parses filenames via `TV_PARSE_REGEX` + `TV_NAME_TEMPLATE`, and installs into `TV_DIR` via a staged copy-then-rename (see [Why staging?](#why-staging)). |
| [`scripts/ingest-movie.zsh`](scripts/ingest-movie.zsh) | Movie child. Validates `.m4v` files, parses filenames via `MOVIE_PARSE_REGEX` + `MOVIE_NAME_TEMPLATE`, and installs into `MOVIES_DIR` via the same staged pattern. |
| [`scripts/ingest-audiobooks.zsh`](scripts/ingest-audiobooks.zsh) | Audiobook child. Per-mp3 quality comparison via `ffprobe` with coupled metadata refresh. Destination derived via `AUDIOBOOKS_PARSE_REGEX` + `AUDIOBOOKS_NAME_TEMPLATE` applied to the book directory's Author/Book path. Installs into `AUDIOBOOKS_DIR` via the same staged pattern. |
| [`scripts/_lib.zsh`](scripts/_lib.zsh) | Shared helper library sourced by every child. Provides file-stat helpers, `ffprobe` wrappers, mid-copy detection, video-quality `compare_files`, and the `stage_file` / `merge_file` staging primitives. Not invoked directly — leading underscore keeps the orchestrator's `ingest-*.zsh` glob from picking it up. |
| [`scripts/_parse_name.py`](scripts/_parse_name.py) | Python3 helper that does the regex match + template expansion. Each child shells out to it once per source unit (per file for TV/Movie, per book directory for audiobooks). Not invoked directly by the user. |
| [`scripts/.env.template`](scripts/.env.template) | Annotated configuration template. Copy to `scripts/.env` and edit. |

## Requirements

- **zsh** (the scripts use zsh-specific features like `EXTENDED_GLOB`, `zstat`, and parameter expansion modifiers).
- **python3** (pre-installed on macOS; used by `_parse_name.py` for regex parsing and template expansion).
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

**Library destinations:**

| Key | Required by | Purpose |
|---|---|---|
| `INGEST_ROOT` | every script | Root of the local "ingest" directory tree. Each child watches a subdirectory under this. |
| `MOVIES_DIR` | `ingest-movie.zsh` | Where movies land. |
| `TV_DIR` | `ingest-tv.zsh` | Where TV episodes land. |
| `AUDIOBOOKS_DIR` | `ingest-audiobooks.zsh` | The live audiobooks library directory itself (NOT a parent). |

Each script derives its own staging directory as a sibling of the live destination with a ` zzz` suffix (e.g. `MOVIES_DIR="/Volumes/nas/Movies"` implies a staging dir at `/Volumes/nas/Movies zzz`). The staging directory must be on the same filesystem as the live destination — see [Why staging?](#why-staging) for why.

**Filename parsing (one pair per child):**

| Key pair | Required by |
|---|---|
| `TV_PARSE_REGEX` + `TV_NAME_TEMPLATE` | `ingest-tv.zsh` |
| `MOVIE_PARSE_REGEX` + `MOVIE_NAME_TEMPLATE` | `ingest-movie.zsh` |
| `AUDIOBOOKS_PARSE_REGEX` + `AUDIOBOOKS_NAME_TEMPLATE` | `ingest-audiobooks.zsh` |

See [Filename parsing](#filename-parsing-regex--template) below for the mechanism.

### Optional convenience: `LIBRARY_ROOT`

`LIBRARY_ROOT` is **not read directly by any script**. It's provided as a convenience for users whose libraries all live under a single root — you can set it in `.env` and reference it in your other key definitions:

```zsh
export LIBRARY_ROOT="/Volumes/nas/media"
export MOVIES_DIR="${LIBRARY_ROOT}/Movies"
export TV_DIR="${LIBRARY_ROOT}/TV"
export AUDIOBOOKS_DIR="${LIBRARY_ROOT}/Audiobooks"
```

Users with libraries on different volumes can leave `LIBRARY_ROOT` unset and write absolute paths directly. There's one side effect of setting it: the orchestrator uses it as an "is the NAS reachable?" probe and waits when the directory is unavailable. If `LIBRARY_ROOT` is unset, the probe is skipped and individual children fail if their library is unreachable.

## Filename parsing (regex + template)

Each child script parses source filenames via two `.env` keys: a **Python-style regex** with named capture groups, and a **template** that references those captures using `%NAME%` placeholders. The regex matches against the source path relative to the script's ingest subdirectory, with the file extension stripped (TV / Movie) or as-is (audiobooks, where the unit is a directory).

### Default values

The template ships with working defaults that reproduce conventional naming:

```zsh
# TV: matches "Show (YYYY) SxxEyy"
TV_PARSE_REGEX='(?P<SHOW>.+?) \((?P<YEAR>\d{4})\) S(?P<SEASON>\d{2})E(?P<EPISODE>\d{2})'
TV_NAME_TEMPLATE='%SHOW% (%YEAR%)/Season %SEASON%/%SHOW% (%YEAR%) - S%SEASON%E%EPISODE%'

# Movie: matches "Title (YYYY)" — year required
MOVIE_PARSE_REGEX='(?P<TITLE>.+?) \((?P<YEAR>\d{4})\)'
MOVIE_NAME_TEMPLATE='%TITLE% (%YEAR%)/%TITLE% (%YEAR%)'

# Audiobook: matches "Author/Book" (the book directory path)
AUDIOBOOKS_PARSE_REGEX='(?P<AUTHOR>[^/]+)/(?P<BOOK>.+)'
AUDIOBOOKS_NAME_TEMPLATE='%AUTHOR%/%BOOK%'
```

### How the parser works

For TV and Movie children, given a source file at `${INGEST_ROOT}/ingest-tv/Doctor Who (2023) S01E01.m4v`:

1. The script strips the ingest prefix and the `.m4v` extension: `Doctor Who (2023) S01E01`.
2. It runs `python3 scripts/_parse_name.py "$REGEX" "$TEMPLATE" "$source_rel"`.
3. The helper does `re.fullmatch(regex, source_rel)`. If it doesn't match, the helper exits with code 2 and the calling script issues a `parse_error` rejection.
4. If it matches, the helper replaces each `%NAME%` in the template with the corresponding capture group's value: `Doctor Who (2023)/Season 01/Doctor Who (2023) - S01E01`.
5. The script appends `.m4v` and prepends `${TV_DIR}/` to produce the final destination, then installs via [staging](#why-staging).

For the audiobook child, the regex matches against the book directory's relative path (e.g. `Stephen King/The Stand`), the template produces a destination relative path, and individual mp3 filenames within the book are preserved verbatim under that destination.

### Failed parses

If the regex doesn't match a given source filename, the file (or book) is rejected via the existing `parse_error` mechanism — the rejection log includes both the regex and the source string for debugging.

### Overriding the defaults

Just set the relevant `*_PARSE_REGEX` and `*_NAME_TEMPLATE` in your `.env` to whatever you need. The regex syntax is Python's full named-group flavour (`(?P<NAME>...)`); the template syntax is plain `%NAME%` placeholders with literal slashes as path separators. The file extension is hardcoded per script (`.m4v` for TV/Movie, mp3 names preserved for audiobooks) and not part of the template.

## Why staging?

Every install — TV, Movie, audiobook — goes through a sibling staging directory before landing in the live library:

1. **Stage:** `cp` source → `<DEST_DIR> zzz/<expanded path>` on the same filesystem as the live destination.
2. **Merge:** atomic `mv` of the staged file (or staged book directory tree) → live destination.
3. **Cleanup:** remove the source file.

Two reasons this matters:

- Some media servers scan the live library aggressively and auto-import anything they see there. Copying directly into the live library risks the server picking up a half-copied file. The staged file only appears in the live library as a complete unit, because the final `mv` is an atomic same-filesystem rename.
- Cross-filesystem copies (which include the typical local-disk → NAS-mount case) are slow and interruptible — `mv src dst` across filesystems silently becomes `cp` + `rm`, with all the partial-state risk that implies. Splitting it into an explicit `cp` to staging followed by an atomic same-filesystem `mv` makes the failure modes legible.

The staging directory is always a **sibling** of the live destination with a ` zzz` suffix (so it sorts to the bottom in file managers and visibly signals "not part of the live library"). It's not separately configurable — the same-filesystem requirement is what makes the final `mv` atomic, and a sibling is the simplest place that guarantees that.

If a `cp` to staging fails partway through, the staged path is left in place and the source is untouched; the next run re-uses the partial-staged file if its size matches the source, or recopies if not. The live library is never touched by a failed install.

## Directory layout

Each script watches its own ingest subdirectory (named to match the script) and writes to its own configured library directory:

```
$INGEST_ROOT/
├── ingest-tv/                          (ingest-tv.zsh watches this)
├── ingest-tv_rejected/
├── ingest-movie/                       (ingest-movie.zsh watches this)
├── ingest-movie_rejected/
├── ingest-audiobooks/                  (ingest-audiobooks.zsh watches this)
└── ingest-audiobooks_rejected/
```

The per-script ingest subdirs (and their `_rejected` siblings) are auto-created on demand — you only need `INGEST_ROOT` to exist. The `_rejected/` directories specifically are only created the first time a rejection actually happens, so systems that never reject anything stay tidy.

Library destinations are each configured independently — they can live on the same volume as each other or different ones. A typical "everything on one NAS" layout might look like:

```
$MOVIES_DIR         → /Volumes/nas/media/Movies
                      (staging at /Volumes/nas/media/Movies zzz)
$TV_DIR             → /Volumes/nas/media/TV
                      (staging at /Volumes/nas/media/TV zzz)
$AUDIOBOOKS_DIR     → /Volumes/nas/media/Audiobooks
                      (staging at /Volumes/nas/media/Audiobooks zzz)
```

…while a split-volume layout might look like:

```
$MOVIES_DIR         → /Volumes/media/Movies
$TV_DIR             → /Volumes/media/TV
$AUDIOBOOKS_DIR     → /Volumes/media-other/Audiobooks
                      (staging at /Volumes/media-other/Audiobooks zzz)
```

Each staging dir is always a sibling of its live counterpart, on the same filesystem — see [Why staging?](#why-staging).

## Orchestrator behaviour

Run `ingest.zsh [DEBUG]` as a long-lived foreground process. Ctrl-C to stop.

On each 120-second tick it:

1. **If `LIBRARY_ROOT` is set in `.env`,** verifies it's reachable as a directory. If not, sleeps an hour and rechecks (intended for laptops that roam off the home network). If `LIBRARY_ROOT` is unset, this probe is skipped and each child is run regardless — they'll fail individually if their library is unreachable.
2. Globs siblings matching `ingest-*.zsh` and runs each in turn, forwarding only the `DEBUG` flag if present. Children inherit the full `.env` environment from the orchestrator.
3. A child failing logs a warning but does not abort the other children.

### Adding a new child

Drop an `ingest-<type>.zsh` next to the orchestrator and `chmod +x` it. The orchestrator picks it up on its next loop with no config change. The contract for a child is:

- The filename must match `ingest-*.zsh` (the dash after `ingest` is load-bearing — it's what prevents the orchestrator from matching its own glob and recursively running itself, and it's also what excludes `_lib.zsh` and `_parse_name.py`).
- By convention, the child's input directory under `$INGEST_ROOT` shares its name (so `ingest-foo.zsh` watches `ingest-foo/`, rejects into `ingest-foo_rejected/`).
- Accept `[DEBUG]` as the only positional argument.
- Source `scripts/.env` at startup (so standalone testing works) and validate that its own required keys are set.
- Source `scripts/_lib.zsh` for the shared helpers (`file_size`, `file_age_seconds`, `is_file_in_use`, `ffprobe_value`, `ffprobe_duration`, `compare_files`, `stage_file`, `merge_file`).
- Use `scripts/_parse_name.py` for filename parsing — don't write a hand-rolled parser in each new child.
- Use the `stage_file` / `merge_file` pair from `_lib.zsh` to install files; don't go direct to the live library.
- Be a single-run script (run once, exit).
- Return 0 on success; non-zero is logged as a warning.

## TV child

Expects `.m4v` files in `$INGEST_ROOT/ingest-tv/` (recursive).

| Validation | Action on failure |
|---|---|
| Not an `.m4v` | `wrong_type` rejection (or auto-delete for `.jpg/.png/.log/.nfo`) |
| Codec not HEVC / H.265 | `wrong_codec` rejection |
| Duration < 120 s | `corrupt` rejection (likely stub) |
| Zero-byte for > 24 h | `corrupt` rejection |
| `ffprobe` can't read for > 24 h | `corrupt` rejection |
| `TV_PARSE_REGEX` doesn't match the filename (extension stripped) | `parse_error` rejection |

Destination is constructed by expanding `TV_NAME_TEMPLATE` with the regex's capture values, then joined with `$TV_DIR` and `.m4v` to produce the final path. The install is staged — see [Why staging?](#why-staging).

Conflict resolution: higher video height wins; file size is the tiebreak.

## Movie child

Expects `.m4v` files in `$INGEST_ROOT/ingest-movie/` (recursive).

| Validation | Action on failure |
|---|---|
| Not an `.m4v` | `wrong_type` rejection (or auto-delete for `.jpg/.png/.log/.nfo`) |
| Codec not HEVC / H.265 | `wrong_codec` rejection |
| Duration < 120 s | `corrupt` rejection (likely stub) |
| Zero-byte for > 24 h | `corrupt` rejection |
| `ffprobe` can't read for > 24 h | `corrupt` rejection |
| `MOVIE_PARSE_REGEX` doesn't match the filename (extension stripped) | `parse_error` rejection |

Destination is constructed by expanding `MOVIE_NAME_TEMPLATE` with the regex's capture values, then joined with `$MOVIES_DIR` and `.m4v` to produce the final path. The install is staged — see [Why staging?](#why-staging). The shipped default regex requires a year in the filename; if your conventions differ, override the regex/template in `.env`.

Conflict resolution: higher video height wins; file size is the tiebreak.

## Audiobook child

Expects strictly `Author/Book/` (depth 2) under `$INGEST_ROOT/ingest-audiobooks/`. Each book directory must contain `metadata.json`, `cover.jpg`, and one-or-more `.mp3` files at the book root.

### Validation order

1. **`wrong_type`** — any non-mp3 audio extension (`m4a, m4b, mp4, flac, wav, ogg, oga, aac, wma, opus, alac, ape, dsf, dff, aiff, aif`) anywhere in the book. The whole book is rejected.
2. **`parse_error`** — author directory name has 2+ consecutive single-uppercase tokens separated by spaces. `J K Rowling` → bad; `JK Rowling` → good; `George R Martin` (one middle initial) → fine.
3. **`parse_error`** — `metadata.json` or `cover.jpg` missing at the book root.
4. **`parse_error`** — no `.mp3` at the book root (with subcase: mp3s exist only in subdirectories → "flat layout required").
5. **`parse_error`** — `AUDIOBOOKS_PARSE_REGEX` doesn't match the book's relative path (Author/Book).

### Destination

The destination is `${AUDIOBOOKS_DIR}/<expanded template>/` where `<expanded template>` comes from running the source book's `Author/Book` relative path through `AUDIOBOOKS_PARSE_REGEX` + `AUDIOBOOKS_NAME_TEMPLATE`. Individual mp3 filenames within the book are preserved verbatim under that destination directory. The install is staged — see [Why staging?](#why-staging).

The shipped default (regex `(?P<AUTHOR>[^/]+)/(?P<BOOK>.+)` + template `%AUTHOR%/%BOOK%`) is a no-op transformation — Author and Book come through unchanged. Override in `.env` if you want a flat layout (e.g. template `%AUTHOR% - %BOOK%`) or rearrange the structure.

### Per-mp3 conflict resolution

For each `.mp3` in the source book, matched by filename against the resolved destination directory:

| Situation | Decision | Action |
|---|---|---|
| No LIVE counterpart | `new` | Install fresh via staging |
| LIVE has it, new bitrate > existing **and** \|duration delta\| ≤ 5% | `winner` | Stage source, move LIVE file to `rejected/replaced/`, merge staging → LIVE |
| LIVE has it, otherwise | `loser` | Move source file to `rejected/lower_quality/<Author>/<Book>/<filename>` |

Bitrate and duration are read via `ffprobe`. If `ffprobe` can't read either side, the existing file wins (fail-safe).

**Whole-book shortcut:** if every source mp3 is a loser, the whole source book moves to `rejected/lower_quality/Author/Book/` in one piece rather than fragmenting into per-file logs plus orphaned metadata.

### Metadata coupling

If at least one mp3 is installed for a book (winner or new), the script always installs `cover.jpg` and `metadata.json` too. Existing LIVE versions move to `rejected/replaced/Author/Book/` with a log noting "metadata refresh: N mp3 file(s) installed for this book". If no mp3 is installed, metadata is not touched.

### Stability and resume

- Before touching a book, every file the script intends to write is checked for mid-copy state (temp extension, sibling `.part` file, `lsof` write handle, size changing across a 3-second sample, or mtime younger than 30 s). If any fails, the whole book is deferred to the next loop.
- Partially-staged files from a previous run are reused if their size matches the source. Size mismatch → re-copy.

## Reject categories (all children)

| Category | Meaning |
|---|---|
| `wrong_type` | File type doesn't match the child's contract |
| `wrong_codec` | Video only — file isn't HEVC/H.265 |
| `corrupt` | Unreadable by ffprobe, zero-byte stale, bad duration |
| `parse_error` | Regex didn't match the source filename, missing required files, bad author name |
| `lower_quality` | Lost a quality comparison vs an existing library file |
| `replaced` | An existing library file was bumped out by a higher-quality incoming file |

Each rejection writes a sibling `.log` file next to the rejected media, with the timestamp, category, original path, and reason.

## Logging

All logs share the pattern:

```
[YYYY-MM-DD HH:MM:SS] [<child>] <message>
```

Children identify themselves with short prefixes: `[tv]`, `[movie]`, `[audiobooks]`. `DEBUG` output is prefixed `[DEBUG]`.

## Known minor issues

- The orchestrator uses `local` at top level. Works in zsh but technically invalid outside functions. Cosmetic — left alone to keep the diff history clean.

## Contributing / extending

Pull requests welcome, especially for additional child scripts (the obvious ones being ebooks, comics, and music). Please:

- The live directory name must match what your downstream media server is configured to watch — whatever you point a `*_DIR` at, make sure the media server knows about it.
- Always run with `DEBUG` first when testing against a real library root.
- Follow the child-script contract documented above.
- Use the helpers in `scripts/_lib.zsh` rather than re-implementing file stats / ffprobe wrappers / staging primitives in each new child.
- Use `scripts/_parse_name.py` for filename parsing — don't write a hand-rolled parser in each new child.
- If you add a new required configuration key, document it in `scripts/.env.template` and validate its presence in the script's startup block.

## License

[MIT](LICENSE).
