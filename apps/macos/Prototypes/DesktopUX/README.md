# Disposable desktop UX study

This prototype answers the visual question in [Choose the library, menu-bar, and recording-panel mockups](https://github.com/apshenichniy/trigo/issues/67). It is throwaway code on `codex/prototype-desktop-library`, outside the production application targets. Do not merge or promote it into the application.

## Owner-selected bases — 2026-09-08

The owner selected the first library concept, then requested ordinary standard macOS fonts and approved the resulting native view. Preserve the date-grouped call list, open transcript paragraphs and bottom player, using semantic system type styles: 13-point body text, 12-point secondary metadata and a 17-point detail title on the current macOS installation.

![Approved native library](evidence/library-standard-fonts.png)

The owner selected the first compact recording-panel concept and approved its revision with a small monospaced elapsed timer above the application-audio level indicator. The panel is a tiny draggable landscape strip, permanently dark even when the library or system is light. Its visible contents are the microphone control, one application-audio scale, the timer, Finish and Hide. Application identity, explanations and reasons belong in tooltips and the menu-bar status. The timer is the explicit exception to the request for icon-only controls.

![Approved recording-panel design](designs/recording-panel-with-timer.png)

The native layout uses a 192 × 44-point panel. The [ImageGen revision prompt](designs/recording-panel-with-timer.prompt.md) and both full ideation sets are preserved in `designs/`. The images are magnified design samples, not measurements or capture evidence.

These are selected bases. The complete design decision remains open pending menu/settings review, remaining states and the final walkthrough.

On 2026-09-08, the owner delegated reasonable first-version choices to the agent and requested questions only for substantial unresolved product decisions. Remaining menu/settings choices are recorded in the design ticket as agent-selected defaults under that mandate. They are not additional owner-reviewed screenshots. The existing recording/window contract and the verification requirements remain binding.

## Run the native preview

Requires macOS 15 or later and a Swift 6 toolchain.

```bash
bash apps/macos/Prototypes/DesktopUX/run.sh
```

The script builds `Trigo UX Prototype.app` inside this directory's ignored `.build/` folder. The prototype has the distinct bundle identifier `io.github.apshenichniy.trigo.prototype.desktopux`; it does not use Trigo Dev or Personal data. Quit an already-running preview before reopening a rebuilt version.

Open **Prototype → Design Controls…** or press **Command–D** to select scenarios. The controls can show recording, starting, saving, interruption, uncertain stopping and save failure, and switch the selected call between reading states. They also expose narrow-window, long-title, appearance and reduced-motion fixtures. Settings are a separate window.

```bash
# Compile without opening a window.
bash apps/macos/Prototypes/DesktopUX/run.sh --build-only

# Render the actual SwiftUI panel components to PNG files without desktop automation.
bash apps/macos/Prototypes/DesktopUX/run.sh --render-fixtures
```

## Scope and evidence

All calls, transcript passages, audio levels, playback and transitions are synthetic and live in memory. The sample player advances a silent timeline. Settings do not change login behavior, connect to a server, request permissions or register a global shortcut. The approved double Left Control gesture remains part of the [recording and desktop window contract](https://github.com/apshenichniy/trigo/issues/66#issuecomment-5577008210), not a capability of this preview.

The library was opened and captured through native computer use, and the owner approved the standard-font revision. The panel and its fixture states were rendered directly from the SwiftUI component. Compilation succeeds. The [QA record](design-qa.md) separates these facts from the remaining native interaction checks.

Native computer use later failed with `Sky Computer Use native pipe closed before response`, including after a session reset. Panel dragging, focus preservation, menus, fullscreen, the complete transition walkthrough and the updated running binary have not been verified through that tool. Offscreen rendering does not prove any of those behaviors. SwiftUI ImageRenderer also cannot render this library's AppKit-backed menus, slider and scrolling contents faithfully; those partial renders are not acceptance evidence.

## Review fixtures still awaiting agreement

- Menu-bar layout and action order in idle, recording and processing states.
- Setup/settings presentation, separated from everyday reading.
- Starting, pending microphone changes, muted/unavailable microphone, saving and failure states in the selected compact style.
- Narrow windows, long source names, light/dark library appearance and native interaction walkthrough.

The panel preserves one application-audio scale and microphone-only activity feedback. A muted microphone is crossed out; an unavailable microphone is dimmed with a reason and badge; an unapplied change has a distinct circular-arrows symbol. Saving freezes the timer and deactivates the controls/levels. The renderer deliberately uses reduced motion. Actual microphone levels, mute acknowledgement, finalization, recovery and persistence still require production implementation and the later agent-run acceptance route.

The connection fixture offers Validate and Save with a sample replacement token, and Retry Saved Connection. It does not introduce a Disconnect operation. Validation, credential persistence, archive-identity checks and failed-update handling remain responsibilities of the existing connection contract; these fixture buttons only change in-memory sample status.

Speaker labels and reading-status examples are provisional visual fixtures. This study does not resolve [Specify library reading and truthful processing states](https://github.com/apshenichniy/trigo/issues/68), speaker continuity, or [Define the UX and transcription handoff for autonomous delivery](https://github.com/apshenichniy/trigo/issues/70).

## Accessibility notes

Icon controls have accessible names and hover help. Unavailable microphone reasons are also attached to the containing element, so the explanation is not limited to an enabled button. State distinctions use glyphs as well as color. Reduced motion suppresses the simulated microphone pulse; the elapsed time uses monospaced digits. These code and rendering properties have not yet been checked with VoiceOver or a full keyboard walkthrough.
