# omarchy-sysmon

CPU and memory in the [Omarchy](https://omarchy.org/) bar, with per-core load,
stall pressure, package temperature and the processes actually responsible in
the panel.

## Why

Omarchy ships no resource widget. `omarchy-system-stats` exists on `PATH` and
even has a `--bar-widget` mode, but nothing consumes it: the power panel
collects its output every five seconds while open and never renders it.

This is that widget, and it tries to answer the question you actually opened it
for rather than printing a percentage:

**Per-core bars.** One runaway thread on a 16-core machine is 6% aggregate --
invisible in a single figure, obvious the moment the cores are drawn
separately, and usually the real answer to "why is this slow".

**Pressure, not just usage.** PSI reports the share of wall-clock time that
something spent *waiting* on a resource. Memory at 90% with no pressure is a
healthy machine with a warm page cache; memory at 70% with pressure climbing is
a machine about to thrash. The panel stays silent until there is something to
say:

```
Waiting for a core 0.3% of the last 10s
Blocked on disk 0.7% of the last 10s
```

**Honest process CPU.** `ps` reports `%CPU` averaged over a process's entire
lifetime, so a browser that pegged a core an hour ago outranks the compiler
running now. This samples `/proc/<pid>/stat` twice and subtracts, like `top`
does. A process seen only once shows `—` rather than its lifetime average.

**Cache is not "used".** The bar measures memory against `MemAvailable`, the
kernel's own estimate of what a new allocation could get without swapping --
which is why this reads 25% where `free -h` looks 90% full.

## Install

```bash
omarchy plugin add https://github.com/dbarke/omarchy-sysmon.git --enable
```

Or clone it into place yourself:

```bash
git clone https://github.com/dbarke/omarchy-sysmon.git \
  ~/.config/omarchy/plugins/dbarke.sysmon
omarchy plugin enable dbarke.sysmon --section right
```

## Use

| Action | Result |
|---|---|
| Click | Open the panel |
| Middle-click | Launch the full monitor (`btop`) |
| Right-click | Re-sample now |
| Hover | Everything the two figures compress, as text |
| `c` / `m` | Sort processes by CPU or by memory |
| `b` | Full monitor |
| `r` | Re-sample |
| `↑` `↓` | Scroll |

The bar carries CPU and memory percentages and a short CPU sparkline, so a
spike that already passed is still visible. Colours are mixed from the active
theme rather than hardcoded -- there is no amber in an Omarchy palette to reach
for -- and shift from foreground toward urgent as a reading climbs.

## Settings

| Setting | Default | What it does |
|---|---|---|
| Refresh interval | `2`s | Also the window each percentage averages over. Longer is calmer, shorter catches spikes. The panel always samples at 1s while open. |
| Bar reading | `both` | `both`, `cpu`, or `memory`. The panel shows everything regardless. |
| Show CPU sparkline | on | A short history strip beside the number. |
| CPU warning threshold | `85`% | At or above this the reading turns urgent. `0` disables. |
| Memory warning threshold | `85`% | Measured against genuinely unavailable memory, not page cache. |
| Show per-core bars | on | One bar per logical CPU. |
| Processes to list | `5` | `0` hides the table *and* stops the panel walking `/proc` for it. |
| Sort processes by | `cpu` | Starting sort. `c` and `m` switch it live. |
| Full monitor command | `omarchy-launch-or-focus-tui btop` | Launched by `b` and by middle-click. |

## Implementation note

`poll.sh` emits raw counters, never percentages, and the arithmetic happens in
QML where the previous sample lives. This is deliberate: `/proc` hands out
totals since boot, and a total since boot is a constant that says nothing about
now. A counter that goes backwards -- suspend/resume, a CPU coming online --
drops the delta rather than drawing a spike that never happened.

The whole brief sample is two `awk` invocations and a handful of bash builtin
reads: no `ps`, no `top`, no fork per process. It costs about 4ms. The full
sample walks `/proc/<pid>/stat` for the process table and costs about 30ms, so
it only runs while the panel is actually open.

Processes die between the glob expanding and `awk` opening the files, so `awk`
exits 2 on almost every full sample. That is the normal case on a machine with
500 processes, not a failure, and the script exits 0 regardless; the reader
simply sees a table missing the handful that exited during the sample.

## Requirements

- Omarchy 4.x (`omarchy-shell` / Quickshell)
- A kernel with `CONFIG_PSI` for the pressure lines (Arch ships it; without it
  those lines stay hidden)
- A Nerd Font for the bar glyphs

## License

MIT — see [LICENSE](LICENSE).
