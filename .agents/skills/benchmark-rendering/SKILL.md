---
name: benchmark-rendering
description: Project skill for comparing Kakico rendering performance in release builds. Use for rendering benchmarks, cached-rendering measurements, and performance comparisons between a Homebrew version and the working tree.
---

# Rendering Benchmarks

Run `bash scripts/benchmark-rendering.sh` from the repository root.
By default, the script checks the Homebrew installation information against the app version and uses the source for the matching local tag as the baseline.
If a baseline is specified, use `bash scripts/benchmark-rendering.sh --baseline-ref <ref>`. Homebrew is not required in this case.
See the root README for prerequisites and usage. No connection to an AI service is required.

Read `build/benchmarks/<timestamp-and-unique-suffix>/comparison.md` and `summary.csv` printed by the CLI. Report the median, p95, first-generation time, and multiplier against the baseline for normal and cached rendering.
The multiplier is current time divided by baseline time; a lower value is faster. Distinguish the first, middle, and last interaction targets. With a single shape, these are the same target, so duplicates are omitted.
The CLI validates 84 combinations across all 28 scenarios and three rendering modes, covering 2,940 frames. It does not determine pass or fail using performance thresholds.

State that this comparison rebuilds the matching source and does not measure the installed binary.
Results include rendering-content differences such as shadows. They do not use a base image or include screen transfer and UI processing. Do not describe a small difference in a single run as statistically significant.

On failure, check the exit code, the saved `error.txt`, and the relevant log, then report the specific cause.
Do not hide a missing tag, version mismatch, or unsupported API by automatically switching to another baseline.
Preserve existing results and the user's source changes. To rerun a benchmark, use the same CLI and let it create a new output directory.
