# Local CPU verification

The soft glow in Settings uses a resting bitmap and a Core Animation opacity pulse. It no longer
rebuilds the SwiftUI preview for each display refresh. Bitmap and grid previews stop when their
window is closed, minimized or occluded, or their view is hidden, and resume when visible again.
Reduce Motion and frozen previews stay still.

Grid effects request a display-link rate that follows their breathing period and recent drawing
cost, shared across active displays. The existing drawing-time guard remains because a display
link can deliver callbacks above its requested rate. Hidden statistics windows also skip resizing
to updated content.

## Measuring a running copy

Build with `./scripts/build-app.sh release`, launch the resulting application, and verify that the
PID belongs to that exact executable. Allow first-run history indexing to finish before measuring
steady background use. Measure Settings, Statistics and the collapsed island separately; close
and reopen windows to check that their previews resume normally.

```sh
python3 scripts/measure-process-cpu.py PID --duration 30 --interval 5
```

This macOS-only reader measures the change in kernel user plus system CPU time over each wall-clock
interval. Its percentages use one CPU core as 100%. It reports the full-window mean and the maximum
interval mean; it does not measure sub-interval spikes. A process list's lifetime average is not
interchangeable with these measurements.

`PreviewLifecycleTests` checks bitmap reuse, animation restart avoidance, hidden/occluded/closed
window suspension and reopening, and the display-link budget. Its offscreen window explicitly
supplies visibility notifications because the display server may occlude every XCTest window.
These tests verify lifecycle logic; native desktop inspection is still required for acceptance.

## 2026-09-30 local validation

The installed 0.4.22 original and this 0.4.26-based local build read the same installed clients.
Settings and Statistics were closed during each 30-second background measurement. The local build
had finished history indexing and reported eight quota windows before the final measurement.

| Running copy | Main-process mean CPU | Maximum 5-second mean |
| --- | ---: | ---: |
| Original 0.4.22 | 1.549% | 1.780% |
| Local optimized 0.4.26 | 0.074% | 0.083% |

Until 2026-10-11 the reader took the kernel's CPU ticks for nanoseconds. A tick is 125/3 ns on Apple silicon, so a
figure taken there before that date is 41.7 times too small: 1.549% reads 64.5% and 0.074% reads 3.1%.

These are separate short observation windows, not a controlled benchmark of only this patch.
Upstream improvements since 0.4.22 also contribute. The values cover the main process; they exclude
separate client-engine and hook processes, and do not rule out short indexing or refresh peaks.
An earlier Settings measurement averaged 0.207%, but history indexing was still pending then.

The release build and signature verification passed. Native previews showed both soft and dot-grid
glows. The full release suite passed 659 XCTest tests with one skipped, plus four Swift Testing tests,
when the test runner's preferred language was explicitly English. Without that override, four existing
English-copy assertions fail on a Chinese system. The override was restored after the run.

The separate local app is installed in `~/Applications/Agent HUD Open.app`. The original installation
and preferences are retained. Startup registration has not been switched to the local copy.

## Where background CPU goes

Cost follows the agents: while one writes its log a collection pass runs every two seconds, and whatever a pass
repeats in full is paid thirty times a minute. `sample PID 20` on a running release build, with its busy samples
grouped by the application's own functions, shows which part is paying; a mean alone does not.

- A dock of logos runs no timer. A bot asks for a frame only as often as its motion shows: 30 a second for a morph,
  an act or a blink, 15 while its eyes follow the pointer, 10 for a breath, and none until its next visit while it
  waits as its logo. Its frames are drawn in the display's colours and byte order; a layer given any other picture
  converts it on every commit, which cost as much as drawing it.
- The Antigravity and DeepSeek observers poll their client's local service every two seconds, and look for that
  service in the process list at most every ten. A listing is half a megabyte on a busy Mac and is searched, not
  split into lines.

## 2026-10-11 local validation

Dynamic mode, collapsed, on an Apple silicon Mac while a Claude Code session wrote its log; 20-second samples of the
release build before and an optimised build after, in milliseconds of CPU per 15 seconds sampled.

| Part | Before | After |
| --- | ---: | ---: |
| Bots: timer, drawing and layer commits | 490 | 227 |
| Antigravity approval observer | 274 | 25 |
| DeepSeek question observer | 285 | 3 |

The samples are a minute apart at best and the agents' activity differs between them; they locate cost and do not
benchmark it.
