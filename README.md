# Daily Select

Daily Select is a privacy-first, on-device photo and video selector for macOS. Point
it at a local folder and it copies a conservative set of strong, varied moments
into one flat folder per capture date.

```text
Photos/                         # Read-only input
Daily Select/
└── 2026-08-09/
    ├── IMG_0004.HEIC
    ├── IMG_0012.JPG
    └── VID_0018.MOV
```

Daily Select never deletes, moves, renames, edits, or overwrites source media.
It performs analysis with Apple's Vision and AVFoundation frameworks; no media,
thumbnails, metadata, or model requests leave your Mac.

## Features

- On-device aesthetic and utility-image scoring
- Near-duplicate and burst grouping with visual feature prints
- Overlapping, multi-scale face detection for small faces in wide photos
- Face-quality and eyewear-appearance diversity within large bursts
- Broad semantic balancing so one day is not filled with only one kind of shot
- Frame sampling for MOV, MP4, and M4V video
- Memory-bounded photo thumbnails with automatic smaller-size retries
- Multiple independent camera folders sharing one resumable output library
- Flat `YYYY-MM-DD` output folders with byte-identical copies
- Bounded analysis batches with an atomic checkpoint after every batch
- Safe resume after interruption: unchanged completed media is not analyzed again
- Auditable per-batch JSON manifests containing scores, labels, groups, and decisions
- Idempotent reruns: existing identical selections are reused

## Requirements

- macOS 15 or newer
- Xcode Command Line Tools or Xcode with Swift 6.2 or newer

Daily Select has no third-party package dependencies.

## Install and run

```bash
git clone https://github.com/jasonqinzhou/daily-select.git
cd daily-select
swift build -c release
.build/release/daily-select "/path/to/Photos" "/path/to/Daily Select"
```

The output argument is optional. When omitted, Daily Select creates a sibling
directory named `Daily Select`.

You can also use the wrapper:

```bash
./run.sh "/path/to/Photos" "/path/to/Daily Select"
```

The input and output directories must not overlap.

You can send several separate camera folders into the same output. Run each
source independently and reuse the exact same output path:

```bash
.build/release/daily-select "/Volumes/iPhone Export" "/path/to/Daily Select"
.build/release/daily-select "/Volumes/Sony SD Card/DCIM" "/path/to/Daily Select"
.build/release/daily-select "/Volumes/GoPro" "/path/to/Daily Select"
```

Daily Select registers every input root in the shared checkpoint and tracks a
file by both its source root and relative path. The commands can be run in any
order and do not require the source folders to share a common parent.

## Options

```text
--dry-run                 Analyze without copying
--ratio 0.35              Fraction selected within each date/topic balance
--max-per-topic 12        Maximum selected within each internal topic balance
--photo-max-pixels 2048   Longest edge used for photo analysis (minimum: 512)
--batch-size 1000         New media analyzed before each checkpoint
--max-batches NUMBER      Stop after this many batches and resume on the next run
-h, --help                Show command help
```

Example:

```bash
.build/release/daily-select --dry-run --ratio 0.30 "/path/to/Photos"
```

## Batches and checkpoints

By default, Daily Select analyzes at most 1,000 new or changed files at a time.
After each batch it copies that batch's selections, writes a per-batch manifest,
and atomically updates `_daily-select-checkpoint.json`. It then continues with
the next batch automatically.

Run the exact same command after a crash, shutdown, or manual stop. Files whose
size and modification time still match the checkpoint are skipped; new or
changed files are analyzed. A small set of candidates near the chronological
batch boundary is carried into the next batch so a burst split at item 1,000 is
still compared together. The source folder remains read-only throughout.

Changing to another input folder does not discard an unfinished boundary from
the previous folder. Return to either source later and its checkpoint resumes
independently. Checkpoints written by the earlier single-source release are
upgraded automatically the next time the tool runs.

For a scheduled or deliberately bounded run, process one batch per invocation:

```bash
.build/release/daily-select --batch-size 1000 --max-batches 1 \
  "/path/to/Photos" "/path/to/Daily Select"
```

`--ratio`, `--max-per-topic`, `--photo-max-pixels`, and `--batch-size` are part
of the checkpointed selection policy. Use the same values for every input that
shares an output. To use different policy settings, choose a new output folder
so results from two policies are not mixed.

## How selection works

1. ImageIO reads capture dates, falling back to timestamped filenames and then
   filesystem dates.
2. ImageIO creates a memory-bounded, orientation-correct thumbnail for photo
   analysis. Vision scores aesthetics, identifies utility images, produces
   broad content labels, and generates visual feature prints.
3. Photos containing people receive an overlapping tiled face scan. Face crops
   are analyzed for capture quality and eyewear appearance, allowing a strong
   no-eyewear frame and a strong eyewear frame to survive the same burst.
4. Similar captures taken close together are grouped. Daily Select keeps the
   best representative, meaningful face-appearance variants, and an additional
   composition only when it is sufficiently different.
5. Broad internal topics balance people, food, nature, travel, animals, and
   other moments. These topics never create output subfolders.
6. Selected originals are copied without transcoding or recompression. The
   analysis thumbnail never replaces or changes the original photo.

Existing daily folders are additive. When a selected filename already exists,
identical contents are reused; different contents are saved with a numeric
suffix such as `IMG_0001-2.JPG`. Existing media is never overwritten. Each
input folder is selected independently, so selections already copied from an
older source are not retroactively re-ranked when a new source is added.

For videos, AVFoundation samples frames near the beginning, middle, and end,
then copies the complete original video when selected.

## Manifests

Each committed batch writes `_daily-select-batches/batch-NNNNNN.json`. Those
batch manifests record:

- Source and destination paths
- Capture dates and media types
- Aesthetic, face-quality, and eyewear-confidence scores
- Semantic labels and internal topic
- Near-duplicate group identifiers
- Selection or rejection reason
- Batch counts and failures
- Whether each asset received full, partial, or basic fallback analysis

The compact `_daily-select-manifest.json` is the current run index and cumulative
summary. It records the current input plus all input roots registered with the
shared output. `_daily-select-checkpoint.json` is the machine-readable resume
state. Both are updated atomically after the selected originals and batch
manifest are successfully written.

The manifests and checkpoint are local and may contain absolute filesystem
paths. Review them before sharing them publicly.

## Privacy and limitations

Daily Select does not contain an HTTP client, analytics SDK, authentication, or
cloud-model integration. Apple Vision models execute locally.

The selector cannot know the personal meaning of a moment. Its decisions are
based on technical quality, visual difference, face appearance, and broad
content balance. It intentionally copies rather than deletes, so originals
remain available when its judgment differs from yours.

If an older Mac reports `failed to create CVPixelBufferPool`, pull the latest
version and rebuild. Daily Select now limits photo-analysis memory, performs
Vision requests sequentially, retries smaller thumbnails, and keeps decodable
photos eligible through a basic fallback even if Vision remains unavailable.
For an especially memory-constrained machine, add `--photo-max-pixels 1024`.

## Development

```bash
swift test -c release
swift build -c release
```

See [CONTRIBUTING.md](CONTRIBUTING.md) before submitting a change. In
particular, do not commit personal photo libraries or manifests containing
private paths.

## License

Daily Select is available under the MIT License. See [LICENSE](LICENSE).
