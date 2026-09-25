# Run data

The `buildinfo/` files that `build.sh` publishes with each run, copied
unchanged. One directory per run on wir-horst (see the report, section 5).
File names start with the run id `<start epoch>-<pid>`. Some names and
columns are German, because `build.sh` is.

| Directory | Run | Note |
|---|---|---|
| `run3-26091115bro` | 3 | 4 domains × 8 targets, 6 workers |
| `run4-26091118bro` | 4 | 5 × 8, 6 workers, first run with split `-j`, LPT order, PSI |
| `run5-26091123bro` | 5 | 9 × 9, 6 workers. Resumed: `1789161357-…` is the attempt killed by a network outage (collector samples only), `1789167052-…` the resume |
| `run6-26091206bro` | 6 | 9 × 9, 6 workers, same configuration as run 5 (repetition) |
| `run7-26091213bro` | 7 | 48 × 9, 9 workers (one wave), golden tree reused: no prepare, no golden steps |
| `run8-26091720bro` | 8 | 8 × 7, 7 workers (10 configured, one wave) |
| `run9-26091802bro` | 9 | 8 × 8, 6 workers, two waves |
| `release-26091920sta` | release | 86 × 20, 8 workers (three waves). Not part of the measurement series. `1789843017-…` is the first attempt (prepare and 14 of 20 golden steps, collector samples only), `1789913332-…` a second attempt that ended in prepare, `1789913904-…` the final attempt |

## `*.build-times.csv`

One line per event: `run_start`, `prepare`, `build` (one domain × target
step), `finalize` (one domain).

| Column | Meaning |
|---|---|
| `epoch` | end of the event, Unix time |
| `seconds` | duration; start = `epoch − seconds` |
| `build_order` | `parallel` for worker runs |
| `template`, `site_code` | site variant (`-key` = with SSH keys) and domain |
| `target` | OpenWrt target |

## `*.metrics.csv.gz`

Collector samples, one per second, whole host.

| Column | Meaning |
|---|---|
| `aktiv` | busy cores: (1 − idle share) × cores, from `/proc/stat`; includes iowait and steal |
| `iowait` | cores in iowait |
| `util` | disk %util of the build volume |
| `schreib_mb` | write rate, MB/s |
| `iops` | I/O operations per second |
| `prepare`, `golden`, `build`, `finalize` | number of `build.sh` processes (main process and workers) reporting that phase |
| `steal` | steal time, in cores |
| `running`, `blocked` | runnable and blocked processes (`/proc/stat`) |
| `psi_cpu`, `psi_io`, `psi_io_full`, `psi_mem` | share of the sample interval with stalls, % (`/proc/pressure/*`, `some` unless `_full`) |

## `*.empfehlung.txt`

The collector's recommendation for the next run (`empfohlen` = recommended
workers), read by `WORKERS=auto`. `*_alle_belegt` values are from samples
with all workers busy. `worker_erlang` is the mean number of busy workers in
the parallel phase.

## `*.summary.txt`

The summary box printed at the end of the run: duration, scope, Erlang,
image count and output size.
