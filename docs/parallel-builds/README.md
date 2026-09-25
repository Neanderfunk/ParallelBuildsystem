# Building many Gluon firmware variants on one host

**A measurement report on where the time goes, and on a rootless overlayfs
worker pool that parallelises the build**

Freifunk im Neanderland (Neanderfunk) firmware, branch `v2023.2.x`,
September 2026.

> **About this report.** The measurements come from `build.sh` in this
> repository and its load collector, on runs that the maintainer (adorfer)
> started on the community's build host. The analysis and the text were
> written by Claude (Anthropic, model Claude Opus 5). Claude also wrote most
> of the parallel build mode described here, over several working sessions
> with the maintainer. The numbers for runs 3 onwards can be checked against
> the raw data in [`data/`](data/) with [`analyse.py`](analyse.py). Earlier
> measurements (sections 2–4, runs 1–2) predate the published run data and
> are documented in the German operator documentation. Where a statement is
> an explanation rather than a measurement, the text says so.
>
> The German operator documentation with every option and file is
> [`../build-sh.md`](../build-sh.md). This report is the condensed and
> transferable part.
>
> **Updated 25 September 2026** (Claude Opus 5.5): runs 8 and 9 added to
> section 5, and the production run of release 2023.2.6 (86 variants × 20
> targets) as a data point outside the measurement series. Scheduling
> details that were implemented but not described are added in section 4.
> Sections 9 and 10 are brought up to date.

---

## Summary

A Freifunk community builds its Gluon firmware once per *site variant*:
one mesh domain, with or without pre-installed SSH keys. Neanderfunk has
86 such variants for 22 OpenWrt targets. Built serially, that takes about
**138 hours** (extrapolated from the measured costs in section 2, not run),
so a security update waits almost a week for its images. In parallel mode,
the 2023.2.6 release (86 variants, by then 20 targets) took about 40 hours
of build time from scratch, 36.5 of them in its final attempt (section 5).

What we found:

1. **The cost is per image, not per configuration.** Switching the site
   configuration recompiles no package. A variant costs ~94 min, almost all of
   it assembling ~448 images at ~12.6 s each.
2. **A serial build leaves the machine idle.** After the first domain, the
   build keeps a median of 1.3 of 36 cores busy (8 % utilisation). It is not
   I/O bound (iowait ≈ 0). More cores would not help at all.
3. **A read-only "golden tree" plus one kernel overlayfs per worker.** The
   170-min base cost is paid only when the inputs change, not every run.
   Each worker starts from the golden tree with a mount that takes no
   measurable time, and the overlay costs no measurable build time. It works
   **rootless**, via two user namespaces.
4. **Parallelise along the target axis, not the domain axis.** A worker that
   builds one target for all domains needs ~11 GB of overlay; one that builds
   one domain for all targets would need ~62 GB.
5. **With W workers, the speed-up is not W.** With 6 workers, follow-up
   domains became 2.7–2.8× faster, not 6×. Each step takes ~1.7× longer
   under load, and ~1.85× with 9 workers: a step alone takes 0.54 of its
   full-load time (run 7). Run-queue contention is ruled out by
   pressure-stall data. Clock speed under thermal limits and I/O remain;
   neither is proven.
6. **The worker count is set by waves, not by load.** With one worker per
   target, T targets on W workers run in ⌈T/W⌉ waves. The last wave runs with
   few workers, and the parallel phase can never be shorter than the longest
   single target. A "utilisation is low, add one worker" rule gave the wrong
   answer. With 9 workers for 9 targets (one wave), a run of 48 domains
   built 36 % more steps per hour than with 6; its end is a tail in which the
   longest target runs alone.
7. **Several standard measurements misled us** (section 7): a load threshold
   as phase detector, a synchronous disk benchmark, and averages that hide
   bursts.

---

## 1. Setting

