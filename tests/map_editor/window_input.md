# Genuine X11 Map acceptance and observed latency

## Reproduce

From the repository root, with the built Linux x86-64 debug addon present:

```bash
DISPLAY=:0 python3 tests/map_editor/window_input_runner.py \
  --godot /mnt/data/code/godot/bin/godot.linuxbsd.editor.x86_64 \
  --samples 31 --timeout 180 > /tmp/opencode/tbloader-window-input.log 2>&1
rg 'Artifacts:|FAIL|PASS window_input|ERROR|Traceback' /tmp/opencode/tbloader-window-input.log
```

Python 3.11+, Linux `/proc`, `libX11.so.6`, `libXtst.so.6`, an accessible X11/XWayland
server, and the exact engine pin are required. No installation, Xvfb, xdotool, or
desktop configuration changes are needed. Run as the sole displayed-editor tester;
the runner's `/tmp/opencode/tbloader-window-input.lock` prevents concurrent copies
of this suite. The default is eight measurement samples per fixture; the command
above reproduces the 31-sample acceptance run. Each editor process is bounded.

## Input and observation boundary

- `window_input_runner.py` reuses `run_tests.stage`, fixture generation, engine pin,
  strict import and diagnostic protocol, copied native library, isolated XDG paths,
  input hashes and retained artifact layout. No addon or fixture symlinks.
- `x11_input.py` connects to the live server and requires XTEST (observed **2.2**).
  It finds the staged editor by `_NET_WM_PID`; all keyboard/mouse presses require
  its focus and mouse presses require the pointer to be over its window. Godot's
  InputOnly IME child is accepted only through ancestry to the verified PID window.
  Native Wayland windows are not injection targets.
- An owned 1×1 override-redirect X window takes focus via `XSetInputFocus` to test
  real OS focus loss. It does not enter the tiling layout. Pending releases are
  cleaned up only while our editor/sink owns focus. A negative guard check in both
  grid cases proves attempted typing into the sink is rejected before injection.
- Original X focus and pointer are restored at teardown. On this Hyprland desktop,
  `hyprctl` also records/restores the original native Wayland window address/PID
  and cursor position. These are focus/pointer operations, not settings changes.
  The final run confirms the original Ghostty address was restored. Existing
  windows are never moved, resized or closed by the runner.
- `window_input_observer.gd` is test-only and dormant unless `TB_TEST_SUITE` is
  `window_input`. It reports widget rectangles, native canonical text/bounds,
  selection, revision, real history version, graph gestures, visibility, focus,
  camera capture/position, and rendered-frame callbacks. Its command vocabulary is
  state, screenshot, measurement bookkeeping and test-process finish. It never
  creates `InputEvent`s, calls input/authoring handlers, edits a document, assigns
  widget values, selects the Map tab, or changes widget focus.
- The pinned `--single-window` option embeds the actual Godot dialogs. Coordinate
  reporting accounts for embedded offsets and the native X11 origin, checked
  against `XTranslateCoordinates`. Separate native dialog-window behavior is not
  covered by this configuration.
- Screenshots are actual rendered root-viewport images; they do not prove physical
  compositor presentation. `window-captures/.gdignore` prevents screenshots from
  entering the project material index. No error/warning allowlist is used.
- Completion requires exit zero, empty stderr, no recognized engine/script errors,
  exactly one PASS marker and exactly the expected positive assertion count for
  each of two editor processes. Failed assertions, early exits and timeouts retain
  full logs, latest state and input trace. A killed failed run is never a PASS.

## Verified results — 2026-09-13

**594 checks passed**, including 31 repeated gesture cycles on each workload, plus
a fresh displayed editor process. Source baseline `58e46df`; native library SHA-256
`cf3482283f24cd3be7822aad1fe347024bec1889385a561198a62d264b34c9d5`.
No production change was needed for this acceptance.

Authoritative retained run:
`tests/map_editor/artifacts/window-input-p_80a_gv/`.
Full outer log: `/tmp/opencode/tbloader-window-input-final.log`.
The explicit no-display probe also fails before staging/launch, with zero checks
and no fallback: `artifacts/window-input-k7uutrsd/result.json`;
`/tmp/opencode/tbloader-window-input-no-display.log`.

