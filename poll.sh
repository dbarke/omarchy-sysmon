#!/bin/bash
#
# One sample of this machine, as tab-separated lines on stdout.
#
# Everything here is a /proc or /sys read: no ps, no top, no forks per
# process. The whole brief sample is two awk invocations and a handful of
# builtin reads, which is what makes a two-second poll interval reasonable.
#
# Counters are emitted raw rather than as percentages. A CPU percentage only
# exists between two samples, and the difference between "since boot" and
# "since two seconds ago" is the difference between a number that never moves
# and a number that means something. The caller keeps the previous sample and
# does the subtraction.
#
# Usage: poll.sh [full]
#   full  also walks /proc/<pid>/stat for the per-process table

set -o pipefail
shopt -s nullglob

mode=${1:-brief}

# ---------------------------------------------------------------- cpu, tasks
# /proc/stat cpu line: user nice system idle iowait irq softirq steal guest
# guest_nice. guest and guest_nice are already counted inside user and nice,
# so the total stops at steal -- including them would inflate the denominator
# and quietly understate every percentage on a machine running VMs.
awk '
  $1 == "cpu" || $1 ~ /^cpu[0-9]+$/ {
    total = 0
    for (i = 2; i <= 9; i++) total += $i
    idle = $5 + $6
    if ($1 == "cpu") printf "cpu\t%d\t%d\n", idle, total
    else printf "core\t%s\t%d\t%d\n", substr($1, 4), idle, total
  }
  $1 == "procs_running" { printf "running\t%s\n", $2 }
  $1 == "procs_blocked" { printf "blocked\t%s\n", $2 }
' /proc/stat

# --------------------------------------------------------------------- memory
# MemAvailable is the kernel's own estimate of what a new allocation could
# get without swapping. It is the only honest "free" number: MemFree ignores
# reclaimable page cache, which is why a healthy Linux box looks 90% full.
awk '
  $1 == "MemTotal:"     { t  = $2 }
  $1 == "MemAvailable:" { a  = $2 }
  $1 == "MemFree:"      { f  = $2 }
  $1 == "Cached:"       { c  = $2 }
  $1 == "Buffers:"      { b  = $2 }
  $1 == "SReclaimable:" { sr = $2 }
  $1 == "Shmem:"        { sh = $2 }
  $1 == "SwapTotal:"    { st = $2 }
  $1 == "SwapFree:"     { sf = $2 }
  END {
    # Cached already includes Shmem, and Shmem is anonymous-ish memory that
    # does not go away under pressure, so it belongs with used, not cache.
    printf "mem\t%d\t%d\t%d\t%d\t%d\n", t, a, f, c + b + sr - sh, sh
    printf "swap\t%d\t%d\n", st, sf
  }
' /proc/meminfo

# ------------------------------------------------------------- load, uptime
read -r l1 l5 l15 procs _ < /proc/loadavg
printf 'load\t%s\t%s\t%s\t%s\n' "$l1" "$l5" "$l15" "${procs#*/}"
read -r up _ < /proc/uptime
printf 'uptime\t%s\n' "$up"

# -------------------------------------------------------------------- stalls
# Pressure stall information answers the question a percentage cannot: not
# "how much is in use" but "is anything actually waiting". Memory at 90% with
# zero memory pressure is fine; memory at 70% with rising pressure is not.
for res in cpu memory io; do
  [ -r "/proc/pressure/$res" ] || continue
  while read -r kind rest; do
    [ "$kind" = some ] || [ "$kind" = full ] || continue
    avg10=${rest%% *}
    printf 'psi\t%s\t%s\t%s\n' "$res" "$kind" "${avg10#avg10=}"
  done < "/proc/pressure/$res"
done

# --------------------------------------------------------------------- therm
# Prefer the CPU package sensor by label. acpitz and the thermal_zone fallback
# measure somewhere on the board rather than the die, so they read cool and
# lag; they are a last resort, not a first choice.
temp_input=""
for dir in /sys/class/hwmon/hwmon*; do
  [ -r "$dir/name" ] || continue
  read -r hwname < "$dir/name"
  case $hwname in
    coretemp | k10temp | zenpower)
      for label in "$dir"/temp*_label; do
        read -r text < "$label"
        case $text in
          "Package id "* | Tctl | Tdie) temp_input="${label%_label}_input"; break ;;
        esac
      done
      [ -n "$temp_input" ] || temp_input="$dir/temp1_input"
      ;;
  esac
  [ -n "$temp_input" ] && break
done
if [ -z "$temp_input" ]; then
  for dir in /sys/class/thermal/thermal_zone*; do
    [ -r "$dir/type" ] || continue
    read -r zonetype < "$dir/type"
    case $zonetype in
      x86_pkg_temp | acpitz) temp_input="$dir/temp"; break ;;
    esac
  done
fi
if [ -n "$temp_input" ] && [ -r "$temp_input" ]; then
  read -r millidegrees < "$temp_input"
  printf 'temp\t%s\n' "$millidegrees"
fi

[ "$mode" = full ] || exit 0

# --------------------------------------------------------------- constants
# Emitted before the process table, because the reader scales rss by the
# page size as it parses each row rather than in a second pass.
printf 'pagesize\t%d\n' "$(getconf PAGE_SIZE)"
printf 'hz\t%d\n' "$(getconf CLK_TCK)"

# ----------------------------------------------------------------- cpu model
awk -F': ' '
  /^model name/ { print "model\t" $2; exit }
' /proc/cpuinfo

# Current clock, averaged over the online CPUs. On a big.LITTLE or boosting
# chip this moves constantly, which is exactly why it is worth showing next
# to a utilisation figure that a governor can flatten.
awk '
  /^cpu MHz/ { sum += $4; n++ }
  END { if (n > 0) printf "mhz\t%.0f\n", sum / n }
' /proc/cpuinfo

# ------------------------------------------------------------------ processes
# comm is field 2 of /proc/<pid>/stat wrapped in parentheses, and it may
# contain both spaces and ")" -- "(Web Content)" and "(foo) bar)" are legal.
# Splitting on whitespace gets those wrong, so the parse works from the LAST
# ")" in the line and treats everything after it as the remaining fields.
#
# utime+stime are emitted as raw jiffies for the same reason the cpu counters
# are: ps's %CPU is an average over the process's entire lifetime, so a
# browser that pegged a core an hour ago outranks the compiler running now.
awk '
  {
    close_paren = 0
    for (i = length($0); i > 0; i--)
      if (substr($0, i, 1) == ")") { close_paren = i; break }
    open_paren = index($0, "(")
    if (close_paren == 0 || open_paren == 0) next

    pid  = substr($0, 1, open_paren - 2)
    comm = substr($0, open_paren + 1, close_paren - open_paren - 1)
    n    = split(substr($0, close_paren + 2), f, " ")
    if (n < 22) next

    # f[k] is stat field k+2: utime=14, stime=15, num_threads=20, rss=24.
    gsub(/\t/, " ", comm)
    printf "proc\t%s\t%d\t%d\t%d\t%s\n", pid, f[12] + f[13], f[22], f[18], comm
  }
' /proc/[0-9]*/stat 2>/dev/null

# Processes die between the glob expanding and awk opening the files, and awk
# exits 2 when any input could not be opened. On a machine with 500 processes
# that is the normal case, not a failure: the sample is simply missing the
# handful that exited during it, which the reader already tolerates. Their
# stderr is dropped above for the same reason -- it would be constant.
exit 0
