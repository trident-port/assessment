#!/usr/bin/env bash
# ============================================================================
# tp-bench.sh - measure how fast a copy runs on THIS cluster.
#
# WHAT IT IS FOR
#
# tp-pre.sh says how much data there is. This says how fast it moves. The two
# files feed tp-estimate, which turns them into the tables of how long the
# migration would take. Every rate in those tables is a number this script
# measured here, not a number from a brochure.
#
# Run it through tp-pre.sh (`./tp-pre.sh --bench --dest-sc <class>`) to get one
# report, or on its own as below.
#
# IT CREATES THINGS. That is why it does nothing unless it is given --bench.
# Without --bench it prints what it WOULD create and exits.
#
# WHAT IT CREATES (all of it in one namespace, `tp-bench`)
#   * the namespace tp-bench
#   * one claim per source class, and up to 16 claims on the destination class
#   * one pod for the owner test and one pod per source class
# WHAT IT DELETES: the namespace tp-bench, by name, when it ends, when it fails
# and when it is interrupted (Ctrl-C or a kill). Nothing else is deleted. A
# volume that a class keeps after its claim is gone (reclaimPolicy Retain) is
# listed by name and left alone: only the array administrator can say whether
# its data may go.
#
# WHAT IT MEASURES, on every source class
#   four kinds of data, each on its own
#     large     a few very large files (default 4 x 10 GiB, always at least twice
#               the memory of the copy pod, so the cache cannot hold them)
#     medium    1,000 files of 1-16 MiB
#     small     1,000,000 files of 1-8 KiB, in a tree 4 to 6 directories deep
#     mixed     a share of the three together
#   the copy of each with 1, 4, 8 and 16 copies at once (large and small),
#   each measurement repeated, with the spread reported
#   the node CPU and memory and the pod memory during every run
#   a second pass over an unchanged tree, and a pass after 1 and 10 percent of
#   the files changed: that is the last pass of a live copy, the cutover window
#   whether the destination keeps file owners (NFSv4 may turn root into nobody)
#
# USAGE
#   ./tp-bench.sh --source-sc sc-a,sc-b --dest-sc sc-dest            (shows the plan)
#   ./tp-bench.sh --bench --source-sc sc-a,sc-b --dest-sc sc-dest   (runs it)
#
# OPTIONS
#   --bench              really create things and measure (without it: plan only)
#   --source-sc A,B      source classes to measure, comma separated (required)
#   --dest-sc X          destination class (required)
#   --size S             small, medium (default) or large, or a number of GiB of
#                        test data in the source claim. medium is about 60 GiB
#   --yes                do not ask for confirmation
#   --parallel 1,4,8,16  simultaneous copies to measure (1 is always added)
#   --reps N             repetitions of each single-slice measurement (default 3)
#   --pod-mem-gib N      memory limit of the copy pod (default: 1, 2 or 4 by size)
#   --large-files N      files of the large profile (default 4)
#   --large-gib N        GiB of each large file (default 10)
#   --medium-files N     files of the medium profile (default 1000)
#   --small-files N      files of the small profile (default 1000000)
#   --image IMG          image with rsync, bash, python3 and coreutils. Default:
#                        the Trident Port image of this bundle (TP_SELF_IMAGE,
#                        or the tag written into this file)
#   --run-as-root        run the pods as root. Needed only for the owner test
#                        (chown). On OpenShift this needs a security context
#                        constraint that allows uid 0; the script prints the
#                        command for the administrator and waits
#   --timeout-min N      minutes each source class may take (default 600)
#   --out-dir DIR        where the result files go (default: here)
#   -h, --help           this text
#
# LEAVES ON YOUR DISK
#   tp-bench-<context>-<date>.json   the measurements (the estimator reads this)
#   tp-bench-<context>-<date>.md     the same, as a table a person reads
# The rsync options are the ones the product uses for a first copy:
#   rsync -aH --numeric-ids --sparse --inplace --delete --stats
# ============================================================================
set -uo pipefail

readonly NS=tp-bench
readonly OWNER_LABEL="app.kubernetes.io/managed-by=tp-bench"
readonly RSYNC_FLAGS="-aH --numeric-ids --sparse --inplace --delete --stats --exclude=/lost+found --exclude=/.snapshot"
DEFAULT_IMAGE="ghcr.io/calzdevops/trident-port:v1.2.12"

BENCH=false
YES=false
SRC_SC=""
DST_SC=""
SIZE="medium"
PARALLEL="1,4,8,16"
REPS=3
POD_MEM_GIB=""
LARGE_FILES=""
LARGE_GIB=""
MEDIUM_FILES=""
SMALL_FILES=""
IMAGE="${TP_SELF_IMAGE:-${MIGRATION_IMAGE:-$DEFAULT_IMAGE}}"
RUN_AS_ROOT=false
TIMEOUT_MIN=600
OUT_DIR="."
POLL="${TP_BENCH_POLL:-10}"

usage() { grep '^#' "$0" | sed 's/^# \{0,1\}//'; }