Actual XTest cases:

1. Click the **Map** main-screen tab; LMB drag creates exactly one selected cuboid,
   bounds `(-64,-48,-64)..(64,48,64)`, six faces/eight vertices/twelve triangles.
   One gesture produces one action. Esc deselects; degenerate click selects. Real
   horizontal-quad and vertical-grid splitter drags resize and restore pane bounds.
2. Move in Top by `(32,16,0)` to `(-32,-32,-64)..(96,64,64)`; Ctrl+Z/Y restore exact
   canonical before/after content through real editor history.
3. H hides, clears selection and removes camera triangles without editing content;
   Shift+H restores visibility without selecting. Revealed geometry is selectable.
4. Grid keys 4/5 set 8/16; Ctrl+Tab cycles **both** panes through all orientations,
   preserving the other pane and the native document. Real Front/Side moves each
   preserve the hidden axis and Ctrl+Z returns exact original canonical content.
5. In each grid, start a selected-brush LMB drag, move 48/32 screen pixels, and
   assert a nonzero live move preview **while LMB is still held**. Transfer actual
   X focus to the owned sink; assert window focus false, gesture cancelled, and
   unchanged canonical content, native revision and real history version. Release
   and refocus, then assert all remain unchanged. This does not confuse a click or
   a drag cancelled before movement with moved-drag cancellation.
6. Type `nh123` into material search: no inspector, hide, grid or document action;
   zero search results. Replace with `checker`: both project folders are found.
   Type `baseline/checker` into the shader widget and click Assign: all six native
   face textures change. Frame button displays the checker cuboid.
7. N opens the entity inspector. Type `message` / `nh123 wasd`; no graph/fly action
   or document edit until clicking **Set on targets**. The worldspawn property is
   committed, the inspector closes via its actual titlebar, and Ctrl+Z/Y undo/redo
   the property exactly. Real 3D/Map tab clicks preserve the authoring document.
8. RMB enters captured fly; actual held W moves the camera. Esc, second RMB, and
   actual OS focus loss each release capture and clear held keys. The focus-loss
   case keeps W pressed until focus is lost and verifies no post-refocus movement.
9. Save As types the absolute filename in the actual dialog and writes exact native
   canonical text. New replaces the saved document; Open resolves the empty-new
   dirty prompt, selects the saved file, and reopens with exact bounds/materials/
   property. A **second displayed process** repeats Open and verifies clean native
   data and twelve rendered triangles before its screenshot.
10. Open each deterministic 32/256-brush blockout through the actual file picker,
    select its floor, then perform 31 LMB begin / three motion / release / Ctrl+Z /
    Ctrl+Y / Ctrl+Z cycles. Every preview leaves canonical text unchanged; release
    moves only the selected floor by 48 map units; history returns exact saved
    text and clean status. Native counts and rendered preview triangles are checked.

The earlier injected `editor`/`ui_journey` suites remain the evidence for broad
component, clipper/prism, UV, point/brush entity, binding, bake/collision,
tab/lifecycle and recovery cases. They are not relabeled as OS-input tests.

### Artifacts

Under the authoritative run:

- `result.json`: cases, commands, engine/library/runner/staged hashes, source status,
  XTEST version and original desktop identity.
- `input.*`, `reopen.*`, `import.*`: complete stdout/stderr and process records.
- `x11-events.json`: monotonic XTest press/release/motion and focus/restoration trace.
- `input-states.json`, `reopen-states.json`, `expected.json`: actual widget/native
  assertions and canonical text. `input-metrics.json` retains observed input and
  all frame callback intervals; `input-timings.json` retains raw operation timings.
- `memory-{32,256}.json`, `latency-summary.json`: raw procfs and timing summaries.
- `project/window-authored.map`, `project/blockout-{32,256}.map` and `.json` bounds
  manifests; generated asymmetric checker textures and real copied addon.
- `project/window-captures/window-{hidden,textured,entity,saved,reopened}.png` and
  `window-blockout-{32,256}.png`. Textured, entity, larger blockout and reopened
  captures were visually inspected. Final editor viewport: **1901×1048**, as placed
  by the compositor; requested dimensions are not assumed to equal actual size.

