# POSIX awk: validate every frame before writing any successful report.
BEGIN {
    FS = OFS = ","
    split("1920 3840", widths, " "); split("1 20 100", counts, " "); split("6 24", strokes, " ")
    for (w=1; w<=2; w++) for (n=1; n<=3; n++) for (s=1; s<=2; s++) {
        count=counts[n]
        for (p=1; p<=(count==1 ? 1 : 3); p++) {
            indexValue=(p==1 ? 0 : (p==2 ? int(count/2) : count-1))
            condition[++total]=widths[w] OFS count OFS strokes[s] OFS indexValue
            for (mode=1; mode<=3; mode++) {
                key=condition[total] OFS mode
                expected[key]=1
            }
        }
    }
}
function bad(message) { print "ERROR: " message > "/dev/stderr"; failed=1; exit 1 }
FNR==1 { file++ }
$0=="BENCHMARK_COMPLETE" { complete[file]++; next }
/^SAMPLE/ {
    if (complete[file]) bad("sample after completion marker")
    if (NF!=8 || $1!="SAMPLE") bad("malformed sample: " $0)
    mode=(file==1 && $6=="normal" ? 1 : (file==2 && $6=="normal" ? 2 : (file==2 && $6=="cache" ? 3 : 0)))
    key=$2 OFS $3 OFS $4 OFS $5 OFS mode
    if (!(key in expected) || $7 !~ /^(0|[1-9][0-9]*)$/ || $7+0>34) bad("unexpected condition/frame: " $0)
    if ($8 !~ /^[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$/ || $8+0<=0 || tolower(sprintf("%g", $8+0)) ~ /inf|nan/) bad("invalid timing: " $0)
    sampleKey=key SUBSEP $7
    if (sampleKey in samples) bad("duplicate sample: " $0)
    samples[sampleKey]=$8+0
    frames[key]++
}
END {
    if (failed) exit 1
    if (file!=2 || complete[1]!=1 || complete[2]!=1) bad("incomplete benchmark logs")
    for (key in expected) if (frames[key]!=35) bad("missing condition or frames: " key)
    for (c=1; c<=total; c++) for (mode=1; mode<=3; mode++) {
        key=condition[c] OFS mode
        for (i=1; i<=30; i++) sorted[i]=samples[key SUBSEP (i+4)]
        for (i=2; i<=30; i++) {
            value=sorted[i]; j=i-1
            while (j>=1 && sorted[j]>value) { sorted[j+1]=sorted[j]; j-- }
            sorted[j+1]=value
        }
        median[key]=(sorted[15]+sorted[16])/2
        p95[key]=sorted[29]
        first[key]=samples[key SUBSEP 0]
    }
    raw=out "/samples.csv"; summary=out "/summary.csv"; report=out "/comparison.md"
    print "side,canvas_width,count,stroke,active_index,mode,frame,ms" > raw
    print "side,canvas_width,count,stroke,active_index,mode,median_ms,p95_ms,first_ms,median_ratio,p95_ratio" > summary
    print "# Rendering comparison: " baseline "\n" > report
    print "Both source snapshots are rebuilt in Release; the installed binary is not measured." > report
    print "Current includes uncommitted source changes. Rendering differences such as shadows are included; output images need not match." > report
    print "Arrows, lines, rectangles and ellipses; active element moves 1 px/frame. No base image, scale 1." > report
    print "Image generation/compositing included; screen transfer, UI processing, loading and export excluded." > report
    print "35 frames/condition, first 5 excluded. Median: middle two averaged; p95: 29th of 30. First: frame 0 including cache preparation." > report
    print "First/middle/last deduplicated for one shape: 28 conditions, 84 groups, 2940 samples." > report
    print "Sequential baseline then current. No performance pass/fail threshold. System load and execution order affect results." > report
    print "Times: median / p95 / first (ms). Ratios: current/baseline median / p95 (lower is faster).\n" > report
    print "|Width|Count|Stroke|Active index|Baseline normal|Current normal|Current cache|Normal/baseline|Cache/baseline|" > report
    print "|---:|---:|---:|---:|---:|---:|---:|---:|---:|" > report
    for (c=1; c<=total; c++) {
        row=condition[c]; gsub(/,/, "|", row); row="|" row "|"
        base=condition[c] OFS 1
        for (mode=1; mode<=3; mode++) {
            key=condition[c] OFS mode
            prefix=(mode==1 ? "baseline" : "current") OFS condition[c] OFS (mode==3 ? "cache" : "normal")
            for (frame=0; frame<35; frame++) printf "%s,%d,%.12g\n", prefix,frame,samples[key SUBSEP frame] > raw
            printf "%s,%.12g,%.12g,%.12g,%.12g,%.12g\n",prefix,median[key],p95[key],first[key],median[key]/median[base],p95[key]/p95[base] > summary
            row=row sprintf("%.4f / %.4f / %.4f|",median[key],p95[key],first[key])
        }
        for (mode=2; mode<=3; mode++) {
            key=condition[c] OFS mode
            row=row sprintf("%.3fx / %.3fx|",median[key]/median[base],p95[key]/p95[base])
        }
        print row > report
    }
}
