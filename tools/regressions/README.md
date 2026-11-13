# File tools regression

Build the Debug app, then run:

```sh
bash tools/regressions/run-file-tools-tests.sh \
  /tmp/orbit-files-build/Build/Products/Debug /tmp/orbit-files-tests
```

The runner imports the real Debug module without starting the app delegate. Its
20 test groups create PDFs and PNGs in unique scratch directories and use only a
private pasteboard. They check JPG pixels, page order and rotation, original and
name-collision preservation, damaged/locked/unreadable/oversized inputs, retained
completed pages after failure, pre-cancellation, file filtering, ring geometry,
and cropped/backdrop output pixels at 1×/2× for every canvas ratio. Entering
background editing must exit crop mode while preserving the committed crop.
Source PNGs
are decoded and checked before editing; decoded outputs are normalized to sRGB
before comparing channel values. `ORBIT_TEST_LIBRARY` can override the dylib.

Cancellation between completed pages, actual Finder drag + Shift delivery,
copy-only AppKit drop negotiation, and editor preview/crop pointer interaction
need an interactive check. The unit runner does not claim to cover these.
Use `ORBIT_FILE_TEST_FILTER` with a regular expression to run only matching test
groups, for example `ORBIT_FILE_TEST_FILTER='entering background|cancelled before'`.

To check result-window lifecycle against the real Debug module:

```sh
bash tools/regressions/build-file-tools-workflow-tests.sh \
  /tmp/orbit-files-build/Build/Products/Debug /tmp/orbit-files-workflow
```

Launch the resulting `Orbit File Workflow Tests.app` on a logged-in macOS desktop.
It does not start Orbit's app delegate. Its eight checks verify that editing a
completed page retains the other pages and failure information, and that a result
window closed during conversion reopens when conversion stops. Fixtures and
`workflow.log` stay in the supplied scratch folder; `workflow.exit` contains the
failure count. The app stays open for inspecting the real result window.

Completed pages are retained when a later page fails or conversion is cancelled;
conversion stops at that point. External-file edits save a new PNG beside the
source, never overwrite it, and do not offer the capture editor's Trash action.

# Clipboard regression

Build the Debug app with testability enabled, then run the native regression:

```sh
bash tools/regressions/run-clipboard-tests.sh \
  /tmp/orbit-clipboard-build/Build/Products/Debug /tmp/orbit-clipboard-tests
```

The runner imports the Debug module with `@testable import Orbit`, without
starting the app delegate. It links `Orbit.app/Contents/MacOS/Orbit.debug.dylib`
by default. For builds that provide a separately linked test library, set
`ORBIT_TEST_LIBRARY=/absolute/path/to/libOrbitTests.dylib` before the command.
A logged-in macOS desktop is required for the named pasteboard.

The 86 assertions cover scalar/grapheme preview boundaries (including a single
1 MiB grapheme), unchanged small previews and footnotes, bounded code/host/size
metadata, old JSON decoding without new fields, polling and classification,
duplicate identity and pin preservation, own-write suppression, exact-byte
normal/plain copying, full-payload tail search, kind/pin filtering, view-model
navigation, and asynchronous save/reload. Large fixtures are each 1 MiB.
Correctness checks have no performance thresholds; saving polls for the expected
snapshot with a two-second deadline rather than waiting a fixed delay.

Only a uniquely named `NSPasteboard` and a unique history directory under the
supplied scratch directory are used. The general pasteboard and real clipboard
history are never accessed. History limit, ignored apps, and pause state are
overridden in the volatile argument domain and restored afterward; persistent
preferences are not changed. Scratch histories remain available for inspection.
These fixtures cover strings only: the injected history URL does not relocate
image/RTF attachments, which still use Orbit's Clips directory. Attachment tests
must isolate that directory separately before using this runner.
Repeat the same command three times to check repeatability.

# OCR regression

```sh
bash tools/regressions/run-ocr-tests.sh /tmp/orbit-ocr-tests
```

The standalone runner compiles the production OCR source without launching Orbit.
Each error case runs in its own process and replaces only Vision's `perform`
method: callback error plus thrown error, callback error alone, thrown error alone,
and a successful callback followed by a thrown error. It checks error identity,
request settings, background execution, and real recognition after a failure.
Real Vision checks cover English line order, Korean, a blank image, and concurrent
requests. Images are generated locally; no clipboard, network or installed app
state is used. A continuation trap makes the runner exit unsuccessfully.