## Display-backed observation timings

The 32-brush fixture has 192 faces / 384 triangles; 256 has 1,536 / 3,072. These are
the same generated cuboid room fixtures used by the
[native baseline](../../MAP_EDITOR_PERFORMANCE.md). A single shared-workstation
editor process tests 32 then 256, with its real preview, material browser, sessions
and snapshot history present. There are no warmups or outlier removals. This is a
repeatable interaction experiment, not a controlled hardware benchmark.

Each timing ends when Python receives and validates a read-only state snapshot.
It includes IPC/polling (10 ms request polling, 30 ms unsuccessful-predicate delay),
full native draw-data/export queries, JSON encoding/reading and Python assertions.
Motion/release begin before the XTest call; drag-begin starts immediately after
the press/XSync. Key timings include the deliberate **25 ms key-down hold**. These
are upper-bound observation delays, not isolated handler, native rebuild, GPU,
compositor presentation or input-to-photon times. JSON work is especially material
at 256 brushes. The four one-cuboid and four empty-document splitter release
samples are smoke data only.

| Observation (ms, median / p95 / max) | 32 brushes | 256 brushes |
|---|---:|---:|
| Drag begin, 31 samples | 32.97 / 58.34 / 84.80 | 76.25 / 132.60 / 141.51 |
| Motion preview, 93 samples | 33.00 / 46.02 / 101.07 | 50.86 / 93.44 / 105.15 |
| Release/commit, 31 samples | 44.00 / 67.02 / 68.91 | 168.26 / 190.79 / 193.80 |
| Undo, 31 samples | 58.64 / 69.77 / 76.50 | 114.76 / 159.80 / 160.57 |
| Redo, 31 samples | 58.98 / 74.35 / 89.32 | 132.10 / 158.50 / 162.42 |
| `frame_post_draw` interval, 248 samples | 43.47 / 88.62 / 144.07 | 108.23 / 172.49 / 192.75 |

Frame rows measure elapsed time **between rendered callbacks**, including idle/
event pacing and observer work, not time spent rendering a frame. Only the named
gesture measurement windows are summarized; screenshots occur outside them. The
full intervals including startup are retained separately. p95 uses nearest rank.
All listed operation observations exceed 16.7 ms; 244/248 small-map and 248/248
large-map callback intervals exceed it. The **16.7 ms complete-frame / 60 Hz target
is not established** by this instrumented run. Continuous motion with lightweight
event-to-render instrumentation, controlled pacing and idle-frame baselines remain
the follow-up responsiveness gate. Native-only rebuild times remain in the native
baseline; these observations must not replace or be subtracted from those values.

Editor RSS/HWM after the first/last cycles, procfs kB (KiB):

| Fixture | First RSS / HWM | Last RSS / HWM |
|---|---:|---:|
| 32 | 1,383,840 / 1,383,840 | 1,383,844 / 1,383,844 |
| 256 | 1,463,228 / 1,463,228 | 1,504,408 / 1,504,408 |

These include the engine, driver, current and retained documents, history payloads,
observer arrays and allocator retention; the 256 run follows the 32 run. Each cycle
undoes back to baseline but the session still retains action tokens until budget
eviction/teardown. This is not per-brush memory or a leak conclusion. The renderer
header reports OpenGL 3.3 compatibility on the local NVIDIA driver; no hardware
capability/performance claim is made.

## Limitations found while making the journey genuine

- On the pinned engine, FileDialog `OPEN_FILE` disables Open unless a **list item**
  is selected; typing a valid absolute filename alone is insufficient. The journey
  selects the real saved-map item. Users should likewise select the file in the
  list (or double-click it). This is an engine FileDialog behavior, not a native
  map parser failure, and no engine modification is included.
- Initial probes exposed test-coordinate handling for embedded windows and the
  XIM child focus transition; the runner/observer were corrected before the final
  run. Every failed run remains under `artifacts/window-input-*` with its reason.
- Broad XTest coverage for every P0/P1 operation, separate native dialog windows,
  other engines/platforms/renderers, physical presentation timing, controlled 60 Hz
  responsiveness and the production lifecycle limitations in the handoff remain
  outside this verified gate. P2 is still future work.
