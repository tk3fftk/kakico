#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
out=$(mktemp -d "${TMPDIR:-/tmp}/rendering-test-XXXXXX")
trap 'rm -rf "$out"' EXIT
for side in baseline current; do
    awk -v side="$side" 'BEGIN {
        split("1920 3840",w); split("1 20 100",n); split("6 24",s)
        for(a=1;a<=2;a++) for(b=1;b<=3;b++) for(c=1;c<=2;c++)
        for(p=1;p<=(n[b]==1?1:3);p++) for(m=1;m<=(side=="baseline"?1:2);m++)
        for(f=0;f<35;f++) {
            i=p==1?0:(p==2?int(n[b]/2):n[b]-1)
            printf "SAMPLE,%d,%d,%d,%d,%s,%d,%d\n",w[a],n[b],s[c],i,(m==1?"normal":"cache"),f,(f+1)*(side=="baseline"?1:2)
        }
        print "BENCHMARK_COMPLETE"
    }' > "$out/$side.log"
done
report() { awk -v out="$out" -v baseline=test -f "$ROOT/scripts/benchmark-rendering/report.awk" "$out/baseline.log" "$out/current.log"; }
report
[ "$(wc -l < "$out/samples.csv" | tr -d ' ')" = 2941 ]
awk -F, 'NR>1 {
    m=$1=="baseline"?1:2
    if ($7!=20.5*m || $8!=34*m || $9!=m || $10!=m || $11!=m) exit 1
} END { if (NR!=85) exit 1 }' "$out/summary.csv"
cp "$out/baseline.log" "$out/good.log"
for kind in missing_marker missing_frame duplicate nan zero overflow unexpected_mode malformed; do
    case "$kind" in
        missing_marker) sed '/BENCHMARK_COMPLETE/d' "$out/good.log" > "$out/baseline.log" ;;
        missing_frame) sed '1d' "$out/good.log" > "$out/baseline.log" ;;
        duplicate) sed '1p' "$out/good.log" > "$out/baseline.log" ;;
        nan) sed '1s/,1$/,nan/' "$out/good.log" > "$out/baseline.log" ;;
        zero) sed '1s/,1$/,0/' "$out/good.log" > "$out/baseline.log" ;;
        overflow) sed '1s/,1$/,1e999/' "$out/good.log" > "$out/baseline.log" ;;
        unexpected_mode) sed '1s/normal/cache/' "$out/good.log" > "$out/baseline.log" ;;
        malformed) sed '1s/$/,extra/' "$out/good.log" > "$out/baseline.log" ;;
    esac
    if report > "$out/invalid.log" 2>&1; then printf 'FAIL: accepted %s\n' "$kind" >&2; exit 1; fi
    grep -q ERROR "$out/invalid.log"
done
printf 'PASS: 2940 samples, 84 summaries, median/p95/first/ratios and 8 invalid logs\n'
