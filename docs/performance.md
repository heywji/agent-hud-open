# Local CPU verification

The board-only build runs no frame timer. A collapsed HUD is the notch's shape or a queue of marks baked into
bitmaps once per size and appearance, and it redraws only when what it shows changes: the store's clock ticks every
10 seconds, and a tick that changes no row, session, mark or setting leaves every HUD alone; the open panel's
countdowns follow that clock. The panel's shadow is a blurred bitmap drawn once per panel size, on a background task
during the hover delay. In the background, collection is what costs CPU.

## Measuring a running copy

Build with `./scripts/build-app.sh release`, launch the resulting application, and verify that the
PID belongs to that exact executable. Allow first-run history indexing to finish before measuring
steady background use. Measure the collapsed HUD, the open panel and Settings separately.

```sh
python3 scripts/measure-process-cpu.py PID --duration 30 --interval 5
```

This macOS-only reader measures the change in kernel user plus system CPU time over each wall-clock
interval. Its percentages use one CPU core as 100%. It reports the full-window mean and the maximum
interval mean; it does not measure sub-interval spikes. A process list's lifetime average is not
interchangeable with these measurements.

Until 2026-10-11 the reader took the kernel's CPU ticks for nanoseconds. A tick is 125/3 ns on Apple silicon, so a
figure taken there before that date is 41.7 times too small.

The values cover the main process; they exclude separate client-engine and hook processes, and do not rule out short
indexing or refresh peaks.

## Where background CPU goes

Cost follows the agents: while one writes its log a collection pass runs every two seconds, and whatever a pass
repeats in full is paid thirty times a minute. `sample PID 20` on a running release build, with its busy samples
grouped by the application's own functions, shows which part is paying; a mean alone does not.

- A logo queue runs no timer and nothing in it moves: its marks are drawn once per size and appearance, with their
  outline, into bitmaps the layers only composite (`LogoImages`).
- The shadow is drawn again only for a new panel size: a clock or data refresh that leaves the size alone reuses the
  installed bitmap, and a hover that ends before the panel opens discards its unfinished one
  (`ShadowWindowController`).
- Nothing polls a client's local service between readings: the observers that did, for Antigravity's approvals and
  DeepSeek Harness's questions, are gone with the features they served.
