#!/usr/bin/env bash
# Host perf probe body. Every result line is HP|<runner>|<rep>|<key>|<value>.
set +e
R="${R:?}"; N="${N:?}"
p() { echo "HP|$R|$N|$1|$2"; }
now_ms() { echo $(( $(date +%s%N) / 1000000 )); }
# Aggregate /proc/stat: busy+idle jiffies (user..steal) and steal jiffies.
cpu_snap() { awk '/^cpu /{t=0; for(i=2;i<=9;i++) t+=$i; print t, $9}' /proc/stat; }
steal_pct() {
  read -r t0 s0 <<<"$1"; read -r t1 s1 <<<"$2"
  awk -v a="$t0" -v b="$s0" -v c="$t1" -v d="$s1" 'BEGIN{dt=c-a; if (dt<=0) print "na"; else printf "%.2f", 100*(d-b)/dt}'
}
phase() {
  local name=$1; shift
  local c0 c1 t0 t1
  c0=$(cpu_snap); t0=$(now_ms)
  "$@" >/dev/null 2>&1
  t1=$(now_ms); c1=$(cpu_snap)
  p "${name}_ms" $((t1 - t0))
  p "${name}_steal_pct" "$(steal_pct "$c0" "$c1")"
}

JOB0=$(cpu_snap)
D="$RUNNER_TEMP/hp"; mkdir -p "$D"
p runner_name "$RUNNER_NAME"
p nproc "$(nproc)"
p mem_gb "$(free -g | awk '/^Mem:/{print $2}')"
p start_utc "$(date -u +%FT%TZ)"
p kernel "$(uname -r)"
p disk_src "$(df -P "$D" | awk 'NR==2{print $1}')"
p disk_fs "$(df -PT "$D" | awk 'NR==2{print $2}')"