[Gluon](https://github.com/freifunk-gluon/gluon) is the firmware framework
used by most German Freifunk communities. It is a layer on top of OpenWrt
(Gluon v2023.2 ≙ OpenWrt 23.05). One build produces, for one *site
configuration*, images for every supported device of one OpenWrt *target*
(e.g. `ath79-generic`, `ramips-mt7621`, `x86-64`).

A community with several mesh domains needs one site configuration per
domain. Neanderfunk has 43 domains, each in two flavours (with and without
the community's SSH keys), so **86 site variants**. At the time of the
measurements the full stable set was 86 variants × 22 targets. Per variant
there were 448 image files (306 sysupgrade, 124 factory, 18 other). The
2023.2.6 release was built for 20 targets.

`build.sh` (this repository) drives Gluon's `make` for all combinations,
signs the manifests and publishes the result. It can resume an interrupted
run, and since September 2026 it can build several targets at the same time
(`WORKERS`).

**Build host "wir-horst":** Intel Xeon E5-2698 v4. It is a KVM guest on a
dual-socket Proxmox host, with 2 × 18 vCPU (NUMA exposed) and 118 GB RAM.
The disk is virtio-scsi-single with an iothread, on a ZFS mirror of two
Samsung PM983 NVMe drives, with ext4 in the guest. Some local comparisons
were made on a Ryzen 9 5950X (32 threads) under WSL2.

---

## 2. Where the time goes (serial build)

| Item | Time |
|---|---|
| Base cost per run: `make update`, `make clean` for all targets, compiling all packages | ~170 min |
| First domain in total | 264 min |
| **Every further domain** | **93–95 min** |
| Images per domain | 448 |
| Per image | ~12.6 s |

Serial run time is therefore about **170 + D × 94 min**. For 86 variants
that is ~138 h (5.7 days).

**A domain switch compiles no package.** In Gluon, only
`package/gluon-site` depends on the site directory (`PKG_FILE_DEPENDS`).
Measured on `ramips-mt7621`, the second domain spends:

| Part | Time |
|---|---|
| `target/linux/install` (the images, real work) | 37.6 s |
| `target/linux/compile` (kernel re-check, nothing changed) | 21.4 s |
| `package/kernel/linux/compile` | 4.3 s |
| all other packages together | ~5 s |

Consequences:

- `make clean` runs once per run, not per domain. The suspicion "too many
  cleans" was wrong.
- Multi-domain images, i.e. one image containing all domain configurations,
  only save time if they reduce the **number of images**. N multi-domain
  images that differ only in their default domain cost as much as N
  single-domain images.
- The 21 s kernel re-check per domain × target adds up to ~11 h in a full
  run. Whether it can be skipped has not been investigated.

---

## 3. A serial build leaves the machine idle

Sampled once per second on wir-horst (36 vCPU), serial build:

| Phase | Busy cores, mean | Median | p95 | Utilisation | Disk |
|---|---|---|---|---|---|
| prepare (`make update`, feeds) | 1.1 | | | 3 % | IOPS peaks 12,400 |
| first domain (compiling + images) | 14.4 | 5.6 | 36 | 40 % | writes up to 1.6 GB/s, %util p95 100 |
| follow-up domain (images only) | 2.9 | **1.3** | 12 | **8 %** | %util mean 9.6, p95 100 |

- The load is **bimodal**: long stretches on one or two cores, and short
  full-load bursts. Our reading, not measured per process: the per-device
  image steps run one after another.
- The build spends 88 % of the time on fewer than 4 cores. iowait is ≈ 0,
  and on the local host there were only 130 write IOPS.
- `make -j` only helps *inside* one target, and Gluon builds one target per
  `make` invocation. The serial loop over targets and domains is the
  bottleneck.
- **More cores make it worse, not better.** A 64-core host would run the same
  serial work at ~4 % utilisation. Faster single cores would help. On the
  Ryzen, a follow-up domain kept 6.5–7.8 of 32 threads busy on average (20–24 %),
  against 2.9 of 36 on the Xeon. Our explanation, not a measurement: the
  slower Xeon cores stretch the serial part.

---

## 4. Design: golden tree, overlays, one worker per target

### 4.1 Golden tree

The normal `gluon/` tree is built completely once: prepare with `git reset`
and `make clean`, then the first domain for all targets, serially and with
the full `-j`. After that it is only read.

A fingerprint of the **inputs** (not of the tree) decides whether a later
run may reuse it:

- the Gluon commit
- the target list, device selection and `BROKEN`
- the host gcc and libc versions
- the SHA-256 of all patches and common template files

If the fingerprint matches, prepare is skipped entirely and the tree is not
touched at all. Re-applying the patches, even with identical content, would
renew the modification times of the patched files. OpenWrt partly decides
rebuilds by modification time, so such a tree would no longer be golden.

The fingerprint deliberately errs on the side of a rebuild. An unnecessary
rebuild costs as much as a serial run always did. A missed input would
silently produce images from stale sources. Only the domain selection and
the per-domain site files are left out, because they only reach
`gluon-site`, which is built per domain anyway.

The fingerprint file is deleted before a rebuild, so an interrupted rebuild
never counts as valid.

### 4.2 One overlay per worker, at the original path

Each worker gets a kernel overlayfs with the golden tree as `lowerdir` and
a private `upperdir`. Two properties of OpenWrt shape this:

- **The overlay has to be mounted at the tree's original path.** OpenWrt
  writes absolute paths into its `.prepared<hash>` stamps. Under any other
  path, everything would be rebuilt.
- **OpenWrt refuses to build as root.**

Both are solved without root, sudo or Docker:

```
build.sh (main process, normal UID)
 └─ setsid unshare -Urm scripts/ovl-enter.sh …   own process group; user+mount namespace, UID 0 inside
     ├─ mount --bind gluon  .overlays/<t>/lower   capture the golden tree before covering it
     ├─ mount -t overlay -o lowerdir=…/lower,upperdir=…,workdir=…,userxattr  gluon
     └─ unshare -U --map-user=<uid> build.sh --worker=<t>   back to the normal UID
```

- The bind mount captures the original directory. The overlay is then
  mounted **on top of the same path**, so no rename is needed.
- `userxattr` stores whiteouts in `user.*` attributes, which works without
  real root (Linux ≥ 5.11).
- The mounts exist only inside the worker's namespace. The main process and
  the other workers still see the unchanged golden tree.
- A worker is discarded by deleting its upperdir: ~3 s for 3 GB and
  ~70,000 files. Mounting takes 0.00 s.
- Requirements: Linux ≥ 5.11, util-linux ≥ 2.38 (`--map-user`), bash ≥ 5.1
  (`wait -n -p`). Ubuntu ≥ 23.10 also needs
  `kernel.apparmor_restrict_unprivileged_userns=0`. `build.sh` tests a real
  overlay mount, including `rm -rf` and re-create, before it relies on the
  mechanism. If the test fails, it builds serially and says so loudly.

**The overlay costs no measurable time.** With the full device set of
`ramips-mt7621` on the local host, the direct build took 241 s and 219 s
(domains 1 and 2), and the overlay build 238 s and 224 s. With only 2 devices,
where fixed costs dominate, the overlay cost 2.6 %.

### 4.3 Parallelise along the target axis

A worker builds **one target for all domains**, then its overlay is
discarded and the next target starts. The reasons:

- Targets share no write path. `bin/`, `staging_dir/target-*` and
  `build_dir/target-*` are per target.
- **Overlay growth belongs to the target, not to the domain.** The first
  domain creates 2.8 GB of upperdir, and every further domain only 0.2 GB.
  For 22 targets × 43 domains that is ~11 GB per worker on the target axis,
  against ~62 GB on the domain axis, where each step pays the 2.8 GB again.
- `.config` is rewritten 22 times instead of ~1,900 times.

Scheduling details (the first two were added after runs 1–3, see
section 6):

- **Longest target first.** The queue is ordered by the mean step time of
  each target in its most recent earlier run (LPT scheduling). Targets
  without any recorded step go to the front, since unknown may mean long.
- **Split `-j`.** Each worker gets cores × 2 ÷ workers, at least 2 (`-j 12`
  instead of 72 with 6 workers). The golden tree keeps the full value.
- **Staggered start.** Workers start 60 s apart, so that their compile
  bursts do not coincide at the start.
- **Abort handling.** Each worker runs in its own process group (`setsid`).
  If the main process is aborted, every group gets TERM and then KILL after
  10 s. In a test, 80 processes were gone in 1 s.
- **A failing worker does not stop the others.** No new worker is started,
  but the running ones finish their targets. Those are recorded as done, and
  `--resume` then builds only what failed.

### 4.4 Measuring while building

A small collector (`scripts/buildcollect.py`) samples once per second:

- busy cores, iowait, disk %util and write rate, steal time
- running and blocked processes, PSI (cpu, io, memory)
- the **phase** each process reports: prepare, golden, build, finalize

At the end it writes a recommendation for the next run, which
`WORKERS=auto` picks up. It evaluates only samples in which **all workers
are busy**, because ramp-up and tail say nothing about spare capacity. Only
a run that completes sets the recommendation. An aborted run may have
sampled only its easiest phase.

`build.sh` computes the mean number of busy workers (in Erlang) a second
time, independently, from its step-time CSV: the sum of step times divided
by wall time. The two methods agree within 0.1–0.2 Erl (run 2: 4.9 against
5.0; see section 5 for runs 5 and 6).

---

## 5. Results

All runs on wir-horst, Gluon v2023.2.6. Runs 1–6 used `WORKERS=6`, run 7
used 9 workers (`WORKERS=auto`, one per target), run 8 used 7 (10
configured, but only 7 targets) and run 9 used 6. "Golden" is the first
domain for all targets. "Parallel" is the remaining domains, spread over the
workers.

| Run | Date | Domains × targets | Total | prepare | golden | parallel phase (steps) | Erl (of W) | per follow-up domain⁴ |
|---|---|---|---|---|---|---|---|---|
| 1 | 10 Sep | 5 × 6 | 124 min | 14 | 66 | 41 min (24) | 4.6 | 10.3 min |
| 2 | 11 Sep | 9 × 6 | 163 min | 13 | ~71¹ | 79 min (48) | 4.9 | 9.9 min |
| 3 | 11 Sep | 4 × 8 | 151 min | 17 | 89 | 44 min (24) | 4.1 | 14.8 min |
| 4² | 11 Sep | 5 × 8 | 167 min | 18 | 91 | 58 min (32) | 4.0 | 14.5 min |
| 5 | 12 Sep | 9 × 9 | 229 min³ | 19 | 82³ | 126 min (72) | 4.5 | 18.0 min |
| 6 | 12 Sep | 9 × 9 | 247 min | 19 | 100 | 125 min (72) | 4.5 | 17.8 min |
| 7 | 12 Sep | 48 × 9 | 562 min | 0⁵ | 0⁵ | 550 min (432) | 7.2 of 9 | 14.9 min |
| 8 | 17 Sep | 8 × 7 | 181 min | 16 | 82 | 81 min (49) | 5.5 of 7 | 11.6 min |
| 9 | 18 Sep | 8 × 8 | 215 min | 18 | 93 | 103 min (56) | 4.3 of 6 | 14.7 min |

¹ golden plus finalize. ² First run with split `-j`, LPT order and PSI.
³ Resumed after a network outage had killed the first attempt. Two of the
nine golden steps were already done, and the total counts from the resume.
⁴ Per mesh domain (site code). The `-key` variant of a domain shares its
site code, so runs 5–6 have 8 follow-up variants but 7 follow-up domains.
Per variant: 15.8 min (run 5), 15.6 min (run 6), 11.5 min (run 7).
⁵ Golden tree reused: the fingerprint matched, so prepare and golden were
skipped and all 48 domains ran in the parallel phase.

**Serial comparison.** A serial run with the same 6 targets on the same day
took 27–29 min per follow-up domain. So follow-up domains ran **2.7× (run 1)
and 2.8× (run 2) faster**, and whole runs 1.6× and 1.9× faster. The golden
tree is now the largest single item: 44 % of run 2 and 58 % of run 3.

**Linear scaling.** Run 2 had twice as many follow-up steps as run 1
(48 against 24) and took 79 instead of 41 min. Ramp-up and tail matter
less the more domains there are.

**Repeatability.** Runs 5 and 6 used the same domains, targets and worker
count, a few hours apart. The only difference was the firmware content:
new config-mode packages and patches, which add a few small files to each
image.

| | Run 5 | Run 6 |
|---|---|---|
| Parallel phase | 126 min | 125 min |
| Erlang (build-times / collector) | 4.50 / 4.67 | 4.47 / 4.56 |
| Per follow-up domain | 18.0 min | 17.8 min |
| Mean step | 472 s | 465 s |
| Busy workers: 6 / 5 / 4 / 3 / 2 / 1 (min) | 48.5 / 20.5 / 17.0 / 29.2 / 6.8 / 4.2 | 49.2 / 21.0 / 10.3 / 33.0 / 6.3 / 5.2 |

At run level the numbers repeat within about 1 %. Per target, the mean
step time varies by up to ±10 %: ath79-generic 648 against 595 s,
ath79-mikrotik 471 against 526 s. Single-target comparisons between runs
therefore need more than one run.

The two Erlang methods differ by 0.09–0.17 Erl in runs 5 and 6. The
collector averages the number of workers that report the build phase in
their status files, over the samples with at least one such worker. The CSV
method divides the sum of step times by the wall time from the first step
start to the last step end. We have not traced the difference further.

**Nine workers, one wave (run 7).** With one worker per target, 9 workers
put all 9 targets into a single wave. Compared with runs 5–6 (6 workers,
two waves), the parallel phase built 47 instead of 35 steps per hour
(+36 %), and a variant took 11.5 instead of 15.7 min. The mean step got
slower, 549 s against 465–472 s: more concurrent workers make each step
longer (section 6.2). The collector saw all 9 workers busy for 274 of the
550 minutes and the CPU 54 % utilised in that time; its rule recommends a
tenth worker, which only helps with more than 9 targets.

**Output of run 5:** 2,727 images and 26.0 GB, about 320 MB per step. The
image share of that (23.7 GB) is ~290 MB per step. The planning figure of
250 MB per step, an average over all 22 targets, underestimates runs with
only the large targets.

**Runs 8 and 9** are short test builds of 8 variants each and add little
beyond runs 1–6. Run 8 had one wave (7 workers for 7 targets). Run 9 had
two (6 workers, 8 targets), and 2 workers were busy for 27 of its 103
minutes.

### Production run: release 2023.2.6

This run is **not part of the measurement series**. It was not planned as
an experiment, and nothing was varied. The numbers come from the
`buildinfo/` files the run published, evaluated with
[`analyse.py`](analyse.py). The raw data is in
[`data/release-26091920sta/`](data/release-26091920sta/).

| | |
|---|---|
| Scope | 86 variants × 20 targets = 1,720 steps |
| Workers | 8 (`WORKERS=auto`), 20 targets, so 3 waves |
| Total | 36 h 29 min (2,190 min), 20 Sep 16:18 to 22 Sep 04:48 |
| prepare | 82 min |
| golden | 136 min for the remaining 6 of 20 targets, see below |
| Parallel phase | 1,942 min (32.4 h), 1,700 steps, 6.8 Erl of 8 |
| Mean step | 464 s |
| Per follow-up variant | 22.9 min |
| Output | 37,066 images, 325.7 GB |

- **The golden tree was not built in this run alone.** A first attempt on
  19 Sep ran prepare (40 min) and 14 of the 20 golden steps (about 2.5 h),
  then stopped. A second attempt ended during prepare after 5 min. The run
  above resumed from there. Built from scratch, the whole release therefore
  took about 40 hours of build time, spread over three attempts.
- **The waves are visible.** Busy workers, in minutes: 8: 1,050, 7: 351,
  6: 51, 5: 158, 4: 247, 3: 58, 2: 20, 1: 9. `ath79-generic` was again the
  longest target (85 steps, mean 690 s, 1,031 min in total), but with three
  waves it was not the critical path. The third wave ended at minute 1,942.
- **Step times under load fit runs 5–7.** The mean step of 464 s is in the
  range of runs 5 and 6 (465–472 s with 6 workers), and below run 7 (549 s
  with 9).
- The collector recommended 10 workers for the next run. With 20 targets
  that means 2 waves instead of 3, and all-busy samples showed the CPU 54 %
  utilised. That is a prediction, not yet tested.
- There is no serial comparison for this scope. The 138 h in the summary is
  an extrapolation for 22 targets.

---

## 6. Findings

### 6.1 The speed-up is F ≈ Erl ÷ 1.7, not W

In the parallel phase of runs 1 and 2, a step took ~475 s on average, against
~280 s for the same steps serially. That is **1.7× slower**. With 4.6–4.9 of
6 workers busy on average, the effective speed-up is 4.7 ÷ 1.7 ≈ 2.8, which
matches the measured 2.7–2.8.

For planning, the full run of 86 variants is estimated at ~52 h with golden
tree (F = 2.8), or ~48 h when the golden tree is reused. An upper bound with
all 6 workers always busy is 6 ÷ 1.7 ≈ 3.5, i.e. ~42 h. A first estimate
with F = W (~27 h) was far too optimistic. The 2023.2.6 release, with 20
instead of 22 targets and 8 workers, took about 40 h from scratch (section
5).

### 6.2 What the 1.7× is not

- **Not the hypervisor.** Steal time was 0.01–0.05 cores on average (max 1)
  in runs 3–6.
- **Not CPU contention.** In run 3 every worker still used `-j 72`. A spot
  check with `vmstat` showed 13–95 runnable processes on 36 vCPUs. Run 4
  split `-j`: the CPU pressure stall with all workers busy dropped to
  **4 %**, and the mean step time barely moved (7.5 → 7.3 min). The CPU
  therefore was not the cause.
- **Not average disk load.** The disk is 8–13 % busy on average, and iowait
  is ~0.5 cores.

**What remains.** I/O pressure is 8–9 % with all workers busy (PSI io
`some`, runs 4–6), with bursts of up to 38 blocked processes and disk
%util p95 81–89 %. The candidates are overlayfs copy-up, writeback of image
bursts that coincide across workers, and **clock speed**. The E5-2698 v4
turbos to about 3.6 GHz with few busy cores and to roughly 2.7 GHz with all
cores busy. A mostly single-threaded step gets slower when its neighbours
light up more cores. None of this has been isolated experimentally.

**Run 7 shows the dependence directly.** Its long tail (section 6.3) ran
the same kind of step with 9, then fewer, then a single worker. Relative
to the median step time of the same target at full load:

| Workers busy | 8–9 | 7 | 6 | 5 | 4 | 3 | 2 | 1 |
|---|---|---|---|---|---|---|---|---|
| Step time | 1.00 | 0.92 | 0.91 | 0.82 | 0.70 | 0.73 | 0.59 | 0.54 |
| Steps | 374 | 20 | 5 | 10 | 5 | 4 | 6 | 8 |

`ath79-generic` took ~12.3 min per step with 9 workers and 6.7 min alone.
The room temperature at the rack stayed at 32.3 °C throughout, so this is
not an effect of the evening. In run 6 the one step with a single worker
busy was also at 0.55. The step time is set by what runs next to it, not
by the step itself. That fits clock speed and I/O equally well; which of the
two dominates is still open. One of the host's two CPU temperature zones
peaks at 88–89 °C under build load, the critical level in its monitoring
and 8–10 K above the other zone, which makes clock speed the stronger
candidate.

### 6.3 Waves, and the critical path

With one worker per target, the parallel phase is a scheduling problem of T
jobs on W machines, where the job lengths are known from the last run.

**Run 3 (8 targets, 6 workers):** The two x86 targets started when the
first wave ended and ran **13–18 min with only 2 workers** busy: 4.1 Erl.
The collector saw spare CPU and recommended "one more worker" (7). With 8
targets, 7 workers still means two waves, and in the second one a single
target runs alone. The correct answer was 8. The recommendation rule now
counts waves: ⌈T/W⌉.

**Run 5 (9 targets, 6 workers):** busy workers over the 126-min parallel
phase:

| Workers busy | 6 | 5 | 4 | 3 | 2 | 1 |
|---|---|---|---|---|---|---|
| Minutes | 48.5 | 20.5 | 17.0 | 29.2 | 6.8 | 4.2 |

The second wave (mt7622, x86-generic, mpc85xx-p1020) ran for ~50 min with
at most 3 workers.

- **LPT ordering does not remove waves** when the targets have similar
  lengths. It only makes the tail shorter.
- **The critical path is the longest target.** In run 5, `ath79-generic`
  (121 sysupgrade images per domain) ran from minute 0 to 94.5, with a mean
  of 648 s per step. With 9 workers, one wave, the parallel phase cannot get
  shorter than that chain, i.e. ~86–95 min instead of 126. That assumes the
  per-step slowdown does not grow with 9 concurrent workers, which is
  exactly what section 6.2 cannot promise.
- **Run 6 repeated the pattern.** LPT put the three shortest targets
  (x86-generic, mt7622, mpc85xx-p1020) into the second wave, exactly as
  intended. Still, 3 or fewer workers were busy for 45 of 125 minutes.
  `ath79-generic` again set the lower bound, at 85.7 min.
- **Run 7 (9 targets, 9 workers, 48 domains) has one wave, and a tail.**
  The eight shorter targets finished between minute 423 and 492;
  `ath79-generic` ran alone for the last 58 minutes (1 worker busy: 57.5
  min). Its steps got shorter as the others finished (table in 6.2), which
  made the end of the run faster than any estimate from the average step.
- **The next lever would be a second worker for the longest target.** Two
  workers could each build half of the devices of `ath79-generic`, in two
  separate overlays of the same target. With many domains, splitting the
  domains of that target between two workers is simpler and gives the same
  effect. Both are untested.

### 6.4 The golden tree is now the largest item

For few domains, the serial golden tree dominates: 44–58 % of runs 2–4. It
disappears completely when the fingerprint matches, e.g. when a run only
builds a different selection of domains. Runs 1–6 all rebuilt it: prepare
and golden appear in every run. **Run 7 reused it:** same inputs as run 6,
so prepare took 0 min and no golden step ran; the 562 min are 550 min
parallel phase and 11 min finalize. Parallelising the golden tree itself is
harder, because all targets build into the same tree.

---

## 7. Measurement pitfalls

- **A load threshold does not detect the build phase.** Our first
  "image-build" measurement on wir-horst had actually sampled `make update`:
  prepare also produces I/O peaks. The giveaway was that busy cores never
  exceeded 2.2, while image builds always have full-load bursts. The sampler
  now waits for the process `make GLUON_TARGET=…`, and later versions read
  the phase that `build.sh` publishes.
- **A synchronous disk benchmark is not the ceiling.** The host benchmark
  (`fdatasync`) gave 746 MB/s. A single serial build then wrote up to
  1,599 MB/s, and run 5 peaked at 4,049 MB/s. Builds write asynchronously,
  and writeback absorbs the bursts.
- **Averages hide the bursts that matter.** Disk %util was 11 % on average
  and 80–100 % at p95. The average says "idle", while the bursts collide
  across workers.
- **Counting samples by the main process's phase.** In run 1 the collector
  found 0 samples with all workers busy, because the main process still
  reported "golden" while the workers were in the parallel phase. The
  phases are now reported per process.
- **`pgrep -f` / `pkill -f` match the shell that runs them** when the pattern
  appears in its own command line. Our first abort test counted itself.

---

## 8. Other lessons

### 8.1 Traps in the overlay setup

- **fuse-overlayfs cannot build OpenWrt.** `package/Makefile` does
  `rm -rf root.orig-<target>` and immediately `cp -fpR root-<target>
  root.orig-<target>`. On fuse-overlayfs the lower directory reappears after
  the `rm -rf`, and `cp` fails with "cannot create directory: File exists".
  Kernel overlayfs sets the whiteout correctly.
- **No overlayfs on top of overlayfs.** Inside a Docker container, `/tmp`
  is Docker's own overlay and cannot serve as upperdir. A bind-mounted ext4
  path works.
- **A killed overlay leaves `work/work` with mode 000.** `rm -rf` needs a
  `chmod -R u+rwx` first. `build.sh` does this itself when the target starts
  again.
- **Docker built ~10 % faster than the host** in a local comparison: 268 s
  against 339 s per run, 77 s against 86 s per domain. We suspect the
  different host tool versions (Debian Bookworm in the container, Ubuntu on
  the host). This is not measured, and we did not act on it.

### 8.2 Surviving a network outage

A DNS outage at the build site killed a run during the night. `build.sh`
now:

- **Retries quickly** only if the failed step's log shows a network
  signature (a list of curl, git and OpenWrt download messages), or a
  network probe fails (`getent` plus a TCP connect to port 443).
- **Otherwise fails at once.** A compile error is not retried.
- **Sleeps if the network stays down.** It wakes every 10 min and gives up
  after 2 h. That covers typical local causes: work at the street cabinet,
  a tripped fuse taking a switch down, routing incidents.
- **Does not count the waiting time as build time.** It is reported as its
  own phase `netwait`, and the collector ignores it.

**A bash trap found along the way.** `set -e` (errexit) is ignored for the
*entire* command when that command is part of an `||` or `&&` list, or an
`if` condition. This includes subshells and functions called there, even if
they run `set -e` themselves. So

```bash
( set -e; step1; step2 ) || handle_failure
```

runs `step2` even when `step1` fails, and `handle_failure` only sees the
status of `step2`. The working pattern takes the subshell out of the list
context:

```bash
set +e; trap - ERR
( set -e; eval "$CMD" ); rc=$?
set -e; trap on_error ERR
[ "$rc" -eq 0 ] || handle_failure
```

### 8.3 Resume must not mix sources

An interrupted run resumes with only the missing steps. Before resuming,
`build.sh` compares a fingerprint of all inputs (templates, patches,
configuration, target and domain lists) with the one of the interrupted
run. If they differ, it refuses: images built from two different sources
must not end up under one signed manifest.

---

## 9. Limitations

- **One host and few runs.** Only one configuration was repeated
  (runs 5 and 6), and not under controlled conditions. The hypervisor runs
  other guests, which the build guest cannot see beyond steal time.
- **Worker counts were not varied systematically.** Runs 1–6 used 6
  workers, run 7 used 9, run 8 used 7, run 9 used 6 and the release run 8.
  The wave argument (section 6.3) is supported by runs 3, 5, 6 and 7, but no
  run compared worker counts on the same targets and domains.
- **The production run is a single data point** (section 5), not a
  measurement: it was interrupted twice, and nothing was varied. The
  collector's recommendation of 10 workers for 20 targets is untested.
- **`WORKERS=auto` does not rescale for a different target count.** It
  takes the last recommendation as it is. Run 8 recommended 6 workers and
  run 9 ran with 6. Run 9 recommended 8, computed for its 8 targets (one
  wave instead of two), and the release run took those 8 over for 20
  targets, which gave it three waves. Only the release run's own
  recommendation, 10, was computed for 20 targets. In practice this has
  worked, because consecutive runs usually build similar sets; the release
  run was the first large change in target count.
- **There is no serial run at production scale.** The 138 h are an
  extrapolation from the costs in section 2, for 22 targets.
- The cause of the **1.7× per-step slowdown** is narrowed down, not
  identified.
- **x86-64** was not part of the local overlay measurements.

**More is possible, no doubt.** This is what we worked with, and it paid
off in this campaign: the final build took about 40 h instead of an
extrapolated 138 h serially. The larger effect is harder to count: without
parallel builds, the intermediate test runs would have used fewer domains
and targets, and some bugs would likely have gone unnoticed.

---

## 10. Reproducing and reusing

- `build.sh` and `scripts/` in this repository are the implementation.
  `scripts/ovl-enter.sh` is the whole rootless overlay entry.
- [`data/`](data/) holds the `buildinfo/` files that each run publishes:
  - `*.build-times.csv`: one line per step, with start epoch and seconds
  - `*.metrics.csv.gz`: collector samples, one per second
  - `*.empfehlung.txt`: the recommendation for the next run
  - `*.summary.txt`: the summary box
- [`analyse.py`](analyse.py) reproduces the numbers of sections 5 and 6 for
  runs 3–9 and for the release run:

  ```bash
  python3 docs/parallel-builds/analyse.py docs/parallel-builds/data/*/
  ```
- The build system is currently bundled with Neanderfunk's site templates
  and Gluon patches. Its interface to them is narrow: two directories,
  `templates/` and `patches/`, and a `prepare.sh` inside the template.
