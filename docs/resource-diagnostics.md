# Capturing session resource usage

On Linux, the collector records CPU, memory, thread count, and open file descriptor
count for a helper process and its descendants. It uses Python 3's standard library
and `/proc`; it works with existing sessions without updating or restarting them.

First find the host PID for the session you want to observe:

```bash
ps -C host -o pid,ppid,args
```

Use the PID of the outer host launched with the session's `.ctl` socket path
and `--headless` to include the helper tree and its applications. Its command
also includes the inner host's `.wsm` path. You can also select an
individual helper to observe just that subtree. From the repository checkout:

```bash
python3 scripts/diagnose_resources.py --pid 12345 \
  --duration 3600 --interval 5 --output resource-capture.jsonl
```

Replace `12345` with the selected PID. The file must not already exist. Omit
`--output` to write JSONL to stdout. The default capture lasts 60 seconds with
one sample per second. Ctrl-C stops a capture, preserving completed records.

Each sample includes elapsed time and a list of processes, identified by PID and
start ticks. CPU is an interval percentage: 100% means one fully occupied core,
with higher values possible for multiple threads. The first observation of a
process has `null` CPU because there is no previous sample. RSS is in KiB; shared
pages are counted in each process, so summing RSS does not give unique physical
memory. Executable basenames help distinguish helpers from their applications.

Compare individual helpers over repeated, similar workload cycles. RSS that
settles at a higher level can reflect reusable allocator storage; continued
growth, growing descriptor counts, or CPU use during an idle period warrants
investigation. This collector reports measurements, not automatic leak verdicts.

The collector does not connect to session sockets or read terminal contents,
command arguments, or environment variables. Run it as the session's user to
read process metadata. Processes that exit or become unreadable while sampling
can have partial records. Observed descendants remain tracked if their parent
exits; children that start and exit between samples can be missed. PID reuse is
checked using process start ticks. Capture ends when the tracked tree disappears
or the duration expires; zombies remain visible until reaped.

Captures are limited to 24 hours, 512 tracked processes, and 20 MiB of output.
Intervals must be between 0.25 and 60 seconds. Hitting a process or output limit
returns an error and preserves the records already written. Longer intervals
reduce overhead and output size. Each sample scans the system's process table,
so the collector itself has a cost on machines with many processes.

This is an opt-in diagnostic tool, separate from CI's `test-c-leaks` ownership
checks. It does not add background monitoring to WSM.

## Repeated-workload regression

CI also keeps one optimized `ptylog` process alive through 32 batches of 4,000
lines, alternating plain scrolling text and unique hyperlinks. Each batch waits
for its completion marker to reach the log before sampling the helper's RSS.
The fixture rotates logs with a 256 KiB budget and discards terminal output;
the Python producer's memory is not included in the helper's measurements.

After four warm-up batches, RSS must remain within 12 MiB of the baseline. Once
output stops, CPU must stay below 5% of one core over a 1.5-second sample. These
are deliberately generous regression limits for this workload, not guarantees
about every application or proof that smaller leaks are absent. CI preserves
JSONL measurements as the `ptylog-resources` artifact, including on failure.

Run the same check locally on Linux (Python 3.9+ and kernel 5.3+):

```bash
zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSafe
python3 ptylog/test_resources.py zig-out/bin/ptylog
```

For a longer manual run, repeat batches in the same process for an hour:

```bash
python3 ptylog/test_resources.py zig-out/bin/ptylog \
  --soak-seconds 3600 > ptylog-soak.jsonl
```

The soak option accepts up to 24 hours and always runs at least 32 batches.
Each batch has a 30-second progress timeout. The fixture uses a temporary
directory and cleans up its helper and child on success or failure. This check
covers logger scrolling, hyperlink churn, and idle CPU after output; it does not
exercise the full attached WSM session tree or stalled output readers.

## Scheduled soak

The `resource-soak` GitHub Actions workflow runs this same fixture for three
hours, scheduled daily at 03:23 UTC on the default branch. GitHub may delay
scheduled runs. It uses ReleaseSafe binaries and the same RSS and idle-CPU
thresholds as the short CI check; normal pull-request checks remain short.

To start an additional run, open **Actions → resource-soak → Run workflow** and
select the branch to test. Runs for the same branch do not execute concurrently,
and starting another run does not cancel an active soak.

Download the `ptylog-soak` artifact from the workflow run for per-batch RSS,
elapsed time, and the final idle-CPU measurement and result. Measurements are
uploaded on success or failure and retained for 14 days. A failed or interrupted
run may only contain partial measurements; a successful result record confirms
completion. The soak step has a 190-minute timeout inside a 210-minute job limit
to leave time for building and uploading results. A cancelled job or runner
failure can prevent artifact upload.