# The runner is the script the pod runs. It is kept in this file so there is one
# thing to ship, and it can be printed (--print-runner) so that a test can run
# the very same text on a laptop with plain directories instead of volumes.
read -r -d '' RUNNER <<'RUNNER_EOF'
set -u
SRC="${TPB_SRC:-/src}"
DST="${TPB_DST:-/dst}"
RSYNC_FLAGS="${TPB_RSYNC_FLAGS:--aH --numeric-ids --sparse --inplace --delete --stats --exclude=/lost+found --exclude=/.snapshot}"
TMPD="$(mktemp -d)"
now_ms() { date +%s%3N; }
emit() { echo "TPB $1"; }
sync_dir() { sync -f "$1" 2>/dev/null || sync; }
clean_dir() { find "$1" -mindepth 1 -delete 2>/dev/null || rm -rf "$1"/* "$1"/.[!.]* 2>/dev/null; }

if [ "${TPB_MODE:-bench}" = "owner" ]; then
  D="${DST}1"
  me=$(id -u); mg=$(id -g)
  mnt=$(grep " /dst1 " /proc/mounts 2>/dev/null | head -n 1 | cut -d' ' -f3,4)
  idm=$(nfsidmap -d 2>/dev/null | head -n 1)
  f="$D/.tpb-owner.$$"
  : > "$f" 2>/dev/null || { emit "{\"event\":\"owner\",\"tested\":false,\"why\":\"the destination did not accept a file (uid $me)\"}"; exit 0; }
  kept="$(stat -c %u:%g "$f" 2>/dev/null)"
  rm -f "$f"
  emit "{\"event\":\"owner\",\"uid\":$me,\"gid\":$mg,\"created_file_reads_back_as\":\"$kept\",\"mount\":\"$mnt\",\"nfs_id_domain\":\"$idm\"}"
  if [ "$me" != "0" ]; then
    emit "{\"event\":\"owner\",\"tested\":false,\"why\":\"the pod runs as uid $me, not root: chown needs root. Run again with --run-as-root to test 0:0\"}"
    exit 0
  fi
  for pair in 0:0 1000:1000 1000:0; do
    : > "$f"
    if chown "$pair" "$f" 2>/dev/null; then
      got="$(stat -c %u:%g "$f" 2>/dev/null)"
      verdict="kept"
      [ "$got" = "$pair" ] || verdict="changed"
      emit "{\"event\":\"owner\",\"tested\":true,\"wrote\":\"$pair\",\"read_back\":\"$got\",\"verdict\":\"$verdict\"}"
    else
      emit "{\"event\":\"owner\",\"tested\":true,\"wrote\":\"$pair\",\"verdict\":\"chown refused\"}"
    fi
    rm -f "$f"
  done
  exit 0
fi

command -v python3 >/dev/null 2>&1 || { emit '{"event":"error","why":"the image has no python3"}'; exit 3; }
command -v rsync >/dev/null 2>&1 || { emit '{"event":"error","why":"the image has no rsync"}'; exit 3; }

LARGE_FILES="${TPB_LARGE_FILES:-4}"; LARGE_MIB="${TPB_LARGE_MIB:-10240}"
MEDIUM_FILES="${TPB_MEDIUM_FILES:-1000}"; SMALL_FILES="${TPB_SMALL_FILES:-1000000}"
UNITS="${TPB_UNITS:-16}"; REPS="${TPB_REPS:-3}"; FULL_REPS="${TPB_FULL_REPS:-2}"
KS="${TPB_PARALLEL:-1,4,8,16}"

cat > "$TMPD/tpgen" <<'PYGEN'
import json, os, random, sys, time


def write_file(path, size):
    with open(path, "wb") as fh:
        left = size
        while left > 0:
            n = min(left, 4 * 1024 * 1024)
            fh.write(os.urandom(n))
            left -= n


def tree(root, prefix, nunits, nfiles, lo, hi, dmin, dmax, seed, stats):
    rnd = random.Random(seed)
    per = [[0, 0] for _ in range(nunits)]
    made = set()
    for i in range(nfiles):
        u = i % nunits
        depth = rnd.randint(dmin, dmax)
        parts = ["%s%02d" % (prefix, u)] + ["d%d" % rnd.randrange(6) for _ in range(depth)]
        d = os.path.join(root, *parts)
        if d not in made:
            os.makedirs(d, exist_ok=True)
            made.add(d)
        size = rnd.randint(lo, hi)
        write_file(os.path.join(d, "f%07d" % i), size)
        per[u][0] += 1
        per[u][1] += size
    with open(stats, "a") as out:
        for u, (f, b) in enumerate(per):
            out.write("%s %d %d %d\n" % (os.path.basename(root) + ":" + prefix, u, f, b))


def mutate(root, pct):
    every = max(1, int(round(100.0 / pct)))
    n = changed = nbytes = 0
    for dirpath, dirs, files in os.walk(root):
        dirs.sort()
        for name in sorted(files):
            n += 1
            if n % every and n != 1:
                continue
            p = os.path.join(dirpath, name)
            size = os.path.getsize(p)
            before = os.stat(p).st_mtime_ns
            with open(p, "r+b") as fh:
                fh.write(os.urandom(min(size, 1024)))
            # rsync calls a file unchanged when size and whole-second mtime match. A file
            # changed twice inside one second would be skipped by the second pass, so the
            # new mtime is always at least two seconds past the old one.
            new = max(time.time_ns(), before + 2000000000)
            os.utime(p, ns=(new, new))
            changed += 1
            nbytes += size
    print(json.dumps({"changed_files": changed, "changed_bytes": nbytes}))


def sample(path, t0, t1):
    rows = []
    for line in open(path):
        p = line.split()
        if len(p) == 6 and t0 <= int(p[0]) <= t1:
            rows.append([int(x) for x in p])
    out = {"samples": len(rows)}
    if len(rows) >= 2:
        cpu = []
        for a, b in zip(rows, rows[1:]):
            dt = b[2] - a[2]
            if dt > 0:
                cpu.append(100.0 * (b[1] - a[1]) / dt)
        span = (rows[-1][0] - rows[0][0]) / 1000.0
        if cpu:
            out["node_cpu_avg_pct"] = round(100.0 * (rows[-1][1] - rows[0][1]) / max(1, rows[-1][2] - rows[0][2]), 1)
            out["node_cpu_max_pct"] = round(max(cpu), 1)
        if span > 0 and rows[-1][3] >= rows[0][3] and rows[0][3] > 0:
            out["pod_cpu_cores_avg"] = round((rows[-1][3] - rows[0][3]) / 1e6 / span, 2)
        out["pod_mem_max_bytes"] = max(r[4] for r in rows)
        out["node_mem_avail_min_bytes"] = min(r[5] for r in rows) * 1024
    print(json.dumps(out))


cmd = sys.argv[1]
if cmd == "tree":
    root, prefix, nunits, nfiles, lo, hi, dmin, dmax, seed, stats = sys.argv[2:12]
    tree(root, prefix, int(nunits), int(nfiles), int(lo), int(hi), int(dmin), int(dmax), int(seed), stats)
elif cmd == "mutate":
    mutate(sys.argv[2], float(sys.argv[3]))
elif cmd == "sample":
    sample(sys.argv[2], int(sys.argv[3]), int(sys.argv[4]))
PYGEN
GEN="python3 $TMPD/tpgen"

# ---- what the pod can see of itself -------------------------------------------
pod_ram() {
  local v; v=$(cat /sys/fs/cgroup/memory.max 2>/dev/null)
  case "$v" in ''|max) v=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null) ;; esac
  case "$v" in ''|*[!0-9]*) v=0 ;; esac
  [ "${#v}" -gt 15 ] && v=0
  echo "$v"
}
host_ram() { local k v; while read -r k v _; do [ "$k" = "MemTotal:" ] && { echo $((v * 1024)); return; }; done </proc/meminfo; echo 0; }
cg_cpu() {
  local k v
  if [ -r /sys/fs/cgroup/cpu.stat ]; then
    while read -r k v; do [ "$k" = usage_usec ] && { echo "$v"; return; }; done </sys/fs/cgroup/cpu.stat
  elif [ -r /sys/fs/cgroup/cpuacct/cpuacct.usage ]; then echo $(( $(cat /sys/fs/cgroup/cpuacct/cpuacct.usage) / 1000 )); return
  fi
  echo 0
}
cg_mem() { cat /sys/fs/cgroup/memory.current 2>/dev/null || cat /sys/fs/cgroup/memory/memory.usage_in_bytes 2>/dev/null || echo 0; }
node_avail() { local k v; while read -r k v _; do [ "$k" = "MemAvailable:" ] && { echo "$v"; return; }; done </proc/meminfo; echo 0; }
SAMPLES="$TMPD/samples"; : > "$SAMPLES"
sample_line() {
  local u n s i w q sq st
  read -r _ u n s i w q sq st _ </proc/stat
  echo "$(now_ms) $((u + n + s + q + sq + st)) $((u + n + s + i + w + q + sq + st)) $(cg_cpu) $(cg_mem) $(node_avail)" >> "$SAMPLES"
}
( while :; do sample_line; sleep 2; done ) &
SAMPLER=$!
trap 'kill $SAMPLER 2>/dev/null; rm -rf "$TMPD"' EXIT

emit "{\"event\":\"pod\",\"ram_limit_bytes\":$(pod_ram),\"host_ram_bytes\":$(host_ram),\"cpus\":$(nproc 2>/dev/null || echo 0),\"uid\":$(id -u)}"

# ---- fill the source with the profiles ---------------------------------------
mkdir -p "$SRC/large" "$SRC/medium" "$SRC/small" "$SRC/mixed" || { emit '{"event":"error","why":"the source claim is not writable"}'; exit 3; }
STATS="$TMPD/stats"; : > "$STATS"
MIB=1048576
fill() {  # profile, then the arguments of `gen tree`
  local p=$1; shift
  local t0 t1; t0=$(now_ms)
  echo "TPB_PROGRESS filling $p"
  $GEN tree "$@" "$STATS" || { emit "{\"event\":\"error\",\"why\":\"could not write the $p profile\"}"; exit 3; }
  sync_dir "$SRC"
  t1=$(now_ms)
  FILL_MS=$((t1 - t0))
}
tot() { awk -v t="$1" '$1==t {f+=$3; b+=$4} END {print f+0, b+0}' "$STATS" 2>/dev/null; }
fill_event() {  # profile tag
  local f b; read -r f b <<<"$(tot "$2")"
  emit "{\"event\":\"fill\",\"profile\":\"$1\",\"ms\":$FILL_MS,\"files\":$f,\"bytes\":$b}"
}
fill large  "$SRC/large"  u "$LARGE_FILES" "$LARGE_FILES" $((LARGE_MIB * MIB)) $((LARGE_MIB * MIB)) 0 0 11; fill_event large large:u
fill medium "$SRC/medium" u "$UNITS" "$MEDIUM_FILES" $((1 * MIB)) $((16 * MIB)) 4 6 12; fill_event medium medium:u
fill small  "$SRC/small"  u "$UNITS" "$SMALL_FILES" 1024 8192 4 6 13; fill_event small small:u
MT0=$(now_ms)
$GEN tree "$SRC/mixed" L 1 2 $((LARGE_MIB / 5 * MIB)) $((LARGE_MIB / 5 * MIB)) 0 0 14 "$STATS" &&
$GEN tree "$SRC/mixed" M 1 $((MEDIUM_FILES / 4)) $((1 * MIB)) $((16 * MIB)) 4 6 15 "$STATS" &&
$GEN tree "$SRC/mixed" S 1 $((SMALL_FILES / 4)) 1024 8192 4 6 16 "$STATS" || { emit '{"event":"error","why":"could not write the mixed profile"}'; exit 3; }
sync_dir "$SRC"
FILL_MS=$(( $(now_ms) - MT0 ))
mf=0; mb=0
for t in mixed:L mixed:M mixed:S; do read -r f b <<<"$(tot "$t")"; mf=$((mf + f)); mb=$((mb + b)); done
emit "{\"event\":\"fill\",\"profile\":\"mixed\",\"ms\":$FILL_MS,\"files\":$mf,\"bytes\":$mb}"

declare -A UF UB NU PFX
while read -r tag u f b; do
  p=${tag%%:*}; px=${tag##*:}
  case "$p" in large|medium|small) UF["$p:$u"]=$f; UB["$p:$u"]=$b; PFX[$p]=$px; NU[$p]=$(( ${NU[$p]:-0} + 1 )) ;; esac
done < "$STATS"
declare -A TF TB
for p in large medium small; do TF[$p]=0; TB[$p]=0; i=0; while [ "$i" -lt "${NU[$p]}" ]; do TF[$p]=$(( ${TF[$p]} + ${UF["$p:$i"]} )); TB[$p]=$(( ${TB[$p]} + ${UB["$p:$i"]} )); i=$((i + 1)); done; done
TF[mixed]=$mf; TB[mixed]=$mb

# ---- copies ------------------------------------------------------------------
PIDS=""
one_copy() {  # src dst resultfile files bytes
  (
    s=$(now_ms)
    rsync $RSYNC_FLAGS "$1/" "$2/" >"$3.out" 2>&1
    rc=$?
    sync_dir "$2"
    e=$(now_ms)
    echo "$((e - s)) $rc $4 $5" > "$3"
  ) &
  PIDS="$PIDS $!"
}
collect() {  # k -> json array of copies
  local j out=""
  for j in $(seq 1 "$1"); do
    read -r ms rc f b < "$TMPD/r.$j" || { ms=0; rc=99; f=0; b=0; }
    out="$out${out:+,}{\"ms\":$ms,\"rc\":$rc,\"files\":$f,\"bytes\":$b}"
  done
  echo "[$out]"
}
finish_run() {  # pass profile k rep wall_ms ws we [extra json fields]
  local smp; sample_line; smp=$($GEN sample "$SAMPLES" "$6" "$7")
  emit "{\"event\":\"run\",\"pass\":\"$1\",\"profile\":\"$2\",\"k\":$3,\"rep\":$4,\"wall_ms\":$5,\"copies\":$(collect "$3"),\"sample\":$smp${8:-}}"
}

run_units() {  # profile k rep
  local P=$1 k=$2 rep=$3 n=${NU[$1]} j idx ws we
  for j in $(seq 1 "$k"); do clean_dir "$DST$j"; done
  echo "TPB_PROGRESS $P x$k slice rep $rep"
  sample_line; ws=$(now_ms); PIDS=""
  for j in $(seq 1 "$k"); do
    idx=$(( ((rep - 1) * k + j - 1) % n ))
    one_copy "$SRC/$P/${PFX[$P]}$(printf '%02d' "$idx")" "$DST$j" "$TMPD/r.$j" "${UF["$P:$idx"]}" "${UB["$P:$idx"]}"
  done
  # shellcheck disable=SC2086
  wait $PIDS; we=$(now_ms)
  finish_run unit "$P" "$k" "$rep" $((we - ws)) "$ws" "$we"
}
run_tree() {  # pass profile rep [pct] [extra]
  local kind=$1 P=$2 rep=$3 ws we
  echo "TPB_PROGRESS $P $kind rep $rep"
  sample_line; ws=$(now_ms); PIDS=""
  one_copy "$SRC/$P" "${DST}1" "$TMPD/r.1" "${TF[$P]}" "${TB[$P]}"
  # shellcheck disable=SC2086
  wait $PIDS; we=$(now_ms)
  finish_run "$kind" "$P" 1 "$rep" $((we - ws)) "$ws" "$we" "${5:-}"
}

for P in large medium small; do
  if [ "$P" = "medium" ]; then ks="1"; else ks="$KS"; fi
  for k in ${ks//,/ }; do
    rep=1; while [ "$rep" -le "$REPS" ]; do run_units "$P" "$k" "$rep"; rep=$((rep + 1)); done
  done
done

for P in medium small mixed; do
  rep=1
  while [ "$rep" -le "$FULL_REPS" ]; do clean_dir "${DST}1"; run_tree full "$P" "$rep"; rep=$((rep + 1)); done
  # the destination now holds a complete copy: an unchanged tree, then 1 and 10 percent changed
  rep=1; while [ "$rep" -le "$FULL_REPS" ]; do run_tree noop "$P" "$rep"; rep=$((rep + 1)); done
  for pct in 1 10; do
    chg=$($GEN mutate "$SRC/$P" "$pct"); chg=${chg#\{}; chg=${chg%\}}
    sync_dir "$SRC"
    run_tree delta "$P" 1 "$pct" ",\"pct\":$pct,$chg"
  done
done
echo "TPB_DONE"
RUNNER_EOF

# ---- arguments ---------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --bench) BENCH=true; shift ;;
    --yes|-y) YES=true; shift ;;
    --source-sc) SRC_SC="${2:-}"; shift 2 ;;
    --dest-sc) DST_SC="${2:-}"; shift 2 ;;
    --size) SIZE="${2:-}"; shift 2 ;;
    --parallel) PARALLEL="${2:-}"; shift 2 ;;
    --reps) REPS="${2:-}"; shift 2 ;;
    --pod-mem-gib) POD_MEM_GIB="${2:-}"; shift 2 ;;
    --large-files) LARGE_FILES="${2:-}"; shift 2 ;;
    --large-gib) LARGE_GIB="${2:-}"; shift 2 ;;
    --medium-files) MEDIUM_FILES="${2:-}"; shift 2 ;;
    --small-files) SMALL_FILES="${2:-}"; shift 2 ;;
    --image) IMAGE="${2:-}"; shift 2 ;;
    --run-as-root) RUN_AS_ROOT=true; shift ;;
    --timeout-min) TIMEOUT_MIN="${2:-}"; shift 2 ;;
    --out-dir) OUT_DIR="${2:-}"; shift 2 ;;
    --print-runner) printf '%s\n' "$RUNNER"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

die() { echo "tp-bench: $*" >&2; exit 2; }
[ -n "$SRC_SC" ] || die "--source-sc is required (a comma separated list of source classes)"
[ -n "$DST_SC" ] || die "--dest-sc is required"

# ---- the size of the test data -------------------------------------------------
# medium is the reference: about 60 GiB of test data. A number of GiB scales it.
case "$SIZE" in
  small)  D_LF=4; D_LGIB=2;  D_MF=200;  D_SF=100000;  D_POD=1 ;;
  medium) D_LF=4; D_LGIB=10; D_MF=1000; D_SF=1000000; D_POD=2 ;;
  large)  D_LF=4; D_LGIB=50; D_MF=5000; D_SF=5000000; D_POD=4 ;;
  ''|*[!0-9]*) die "--size is small, medium, large or a number of GiB" ;;
  *) D_LF=4; D_LGIB=$(( SIZE * 10 / 60 )); [ "$D_LGIB" -ge 1 ] || D_LGIB=1
     D_MF=$(( SIZE * 1000 / 60 )); D_SF=$(( SIZE * 1000000 / 60 )); D_POD=$(( SIZE / 30 + 1 )) ;;
esac
: "${LARGE_FILES:=$D_LF}" "${LARGE_GIB:=$D_LGIB}" "${MEDIUM_FILES:=$D_MF}" "${SMALL_FILES:=$D_SF}" "${POD_MEM_GIB:=$D_POD}"
for v in LARGE_FILES LARGE_GIB MEDIUM_FILES SMALL_FILES POD_MEM_GIB REPS TIMEOUT_MIN; do
  case "${!v}" in ''|*[!0-9]*|0) die "$v must be a whole number above zero" ;; esac
done
[ "$MEDIUM_FILES" -ge 16 ] && [ "$SMALL_FILES" -ge 16 ] || die "--medium-files and --small-files must be at least 16"
case "$PARALLEL" in ''|*[!0-9,]*) die "--parallel is a comma separated list of numbers" ;; esac
# 1 is always measured: the pessimistic scenario is built on it.
PARALLEL=$(printf '%s\n' 1 ${PARALLEL//,/ } | sort -nu | paste -sd, -)
MAXK=$(printf '%s\n' ${PARALLEL//,/ } | sort -n | tail -n 1)
[ "$MAXK" -le 32 ] || die "--parallel: more than 32 simultaneous copies is not supported"

LARGE_MIB=$(( LARGE_GIB * 1024 ))
# The large data must be at least twice the memory of the copy pod, or the
# cache could hold it and the byte rate would be the speed of memory.
[ $(( LARGE_FILES * LARGE_MIB )) -ge $(( 2 * POD_MEM_GIB * 1024 )) ] \
  || die "the large-file data (${LARGE_FILES} x ${LARGE_GIB} GiB) must be at least twice the memory of the copy pod (${POD_MEM_GIB} GiB): raise --large-gib or lower --pod-mem-gib"

# sizes, in MiB: medium files average 8.5 MiB, small files 4.5 KiB
MED_MIB=$(( MEDIUM_FILES * 17 / 2 ))
SMALL_MIB=$(( SMALL_FILES * 9 / 2048 ))
MIX_MIB=$(( 2 * (LARGE_MIB / 5) + (MEDIUM_FILES / 4) * 17 / 2 + (SMALL_FILES / 4) * 9 / 2048 ))
SRC_MIB=$(( LARGE_FILES * LARGE_MIB + MED_MIB + SMALL_MIB + MIX_MIB ))
UNIT_MAX=$LARGE_MIB
for m in $MED_MIB $SMALL_MIB $MIX_MIB; do [ "$m" -gt "$UNIT_MAX" ] && UNIT_MAX=$m; done
SRC_CLAIM_GIB=$(( (SRC_MIB * 125 / 100 + 1023) / 1024 ))
DST_CLAIM_GIB=$(( (UNIT_MAX * 125 / 100 + 1023) / 1024 ))
DST_PEAK_GIB=$(( (MAXK * LARGE_MIB + 1023) / 1024 ))

IFS=',' read -r -a SRC_LIST <<<"$SRC_SC"

# A guess, said as one: 100 MiB/s per copy for bytes, 1500 files/s per copy for
# files, and no gain beyond two copies. The real time depends on the storage.
ESTIMATE_SECONDS=$(python3 - "$LARGE_FILES" "$LARGE_MIB" "$MED_MIB" "$MEDIUM_FILES" "$SMALL_MIB" "$SMALL_FILES" "$MIX_MIB" "$PARALLEL" "$REPS" "${#SRC_LIST[@]}" <<'PY' 2>/dev/null
import sys
lf, lmib, med, mf, small, sf, mix, par, reps, ncls = sys.argv[1:11]
lf, lmib, med, mf, small, sf, mix, reps, ncls = map(int, (lf, lmib, med, mf, small, sf, mix, reps, ncls))
ks = [int(x) for x in par.split(",")]
B, F = 100.0, 1500.0
fill = (lf * lmib + med + small + mix) / 80.0 + (sf * 1.25) / 1500.0
runs = 0.0
for k in ks:
    gain = k / float(min(k, 2))
    runs += reps * gain * (lmib / B + (small / 16.0) / B + (sf / 16.0) / F)
runs += reps * (med / 16.0) / B
full = 2 * ((med / B + mf / F) + (small / B + sf / F) + (mix / B + (sf / 4.0 + mf / 4.0) / F))
passes = full * 1.6
print(int(ncls * (fill + runs + full + passes) * 1.3))
PY
)
[ -n "$ESTIMATE_SECONDS" ] || ESTIMATE_SECONDS=0
human_secs() { local s=$1; if [ "$s" -ge 3600 ]; then echo "$((s / 3600)) h $(( (s % 3600) / 60 )) min"; else echo "$((s / 60)) min"; fi; }

plan() {
  echo "tp-bench plan. Nothing has been created."
  echo "  namespace:           $NS"
  echo "  source classes:      ${SRC_LIST[*]}"
  echo "  destination class:   $DST_SC"
  echo "  test data (source):  $((SRC_MIB / 1024)) GiB in each source class, in a claim of ${SRC_CLAIM_GIB} GiB"
  echo "                       large: ${LARGE_FILES} x ${LARGE_GIB} GiB   medium: ${MEDIUM_FILES} files of 1-16 MiB"
  echo "                       small: ${SMALL_FILES} files of 1-8 KiB, 4 to 6 directories deep   mixed: a share of the three"
  echo "  destination:         $MAXK claims of ${DST_CLAIM_GIB} GiB; up to ${DST_PEAK_GIB} GiB written at the same time"
  echo "  simultaneous copies: $PARALLEL, each measured $REPS times"
  echo "  copy pod memory:     ${POD_MEM_GIB} GiB (the large data is $((LARGE_FILES * LARGE_GIB * 10 / (POD_MEM_GIB * 10))) times that)"
  echo "  image:               $IMAGE"
  echo "  runs as:             $([ "$RUN_AS_ROOT" = true ] && echo "root (needs a security context constraint)" || echo "a non-root user (restricted)")"
  echo "  copy command:        rsync $RSYNC_FLAGS"
  echo "  time:                about $(human_secs "$ESTIMATE_SECONDS") (a guess from 100 MiB/s and 1500 files/s per copy;"
  echo "                       the real time depends on your storage and can be several times more or less)"
  echo "  at the end:          the namespace $NS is deleted by name"
}
if [ "$BENCH" != true ]; then plan; echo "Add --bench to run it."; exit 0; fi
case "$IMAGE" in *@@*) die "this file carries no image tag; pass --image <image with rsync>" ;; esac

# `oc` is kubectl plus OpenShift's own resources, so prefer it when present.
K=kubectl; command -v oc >/dev/null 2>&1 && K=oc
command -v "$K" >/dev/null 2>&1 || die "no kubectl or oc in PATH"
command -v python3 >/dev/null 2>&1 || die "python3 is needed to write the result files"
$K version >/dev/null 2>&1 || $K get --raw=/version >/dev/null 2>&1 || die "cannot reach the cluster API"

for sc in "${SRC_LIST[@]}" "$DST_SC"; do
  if ! $K get storageclass "$sc" >/dev/null 2>&1; then
    have=$($K get storageclass -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | paste -sd, -)
    die "storage class '$sc' not found. Classes on this cluster: ${have:-none readable}. Use one of them. If the destination class does not exist yet, create the Trident backend and its StorageClass first."
  fi
done

# What the account must be allowed to do. All of it is asked before anything is made.
MISSING=""
need() {   # verb resource [namespace]
  if [ -n "${3:-}" ]; then _a=$($K auth can-i "$1" "$2" -n "$3" 2>/dev/null)
  else _a=$($K auth can-i "$1" "$2" 2>/dev/null); fi
  [ "$_a" = "yes" ] || MISSING="$MISSING
    $1 $2${3:+ in namespace $3}"
}
need create namespaces
need delete namespaces
need create persistentvolumeclaims "$NS"
need create pods "$NS"
need get pods/log "$NS"
need get persistentvolumes
if [ -n "$MISSING" ]; then
  die "the account is not allowed to do all of this:$MISSING
  Ask the cluster administrator for these permissions, or run the script with an administrator account. Nothing was created."
fi

# ---- say what it will cost and ask ---------------------------------------------
echo
plan
echo
echo "This writes about $((SRC_MIB / 1024)) GiB into each source class and up to ${DST_PEAK_GIB} GiB into the destination class."
if [ "$YES" != true ]; then
  if [ -t 0 ]; then
    read -r -p "Continue? [y/N] " _ans
    case "$_ans" in y|Y|yes|YES) : ;; *) echo "Stopped. Nothing was created."; exit 1 ;; esac
  else
    die "this needs a confirmation and there is no terminal. Read the plan above and pass --yes to go on."
  fi
fi

CTX=$($K config current-context 2>/dev/null | tr -d '\n' | tr -c 'a-zA-Z0-9_.-' '-' | sed 's/-\{1,\}$//')
[ -n "$CTX" ] || CTX=cluster
STAMP=$(date +%Y%m%d-%H%M)
mkdir -p "$OUT_DIR" || die "cannot create $OUT_DIR"
OUT_JSON="$OUT_DIR/tp-bench-${CTX}-${STAMP}.json"
OUT_MD="$OUT_DIR/tp-bench-${CTX}-${STAMP}.md"
WORK=$(mktemp -d "${TMPDIR:-.}/tp-bench.XXXXXX") || die "cannot create a work directory"

# ---- the namespace: ours or nobody's ----------------------------------------
if $K get namespace "$NS" >/dev/null 2>&1; then
  mark=$($K get namespace "$NS" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null)
  if [ "$mark" != "tp-bench" ]; then
    rm -rf "$WORK"
    die "namespace $NS already exists and was not made by this script. Nothing was touched. Remove it yourself or ask what it is for."
  fi
  echo "namespace $NS is left over from an earlier run of this script. Deleting it first."
  $K delete namespace "$NS" --wait=true --timeout=300s >/dev/null 2>&1
fi

CREATED=false
LEFT_PVS=""
CLEANED=false
cleanup() {
  trap - EXIT INT TERM
  [ "$CLEANED" = true ] && return
  CLEANED=true
  if [ "$CREATED" = true ]; then
    echo
    echo "cleaning up: deleting namespace $NS"
    # Remember which volumes the claims got, before the claims go.
    PVS=$($K get pvc -n "$NS" -o jsonpath='{range .items[*]}{.spec.volumeName}{"\n"}{end}' 2>/dev/null | sed '/^$/d')
    $K delete namespace "$NS" --wait=true --timeout=600s >/dev/null 2>&1
    if $K get namespace "$NS" >/dev/null 2>&1; then
      echo "   WARNING: namespace $NS is still there. Delete it by hand: $K delete namespace $NS"
    else
      echo "   namespace $NS deleted"
    fi
    for pv in $PVS; do
      if $K get pv "$pv" >/dev/null 2>&1; then
        LEFT_PVS="$LEFT_PVS $pv"
        echo "   WARNING: volume $pv is still there (its class keeps volumes after the claim is gone)."
        echo "            It was left alone on purpose. Ask the array administrator whether its data may go (persistentvolume/$pv)."
      fi
    done
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'echo; echo "interrupted"; exit 130' INT
trap 'echo; echo "terminated"; exit 143' TERM

echo "creating namespace $NS"
$K create namespace "$NS" >/dev/null || { CLEANED=true; rm -rf "$WORK"; die "cannot create namespace $NS (needs permission to create namespaces)"; }
CREATED=true
$K label namespace "$NS" "$OWNER_LABEL" --overwrite >/dev/null 2>&1

_quota=$($K get resourcequota -n "$NS" -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.status.hard}{"\n"}{end}' 2>/dev/null)
if [ -n "$_quota" ]; then
  echo "a quota applies in $NS:"
  echo "$_quota" | sed 's/^/   /'
  echo "   this run needs up to $((MAXK + ${#SRC_LIST[@]})) claims ($((MAXK * DST_CLAIM_GIB + SRC_CLAIM_GIB)) GiB at most) and one pod at a time."
fi

if [ "$RUN_AS_ROOT" = true ]; then
  echo
  echo "Root pods need a security context constraint. An administrator runs:"
  echo "    $K adm policy add-scc-to-user anyuid -z default -n $NS"
  echo "(it is removed with the namespace). Press Enter when it is done."
  read -r _ || die "--run-as-root needs a terminal to wait on"
fi

SEC_BLOCK() {
  if [ "$RUN_AS_ROOT" = true ]; then
    cat <<'SEC'
  securityContext:
    runAsUser: 0
    seccompProfile: {type: RuntimeDefault}
SEC
  else
    cat <<'SEC'
  securityContext:
    runAsNonRoot: true
    seccompProfile: {type: RuntimeDefault}
SEC
  fi
}
CSEC_BLOCK() {
  if [ "$RUN_AS_ROOT" = true ]; then
    echo '      securityContext: {allowPrivilegeEscalation: false, runAsUser: 0, capabilities: {drop: [ALL], add: [CHOWN, DAC_OVERRIDE, FOWNER, FSETID]}}'
  else
    echo '      securityContext: {allowPrivilegeEscalation: false, runAsNonRoot: true, capabilities: {drop: [ALL]}}'
  fi
}

make_pvc() {   # $1 name $2 class $3 GiB
  $K apply -n "$NS" -f - >/dev/null <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $1
  namespace: $NS
  labels: {app.kubernetes.io/managed-by: tp-bench}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: $2
  resources: {requests: {storage: ${3}Gi}}
EOF
}

make_pod() {   # $1 name $2 mode (owner|bench) $3 source claim or "" $4 copies
  _pod=$1; _mode=$2; _srcpvc=$3; _n=$4
  _b64=$(printf '%s\n' "$RUNNER" | base64 -w0)
  _mounts=""; _vols=""
  if [ -n "$_srcpvc" ]; then
    _mounts="$_mounts
        - {name: src, mountPath: /src}"
    _vols="$_vols
    - {name: src, persistentVolumeClaim: {claimName: $_srcpvc}}"
  fi
  _i=1
  while [ "$_i" -le "$_n" ]; do
    _mounts="$_mounts
        - {name: dst$_i, mountPath: /dst$_i}"
    _vols="$_vols
    - {name: dst$_i, persistentVolumeClaim: {claimName: tpb-dst-$_i}}"
    _i=$((_i + 1))
  done
  $K apply -n "$NS" -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $_pod
  namespace: $NS
  labels: {app.kubernetes.io/managed-by: tp-bench}
spec:
  restartPolicy: Never
$(SEC_BLOCK)
  containers:
    - name: bench
      image: $IMAGE
      imagePullPolicy: IfNotPresent
      command: ["bash", "-c", "echo $_b64 | base64 -d | bash"]
      env:
        - {name: TPB_MODE, value: "$_mode"}
        - {name: TPB_LARGE_FILES, value: "$LARGE_FILES"}
        - {name: TPB_LARGE_MIB, value: "$LARGE_MIB"}
        - {name: TPB_MEDIUM_FILES, value: "$MEDIUM_FILES"}
        - {name: TPB_SMALL_FILES, value: "$SMALL_FILES"}
        - {name: TPB_REPS, value: "$REPS"}
        - {name: TPB_PARALLEL, value: "$PARALLEL"}
        - {name: TPB_RSYNC_FLAGS, value: "$RSYNC_FLAGS"}
      resources:
        requests: {cpu: 500m, memory: ${POD_MEM_GIB}Gi}
        limits: {memory: ${POD_MEM_GIB}Gi}
$(CSEC_BLOCK)
      volumeMounts:$_mounts
  volumes:$_vols
EOF
}

# 0 done, 1 failed, 2 timed out, 3 image cannot be pulled
wait_pod() {   # $1 pod $2 seconds
  _p=$1; _limit=$2; _t0=$SECONDS; _last=""; _hinted=false
  while :; do
    _ph=$($K get pod "$_p" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
    case "$_ph" in Succeeded) return 0 ;; Failed) return 1 ;; esac
    [ $((SECONDS - _t0)) -ge "$_limit" ] && return 2
    if [ "$_ph" = "Pending" ] && [ $((SECONDS - _t0)) -ge "${TP_BENCH_PULL_WAIT:-45}" ]; then
      _why=$($K get pod "$_p" -n "$NS" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null)
      case "$_why" in
        ErrImagePull|ImagePullBackOff|InvalidImageName)
          echo "   the image cannot be pulled: $IMAGE ($_why)"
          echo "   If this cluster has no route to the registry, copy the image to your own registry and pass it:"
          echo "   --image <your-registry>/<path>/trident-port:<tag> (with tp-pre.sh: --bench-image). It needs rsync, bash and python3."
          return 3 ;;
      esac
    fi
    if [ "$_ph" = "Pending" ] && [ "$_hinted" = false ] && [ $((SECONDS - _t0)) -ge 120 ]; then
      _hinted=true
      echo "   pod $_p is still Pending after 2 minutes. Events:"
      $K get events -n "$NS" --field-selector "involvedObject.name=$_p" -o custom-columns=REASON:.reason,MESSAGE:.message --no-headers 2>/dev/null | tail -n 5 | sed 's/^/     /'
    fi
    _prog=$($K logs "$_p" -n "$NS" --tail=1 2>/dev/null | grep '^TPB_PROGRESS' | tail -n 1)
    [ -n "$_prog" ] && [ "$_prog" != "$_last" ] && { echo "   $_prog"; _last=$_prog; }
    sleep "$POLL"
  done
}

echo "image: $IMAGE"
echo "creating $MAXK destination claim(s) of ${DST_CLAIM_GIB} GiB on $DST_SC"
i=1; while [ "$i" -le "$MAXK" ]; do make_pvc "tpb-dst-$i" "$DST_SC" "$DST_CLAIM_GIB" || die "cannot create a claim in $NS"; i=$((i + 1)); done

echo "owner test on the destination"
make_pod tpb-owner owner "" 1 || die "cannot create a pod in $NS"
wait_pod tpb-owner 900; owner_rc=$?
$K logs tpb-owner -n "$NS" > "$WORK/owner.log" 2>&1
[ "$owner_rc" -ne 3 ] || die "stopped: the image cannot be pulled. Nothing was measured."
[ "$owner_rc" -eq 0 ] || echo "   the owner test pod did not finish ($owner_rc); see the result file"

idx=1
for sc in "${SRC_LIST[@]}"; do
  echo
  echo "source class $sc ($idx of ${#SRC_LIST[@]})"
  make_pvc "tpb-src-$idx" "$sc" "$SRC_CLAIM_GIB" || die "cannot create a claim in $NS"
  make_pod "tpb-run-$idx" bench "tpb-src-$idx" "$MAXK" || die "cannot create a pod in $NS"
  wait_pod "tpb-run-$idx" $((TIMEOUT_MIN * 60)); rc=$?
  $K logs "tpb-run-$idx" -n "$NS" > "$WORK/run-$idx.log" 2>&1
  echo "$sc" > "$WORK/run-$idx.class"
  case "$rc" in
    0) echo "   finished" ;;
    1) echo "   the pod FAILED. Its log is kept in the result file." ;;
    2) echo "   timed out after $TIMEOUT_MIN minutes. What it measured so far is kept." ;;
    3) echo "   the image cannot be pulled. Nothing was measured for this class." ;;
  esac
  $K delete pod "tpb-run-$idx" -n "$NS" --wait=false >/dev/null 2>&1
  $K delete pvc "tpb-src-$idx" -n "$NS" --wait=false >/dev/null 2>&1
  idx=$((idx + 1))
done

# ---- the result files ---------------------------------------------------------
TPB_WORK="$WORK" TPB_OUT_JSON="$OUT_JSON" TPB_OUT_MD="$OUT_MD" TPB_CTX="$CTX" TPB_IMAGE="$IMAGE" \
TPB_DST_SC="$DST_SC" TPB_PARALLEL="$PARALLEL" TPB_RSYNC="$RSYNC_FLAGS" TPB_REPS="$REPS" TPB_SIZE="$SIZE" \
TPB_LARGE_FILES="$LARGE_FILES" TPB_LARGE_MIB="$LARGE_MIB" TPB_MEDIUM_FILES="$MEDIUM_FILES" \
TPB_SMALL_FILES="$SMALL_FILES" TPB_ROOT="$RUN_AS_ROOT" TPB_SRC_GIB="$SRC_CLAIM_GIB" TPB_DST_GIB="$DST_CLAIM_GIB" \
TPB_POD_MEM_GIB="$POD_MEM_GIB" TPB_ESTIMATE="$ESTIMATE_SECONDS" python3 - <<'PY'
import datetime, glob, json, math, os

W = os.environ["TPB_WORK"]


def events(path):
    out = []
    try:
        for line in open(path, encoding="utf-8", errors="replace"):
            if line.startswith("TPB {"):
                try:
                    out.append(json.loads(line[4:]))
                except ValueError:
                    pass
    except OSError:
        pass
    return out


def tail(path, n=15):
    try:
        return open(path, encoding="utf-8", errors="replace").read().strip().splitlines()[-n:]
    except OSError:
        return []


classes = []
pod = {}
errors = []
for log in sorted(glob.glob(os.path.join(W, "run-*.log"))):
    ev = events(log)
    klass = open(log[:-4] + ".class").read().strip()
    fills = {e["profile"]: e for e in ev if e.get("event") == "fill"}
    runs = [e for e in ev if e.get("event") == "run"]
    pod = pod or next((e for e in ev if e.get("event") == "pod"), {})
    errors += [(klass, e.get("why")) for e in ev if e.get("event") == "error"]
    classes.append({"source_class": klass, "fill": fills, "runs": runs,
                    "finished": any(l.strip() == "TPB_DONE" for l in tail(log, 3)),
                    "log_tail": [] if runs else tail(log)})

large_bytes = int(os.environ["TPB_LARGE_FILES"]) * int(os.environ["TPB_LARGE_MIB"]) * 1048576
ram = pod.get("ram_limit_bytes") or 0
basis = "pod memory limit"
if not ram:
    ram = pod.get("host_ram_bytes") or 0
    basis = "node memory (the pod had no limit)"
ratio = (large_bytes / float(ram)) if ram else 0.0
pod["cache_check"] = {"large_bytes": large_bytes, "ram_bytes": ram, "ram_basis": basis,
                      "ratio": round(ratio, 2), "ok": bool(ram) and ratio >= 2.0}

owner = [e for e in events(os.path.join(W, "owner.log")) if e.get("event") == "owner"]
doc = {
    "schema": "tp-bench/2",
    "generated": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "context": os.environ["TPB_CTX"],
    "image": os.environ["TPB_IMAGE"],
    "dest_class": os.environ["TPB_DST_SC"],
    "size": os.environ["TPB_SIZE"],
    "repetitions": int(os.environ["TPB_REPS"]),
    "parallel": [int(x) for x in os.environ["TPB_PARALLEL"].split(",")],
    "rsync": "rsync " + os.environ["TPB_RSYNC"],
    "claims_gib": {"source": int(os.environ["TPB_SRC_GIB"]), "destination": int(os.environ["TPB_DST_GIB"])},
    "profiles": {
        "large": {"files": int(os.environ["TPB_LARGE_FILES"]), "file_mib": int(os.environ["TPB_LARGE_MIB"])},
        "medium": {"files": int(os.environ["TPB_MEDIUM_FILES"]), "file_mib": "1-16"},
        "small": {"files": int(os.environ["TPB_SMALL_FILES"]), "file_kib": "1-8", "tree_depth": "4-6"},
        "mixed": "a quarter of the medium and small files and two large files of a fifth of the large size",
    },
    "estimated_seconds_before_the_run": int(os.environ["TPB_ESTIMATE"]),
    "run_as_root": os.environ["TPB_ROOT"] == "true",
    "pod": pod,
    "owner_test": owner or [{"tested": False, "why": "no output from the owner pod: " + " | ".join(tail(os.path.join(W, "owner.log"), 3))}],
    "classes": classes,
    "errors": errors,
    "limits": [
        "All simultaneous copies run inside one pod on one node, each to its own destination claim. "
        "Copies spread over several nodes may add up to more.",
        "Each simultaneous copy reads a different slice of the source, so they do not share cached data.",
        "One destination class was measured. A second destination class needs its own run.",
        "The node CPU is read from the node's own counters inside the pod. The network and the array are not "
        "read, so a limit that is neither CPU nor memory cannot be told apart.",
    ],
}
json.dump(doc, open(os.environ["TPB_OUT_JSON"], "w"), indent=1)


def stats(values):
    m = sum(values) / len(values)
    sd = math.sqrt(sum((x - m) ** 2 for x in values) / (len(values) - 1)) if len(values) > 1 else None
    return m, (100.0 * sd / m if sd is not None and m else None)


md = ["# tp-bench: what was measured", "",
      "Cluster context `%s`, destination class `%s`, generated %s." % (doc["context"], doc["dest_class"], doc["generated"]),
      "Copy command: `%s`." % doc["rsync"],
      "The tables of times are made by tp-estimate from this file.", "",
      "| source class | profile | copies | repetitions | MiB/s per copy | files/s per copy | spread | state |",
      "|---|---|---|---|---|---|---|---|"]
for c in classes:
    keys = sorted({(r["profile"], r["pass"], r["k"]) for r in c["runs"] if r["pass"] in ("unit", "full")})
    for profile, kind, k in keys:
        mib, fil = [], []
        for r in c["runs"]:
            if (r["profile"], r["pass"], r["k"]) != (profile, kind, k) or not r["copies"]:
                continue
            if any(x["rc"] != 0 or x["ms"] <= 0 for x in r["copies"]):
                continue
            secs = sum(x["ms"] for x in r["copies"]) / len(r["copies"]) / 1000.0
            mib.append(r["copies"][0]["bytes"] / 1048576.0 / secs)
            fil.append(r["copies"][0]["files"] / secs)
        if not mib:
            md.append("| %s | %s | %d | 0 | unknown | unknown | n/a | no copy finished cleanly |" % (c["source_class"], profile, k))
            continue
        m, cv = stats(mib)
        state = "ok" if cv is None or cv <= 15 else "HIGH DISPERSION"
        md.append("| %s | %s%s | %d | %d | %.1f | %.0f | %s | %s |" % (
            c["source_class"], profile, " (whole tree)" if kind == "full" else "", k, len(mib), m, sum(fil) / len(fil),
            "n/a" if cv is None else "%d percent" % round(cv), state))
md += ["", "## Owner test on the destination", ""] + ["- `%s`" % json.dumps(o, sort_keys=True) for o in doc["owner_test"]]
cc = pod["cache_check"]
md += ["", "## Conditions", "",
       "- large-file data is %.1f times the %s (%s)" % (cc["ratio"], cc["ram_basis"], "enough to stay out of the cache" if cc["ok"] else "BELOW the 2 times needed"),
       ""]
md += ["## Limits of this measurement", ""] + ["- " + l for l in doc["limits"]]
open(os.environ["TPB_OUT_MD"], "w").write("\n".join(md) + "\n")
PY
py_rc=$?

echo
echo "result files:"
echo "  $OUT_JSON"
echo "  $OUT_MD"
[ "$py_rc" -eq 0 ] || echo "  WARNING: the result files could not be written (exit $py_rc)"
# The EXIT trap deletes the namespace.
exit "$py_rc"