# Block devices as the guest sees them: write cache mode decides whether fsync sends a flush.
for b in /sys/block/*; do
  n=$(basename "$b"); case "$n" in loop*|ram*|zram*|nbd*) continue;; esac
  p "blk_${n}_write_cache" "$(cat "$b/queue/write_cache" 2>/dev/null)"
  p "blk_${n}_fua" "$(cat "$b/queue/fua" 2>/dev/null)"
  p "blk_${n}_size_gb" "$(( $(cat "$b/size" 2>/dev/null || echo 0) * 512 / 1000000000 ))"
done
p root_src "$(findmnt -no SOURCE / 2>/dev/null)"
p work_src "$(findmnt -no SOURCE -T "$D" 2>/dev/null)"
sudo apt-get update -qq >/dev/null 2>&1
sudo apt-get install -y -qq --no-install-recommends fio jq >/dev/null 2>&1
p fio_version "$(fio --version 2>/dev/null)"

fiojob() {
  local name=$1; shift
  local out="$D/$name.json" c0 c1 side v
  c0=$(cpu_snap)
  fio --name="$name" --directory="$D" --output-format=json --output="$out" "$@" >/dev/null 2>&1
  c1=$(cpu_snap)
  p "fio_${name}_steal_pct" "$(steal_pct "$c0" "$c1")"
  for side in write read; do
    v=$(jq -r ".jobs[0].${side}.iops // 0 | floor" "$out" 2>/dev/null)
    if [ -n "$v" ] && [ "$v" != "0" ]; then
      p "fio_${name}_${side}_iops" "$v"
      p "fio_${name}_${side}_bw_mibs" "$(jq -r ".jobs[0].${side}.bw_bytes/1048576 | floor" "$out")"
      p "fio_${name}_${side}_clat_p50_us" "$(jq -r ".jobs[0].${side}.clat_ns.percentile[\"50.000000\"] // 0 | ./1000 | floor" "$out")"
      p "fio_${name}_${side}_clat_p99_us" "$(jq -r ".jobs[0].${side}.clat_ns.percentile[\"99.000000\"] // 0 | ./1000 | floor" "$out")"
    fi
  done
  v=$(jq -r '.jobs[0].sync.lat_ns.percentile["50.000000"] // empty | ./1000 | floor' "$out" 2>/dev/null)
  [ -n "$v" ] && p "fio_${name}_fsync_p50_us" "$v"
  v=$(jq -r '.jobs[0].sync.lat_ns.percentile["99.000000"] // empty | ./1000 | floor' "$out" 2>/dev/null)
  [ -n "$v" ] && p "fio_${name}_fsync_p99_us" "$v"
  rm -f "$D/$name".[0-9]*.[0-9]* 2>/dev/null
}
# Small synced writes (Postgres commits, BuildKit metadata), then bulk throughput.
fiojob fsync4k --rw=randwrite --bs=4k --size=256M --ioengine=sync --fsync=1 --runtime=20 --time_based
fiojob seqw1m --rw=write --bs=1M --size=2G --ioengine=libaio --iodepth=16 --direct=1 --runtime=15 --time_based
fiojob randr4k --rw=randread --bs=4k --size=1G --ioengine=libaio --iodepth=32 --direct=1 --runtime=15 --time_based

# Package-install style churn: 20k small files, then sync; then delete and sync.
mkfiles() {
  python3 - "$1" <<'PY'
import os, sys
root = sys.argv[1]
data = b"x" * 4096
for d in range(200):
    dp = os.path.join(root, f"d{d}")
    os.makedirs(dp, exist_ok=True)
    for f in range(100):
        with open(os.path.join(dp, f"f{f}.js"), "wb") as fh:
            fh.write(data)
PY
  sync
}
phase small_create_sync mkfiles "$D/sf"
phase small_delete_sync bash -c "rm -rf '$D/sf' && sync"

# tsc: the same synthetic project on disk and on tmpfs, one compile and one per vCPU.
npm install -g --no-audit --no-fund "typescript@${TS_VERSION}" >/dev/null 2>&1
p tsc_version "$(tsc -v 2>/dev/null)"
gen() {
  mkdir -p "$1/src"
  OUT="$1" MODULES="$2" node -e 'const fs=require("fs"),o=process.env.OUT,n=+process.env.MODULES;for(let i=0;i<n;i++){const dep=i>0?`import { v${i-1} } from "./m${i-1}";`:"";fs.writeFileSync(`${o}/src/m${i}.ts`,`${dep}\nexport const v${i}: number = ${i};\nexport interface I${i} { a: number; b: string; c: number[]; d: Record<string,number> }\nexport function f${i}(x: I${i}): number { return x.a + x.c.length + Object.keys(x.d).length${i>0?" + v"+(i-1):""}; }\nexport type T${i}<X> = { wrapped: X; tag: "m${i}"; list: I${i}[] };\n`)}'
  printf '{"compilerOptions":{"target":"ES2022","module":"commonjs","declaration":true,"sourceMap":true,"strict":true,"outDir":"dist","rootDir":"src"},"include":["src"]}' > "$1/tsconfig.json"
}
NP=$(nproc)
for where in disk shm; do
  base="$D/ts"; [ "$where" = shm ] && base=/dev/shm/hp-ts
  gen "$base/st" 800
  for i in 1 2 3; do
    rm -rf "$base/st/dist"
    phase "tsc_st_${where}_${i}" tsc -p "$base/st/tsconfig.json"
  done
  for k in $(seq 1 "$NP"); do gen "$base/mt$k" 300; done
  mt() { local k; for k in $(seq 1 "$NP"); do tsc -p "$base/mt$k/tsconfig.json" & done; wait; }
  phase "tsc_mt_${where}" mt
  rm -rf "$base"
done

# Commit-heavy Postgres (fsync on) in the service container.
if [ -n "$PG_CID" ]; then
  docker exec "$PG_CID" pgbench -U postgres -i -s 10 -q postgres >/dev/null 2>&1
  c0=$(cpu_snap)
  out=$(docker exec "$PG_CID" pgbench -U postgres -c 8 -j 4 -T 30 postgres 2>/dev/null)
  c1=$(cpu_snap)
  p pgbench_tps "$(echo "$out" | awk '/^tps/{print $3; exit}')"
  p pgbench_lat_ms "$(echo "$out" | awk -F'= ' '/latency average/{split($2,a," "); print a[1]; exit}')"
  p pgbench_steal_pct "$(steal_pct "$c0" "$c1")"
fi

p job_steal_pct "$(steal_pct "$JOB0" "$(cpu_snap)")"
p end_utc "$(date -u +%FT%TZ)"
