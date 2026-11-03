#!/bin/bash
# macOS ships Bash 3.2; do not require associative arrays or GNU utilities.
set -euo pipefail
export LC_ALL=C HOMEBREW_NO_AUTO_UPDATE=1
ROOT=$(cd "$(dirname "$0")/.." && pwd)
RESOURCE="$ROOT/scripts/benchmark-rendering"
out=
stage=initialization
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
finish() {
    status=$?
    if [ "$status" -ne 0 ] && [ -n "$out" ]; then
        printf 'Failed during %s (exit %s). See logs in %s\n' "$stage" "$status" "$out" | tee "$out/error.txt" >&2
    fi
}
trap finish EXIT
ref=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --help|-h)
            cat <<'HELP'
Usage: scripts/benchmark-rendering.sh [--baseline-ref REF]
Compare Release rendering from the current working tree and baseline source.
Default: detect installed Homebrew Kakico and use its matching local v<version> tag.
--baseline-ref REF  Use a Git reference without Homebrew/app detection.
Requires macOS 15+, Swift 6+, Bash 3.2+, jq and Git. No Python or AI service.
Results: build/benchmarks/<timestamp>-<unique suffix>/comparison.md
HELP
            exit 0 ;;
        --baseline-ref)
            [ "$#" -ge 2 ] && [ -n "$2" ] || fail '--baseline-ref requires a Git reference'
            ref=$2; shift 2 ;;
        *) fail "Unknown argument: $1" ;;
    esac
done
for tool in jq git swift awk plutil shasum; do command -v "$tool" >/dev/null || fail "Missing tool: $tool"; done
cd "$ROOT"
mkdir -p build/benchmarks
out=$(mktemp -d "$ROOT/build/benchmarks/$(date +%Y%m%d-%H%M%S)-XXXXXX")
printf 'Artifacts: %s\n' "$out"
if [ -z "$ref" ]; then
    stage='Homebrew/app version detection'
    brew info --cask --json=v2 kakico > "$out/brew.json" 2> "$out/brew.log"
    version=$(jq -er '.casks[0].installed | select(type == "string" and length > 0)' "$out/brew.json") || fail 'Kakico is not installed; use --baseline-ref'
    app=$(jq -er '[.casks[0].artifacts[] | select(has("app"))] | select(length == 1) | .[0] | .target // ("/Applications/" + .app[0])' "$out/brew.json") || fail 'Cannot identify installed app'
    # shellcheck disable=SC2088
    case "$app" in '~/'*) app="$HOME/${app#\~/}" ;; esac
    actual=$(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")
    jq -n --arg path "$app" --arg version "$actual" '{path:$path,version:$version}' > "$out/installed-app.json"
    [ "$version" = "$actual" ] || fail "Homebrew installed version $version differs from app version $actual"
    ref="refs/tags/v$version"
fi
stage="resolving baseline $ref (matching local tag/reference required)"
commit=$(git rev-parse --verify --end-of-options "$ref^{commit}") || fail "Missing or invalid baseline reference: $ref"
stage='recording environment and source snapshots'
{
    date -u; uname -a; sw_vers; swift --version
    sysctl -n machdep.cpu.brand_string
    printf 'Bash: %s\n' "$BASH_VERSION"; jq --version
} > "$out/environment.txt" 2>&1
jq -n --arg ref "$ref" --arg commit "$commit" --arg head "$(git rev-parse HEAD)" \
    '{baseline_ref:$ref,baseline_commit:$commit,current_head:$head}' > "$out/git.json"
git status --porcelain=v1 --untracked-files=all > "$out/git-status.txt"
git diff --binary HEAD > "$out/worktree.patch"
git diff --binary --cached > "$out/staged.patch"
git archive --format=tar --output="$out/baseline.tar" "$commit"
mkdir "$out/baseline-source" "$out/current-source"
tar -xf "$out/baseline.tar" -C "$out/baseline-source"
cp -R Sources Tests Package.swift Package.resolved "$out/current-source/"
cp "$RESOURCE/Benchmark.swift" "$out/Benchmark.swift"
cp "$ROOT/scripts/benchmark-rendering.sh" "$out/benchmark-rendering.sh"
cp "$RESOURCE/report.awk" "$out/report.awk"
(cd "$out" && find baseline-source current-source -type f -exec shasum -a 256 {} +) > "$out/source-sha256.txt"
for side in baseline current; do
    stage="$side dependency preparation"
    printf '%s: preparing pinned dependencies and Release build\n' "$side"
    package="$out/$side-package"
    cp -R "$out/$side-source" "$package"
    flags=
    if [ "$side" = current ]; then flags=', swiftSettings: [.define("CURRENT_CACHE")]'; fi
    cat >> "$package/Package.swift" <<SWIFT

package.products.append(.executable(name: "RenderingBenchmark", targets: ["RenderingBenchmark"]))
package.targets.append(.executableTarget(name: "RenderingBenchmark", dependencies: ["AnnotationModel", "AnnotationRender"], path: "Benchmark"$flags))
SWIFT
    mkdir "$package/Benchmark"
    cp "$out/Benchmark.swift" "$package/Benchmark/main.swift"
    jq -e '.pins | type == "array"' "$package/Package.resolved" >/dev/null
    jq -e 'all(.pins[]; .state.revision | type == "string" and test("^[0-9a-f]{40}$"))' "$package/Package.resolved" >/dev/null || fail 'Dependency must have a full pinned revision'
    swift package --package-path "$package" --force-resolved-versions resolve > "$out/$side-resolve.log" 2>&1
    cmp "$out/$side-source/Package.resolved" "$package/Package.resolved" || fail 'Dependency lockfile changed'
    state="$package/.build/workspace-state.json"
    jq -e --slurpfile lock "$package/Package.resolved" \
        '([.object.dependencies[].packageRef.identity] | sort) == ([$lock[0].pins[].identity] | sort)' "$state" >/dev/null || fail 'Resolved dependency set differs from lockfile'
    jq -r '.pins[] | [.identity,.state.revision] | @tsv' "$package/Package.resolved" > "$out/$side-pins.tsv"
    while IFS=$'\t' read -r identity revision; do
        subpath=$(jq -er --arg id "$identity" '.object.dependencies[] | select(.packageRef.identity == $id) | .subpath' "$state")
        checkout="$package/.build/checkouts/$subpath"
        [ "$(git -C "$checkout" rev-parse HEAD)" = "$revision" ] || fail "Dependency revision mismatch: $identity"
        [ -z "$(git -C "$checkout" status --porcelain)" ] || fail "Dirty dependency: $identity"
    done < "$out/$side-pins.tsv"
    stage="$side Release build (a failure may indicate an unsupported rendering API; see $side-build.log)"
    swift build --package-path "$package" -c release --force-resolved-versions --product RenderingBenchmark > "$out/$side-build.log" 2>&1
    stage="$side measurement"
    printf '%s: measuring\n' "$side"
    "$package/.build/release/RenderingBenchmark" > "$out/$side-run.log" 2>&1
done
stage='validating all conditions and generating report'
awk -v out="$out" -v baseline="$ref" -f "$out/report.awk" "$out/baseline-run.log" "$out/current-run.log"
printf 'Completed: %s/comparison.md\n' "$out"