# Capture reference regression

Build the Debug app, then run the native capture-reference tests:

```sh
xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Debug \
  -derivedDataPath /tmp/orbit-reference-build CODE_SIGNING_ALLOWED=NO build
bash tools/regressions/run-capture-reference-tests.sh \
  /tmp/orbit-reference-build/Build/Products/Debug /tmp/orbit-reference-tests
```

The runner imports the app's Debug module without starting its app delegate.
It uses a generated image and temporary files, restores the clipboard, and
intercepts translation requests locally. A logged-in macOS desktop is required.
Coverage includes preview → pin → unpin, independent references, opacity bounds,
control-bar placement and Escape recovery, real Vision OCR, translation input and
clipboard preservation, recognition failure, and closing during recognition.
`--interactive` on the compiled runner opens a writing desk and the real capture
preview for UI checks. The controls' mouse-event flags are checked automatically;
physical click delivery to another app, multiple displays and fullscreen Spaces
need an interactive check.

# Notch recording regression

Build the Debug app (including Swift type checking), then run the native regression:

```sh
xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Debug \
  -derivedDataPath /tmp/orbit-notch-build CODE_SIGNING_ALLOWED=NO build
bash tools/regressions/run-notch-recording-tests.sh \
  /tmp/orbit-notch-build/Build/Products/Debug /tmp/orbit-notch-results
```

The runner imports the app's Debug module/dylib and starts only its notch, recorder
and keep-awake services in a separate process; it does not launch the app delegate
or alter the installed app's preferences. A logged-in macOS desktop and Screen
Recording permission are required (exit 2 means unavailable, not a pass).
It records a blank window with microphone and system audio output disabled,
keeps videos in the result directory, and releases its own power assertions.
It never enables closed-lid mode or uploads anything. Append `--screenshots`
for window-only UI evidence. Screenshot failures fail that run separately from
the behavioral assertions; ScreenCaptureKit can return error -3811 even before
recording starts. Omit the flag for repeatable behavioral regression runs.

`debugRoom` controls only the menu-bar space measurement to reproduce a crowded
bar without rearranging the user's status items. It uses the real asynchronous
measurement result path. A suspended older measurement completes after a newer
one to verify that cancellation prevents stale results from overwriting it.
The real SwiftUI view, recording start/stop/discard and IOKit power assertions
are exercised. Space stays crowded during `finishing` and is freed only at `idle`,
so restoration must include a measurement after recording teardown, not just when
`isRecording` becomes false. Coverage also includes recording priority, preserving
the original session, deadline and assertion IDs, switching awake off during
recording, starting with awake off, and the timer fallback. Real menu-bar layout timing across displays
still needs a manual check. The existing debug animation speed is accelerated
for stable screenshots; this does not test the spring animation itself.

# Issues #14–#21: validation and publication handoff

## Baseline and ownership

Read all eight issues and their comment state. #14–#19 used the requested public
API; #20/#21 and their empty timelines used GitHub's web issue data after API
rate limiting. Current job worktree started clean at remote main
`996f0a5269b1d3a46398a66b078d1d17f9775011` (1.4.6, build 17, PR #43).
Inspected prior local attempts `8177e47` and `26c86af`; reworked their fixes in
this isolated job worktree. Do not publish those branches as additional PRs.
`git ls-remote` still showed that main SHA, no work branches for these attempts,
and no v1.4.6/v1.4.7 tags. GitHub's PR list showed **0 open PRs**; latest release
redirected to **v1.4.5**. Source version prepared here: **1.4.7 (18)**, not a release.

| Issue | Change and coverage |
| --- | --- |
| #14 | Reserve existing split sets, including orphan/case-equivalent volumes. Unique staging and exclusive atomic rename refuse late whole-file/part collisions. Roll back only owned parts and retain the complete archive on split failure. Tests preserve old volumes and round-trip both backups, exercise late collisions, cancellation, the 9999-part limit and optional UI-sized 25 MB splitting. Four-digit volumes are recognized by the reader and app. |
| #15 | Reject normalized/Windows-transformed collisions before writing, including directory, case, punctuation and NFC collisions. Explicit error instead of merging directories or losing data. Test opt-out preserving both contents and disappearing-source failure; source/read/write failures no longer silently succeed. |
| #16 | All five bare currency symbols (also with whitespace) safely return no answer. |
| #17 | Filter the metadata directory, not prefix-only files or an ordinary file named exactly `__MACOSX`; test all three. |
| #18 | Support leading signs; reject incomplete/non-finite amounts. Test negative/positive temperature results and signed amounts. |
| #19 | Preserve 30-/45-minute and sub-hour offsets, whole hours and zero; Korean translations included. |
| #20 | Retain PR #33's existing theme-change window sizing fix. Remove the independent horizontal metadata height cap for small covers. Fitting-size/hover/anchor tests added. **Original Stage Manager photo is not independently reproduced or visually verified; do not claim this issue fully verified/closed yet.** |
| #21 | Claim a per-account OS lock before services/status items. Bounded acknowledged/idempotent document/window handoff, owner-exit takeover and explicit timeout. Queue late document events while handoff runs; ignore handoffs before service readiness/during shutdown. Language restart waits for exit/lock release. Debug test checks conflicting lock descriptors; real process/GUI checks remain required. |

No new dependencies/services. Name validation is O(entries), splitting uses a
bounded 4 MiB buffer and at most 9999 volumes. Lock descriptors are CLOEXEC,
NOFOLLOW, ownership/type/permissions checked, including the containing directory.
Never unlink the lock. Handoff retries for five seconds and remembers 256 IDs.
Distributed notifications use the existing local-session convention, not an
authenticated IPC/security boundary against malicious same-user processes.

## Checks actually observed here (Linux)

- `python3 -u tools/i18n.py`: passed (after an initial 120-second timeout,
  rerun with sufficient local budget); 316 settings entries, 61 actions,
  4208 catalog keys, 2800 Korean translations.
- `python3 tools/regressions/check-metadata.py`: passed (JSON/plists, 11
  translations/format arguments, version agreement, Xcode references/delimiters,
  relaunch/runner shell syntax). **Not Swift compilation.**
- `git diff --check`: passed.
- Archive runner: exit 2, explicit macOS-required diagnostic; **no Swift tests ran**.
- `swiftc`/Swift unavailable. `xcodegen` and `xcodebuild`: command not found
  (exit 127). **No successful native build, signing or GUI check.**

## Native acceptance gates (not performed here)

```sh
python3 tools/regressions/check-metadata.py
bash tools/regressions/run-archive-tests.sh
bash tools/regressions/run-archive-tests.sh --large
xcodegen generate
python3 tools/i18n.py
xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Debug \
  -derivedDataPath build-issues -disableAutomaticPackageResolution \
  ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build
git diff --check
```

In a logged-in disposable macOS account, launch the Debug app, then:

```sh
swift -e 'import Foundation; DistributedNotificationCenter.default().post(name: .init("com.lyu.orbit.debug"), object: "issues-selftest")'
```

Require a fresh `issues-selftest: 0 failed` in `~/Library/Logs/Orbit/perf.log`.
Run the existing `widget-themes` hook too. Manually test English/Korean launcher,
Asia/Seoul `india time`, Stage Manager on/off, all themes, smallest cover/largest
text, hover, display edges/Spaces and the reported title/artist; record screenshots
and style/OS settings. Fitting-size tests alone do not prove complete glyphs.
Repeated Finder/Dock, `open -n`, direct executable, app-copy and simultaneous
launches must give one owner/status-item set and deliver every document request.
Test owner exit during handoff, crash/relaunch, hung owner (timeout, no duplicate
services), language restart, closed-lid restoration and updater restart.

## Publication gates for Metamong

No commits, pushes, PRs, merges, releases or Discord messages were made here.
Current protection/rules API verification was rate limited; previous attempt
reported `main.protected: false`. No `.github` workflows exist in this checkout.
**Do not infer green CI or effective protection. Do not merge until verified.**
Metamong must recheck remote PRs/versions, active branch protection and required
green native checks, obtain independent review and separate merge execution
approval, and never self-approve or push main/an existing PR head. Every new
commit must include `Co-authored-by: 유성윤 <94370559+3x-haust@users.noreply.github.com>`.
README requires signed, not notarized releases for Apple silicon and Intel;
Release also requires the verified Tavi helper and real signing identity.
Preserve source/tag/version/artifact identity, checksums, clean-install and both
architecture startup evidence. Report actual PR URL, merge SHA and published
version/assets to the original Discord channel only after remote confirmation.
