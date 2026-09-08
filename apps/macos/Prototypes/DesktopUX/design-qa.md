# Design QA — floating desktop library

**Final result: passed for the local prototype**

This review covers the retained prototype for [design decision #67](https://github.com/apshenichniy/trigo/issues/67), including the owner's requested floating sidebar and Liquid Glass revision. The full native run passed all nine scenarios with zero failures or skips. Final light/dark, narrow, resized and hidden-sidebar captures were inspected at readable scale; no unresolved P0, P1 or P2 visual finding remains in the reviewed scope. The owner accepted the prototype overall and requested its preservation as a workbench, then clarified that further invariant and intermediate/recovery-state UI refinement follows the first working release and hands-on use. The accepted baseline and delegated #68 defaults are sufficient for the implementation handoff.

## Retention and Quit correction — 2026-09-08

The owner's report that Command-Q could not close the workbench exposed a fixture boundary missing from the earlier suite. The product Quit handler correctly refused to leave unresolved stop/save states, but a deliberately held Saving fixture never supplies completion. That made the workbench itself impossible to quit normally while inspecting those states.

The focused native reproducer passed in Idle and failed in held Saving and Recovery. Since changing only the fixture isolated the blocker, additional instrumentation was unnecessary. Ordinary Command-Q / Quit now exits the workbench. **Prototype → Simulate Trigo Quit…** explicitly exercises the existing product guards and recording confirmation. The eight regression scenarios passed, including waiting for finalization, unresolved recovery, cancellation, Finish and quit, and starting retirement. [Quit verification](evidence/quit-verification.json) retains the failing and passing run identities, source hashes and scope.

The library, recording-panel appearance and synthetic data model are unchanged by this correction. Earlier visual evidence remains the accepted layout baseline; the newer focused suite verifies the changed Quit route. The old running preview was closed, and the rebuilt workbench was left closed for the owner.

## Findings and corrections

- **P2, corrected — Window controls and custom toolbar did not share a baseline.** The first glass capture placed SwiftUI toolbar controls below the native traffic lights. The library now uses an actual `NSToolbar` in unified compact style. The sidebar action is a navigational item on the leading side; macOS positions the traffic lights, title and controls. The native test checks both vertical alignment and leading placement. Header and transcript text now share the same horizontal inset.
- **P2, corrected — Divider movement varied with pointer events.** A full run moved the divider only 46.5 points for a 70-point drag, despite earlier focused checks passing. The gesture now uses the stable library coordinate space rather than the moving divider's local space. The final regression passed an actual 70-point drag within 3 points, then verified width restoration after hide/show within 1 point.
- **P2, corrected — The initial native toolbar menu omitted Settings.** The complete `NSMenu` is now constructed before assigning it to `NSMenuToolbarItem`. The library-menu route to General, Connection and Diagnostics passed in the focused native rerun.
- **P3 — Recording-strip surface polish.** The approved compact strip retains its flat dark material and restrained pulse; the generated image has broader glow. Its dimensions, control order, timer position and state semantics match the approved base. This library revision does not change that selected panel appearance.

## Visual sources and captures

The owner attached `codex-clipboard-e137e87c-c4eb-48a1-b5f2-2ca68241bf70.png` in the design conversation on 2026-09-08. The local source is `/var/folders/g3/ybh9tphn64v89zj_bv2322zh0000gn/T/codex-clipboard-e137e87c-c4eb-48a1-b5f2-2ca68241bf70.png`. It is a 2740 × 1776-pixel Telegram screenshot. Its floating navigation surfaces and control treatment are the reference; its private chat content, avatars, folder rail and messaging actions are not part of the Trigo brief. The private image is not copied into Git.

The earlier owner-approved library capture, `evidence/library-standard-fonts.png`, remains the system-typography and information-architecture reference. The compact-strip reference remains `designs/recording-panel-with-timer.png`.

| Current native capture                               | Viewport / density                        | State                                           |
| ---------------------------------------------------- | ----------------------------------------- | ----------------------------------------------- |
| `evidence/native/library-light.png`                  | 1216 × 864 points; 2432 × 1728 pixels; 2× | Ready Chrome call, light, default sidebar       |
| `evidence/native/library-narrow-long-title-dark.png` | 820 × 770 points; 1640 × 1540 pixels; 2×  | Dark, long source title, narrow window          |
| `evidence/native/library-sidebar-resized.png`        | 1216 × 864 points; 2×                     | Sidebar narrowed by pointer drag                |
| `evidence/native/library-sidebar-hidden.png`         | 1216 × 864 points; 2×                     | Reader expanded after hiding the sidebar        |
| `evidence/native/library-narrow-scrolled.png`        | 820 × 770 points; 2×                      | Last passage selected; player remains reachable |
| `evidence/native/library-new-call-processing.png`    | 1216 × 864 points; 2×                     | Finished sample call appears in Today           |
| `evidence/native/settings-connection.png`            | 550 × 432 points; 1100 × 864 pixels; 2×   | Sample replacement-token flow completed         |
| `evidence/native/panel-recording-native.png`         | 192 × 44 points; 384 × 88 pixels; 2×      | Live native compact recording strip             |

Native captures contain the actual app windows/components. Browser CSS dimensions and deviceScaleFactor do not apply. The Telegram reference has a different viewport and content model, so the comparison evaluates the requested floating-surface composition and native-control treatment, not pixel-identical chat content. System typography is compared with the earlier approved Trigo capture. No screenshot was edited to manufacture a comparison result.

## Comparison history

1. The original library image and first native capture were opened together. Early passage clipping and small menu glyphs were corrected. The owner then requested standard macOS typography and approved `evidence/library-standard-fonts.png`.
2. The timer-strip source and its native component renders were compared together. The timer weight, microphone outline, meter proportions and red Finish color were corrected. Remaining material/glow differences were classified as P3.
3. The owner's Telegram reference and the first live glass library capture were opened in the same comparison input, alongside the narrow dark and hidden-sidebar states. The inset sidebar, plain transcript and floating player fit the brief. The misaligned custom top toolbar was a P2 finding.
4. After switching to `NSToolbar`, the reference and revised library capture were opened together again. Navigational placement and toolbar alignment were corrected; the menu/settings interaction passed after complete-menu assignment. The live connection screen was also inspected at readable scale.
5. After the divider correction, the owner reference, final light library, narrow dark layout and resized sidebar were opened in the same comparison input. Floating surfaces and native controls follow the requested composition; the toolbar alignment, wrapping and insets are coherent. Hidden-sidebar, narrow-scrolled, new-call processing, connection and live panel captures were then inspected. The last passage and player remain reachable after scrolling; processing rows fit their status line. No additional P0/P1/P2 visual defect was found.
6. Four reading-state captures were initially obscured by the separate Design Controls window. The test now brings the library forward and asserts each heading is hittable. The focused rerun passed, and the unobstructed processing, no-speech, offline and failed states were inspected. Their messages, Retry actions, status rows and player fit the intended layout.

The full-window captures are large enough to judge system type, insets and individual controls. The compact-strip screenshot is itself a focused component capture; its timer, microphone, meter and Finish glyph are legible at native 2×. No further crop is needed for those surfaces.

## Required fidelity surfaces

- **Fonts and typography:** Semantic macOS system styles preserve the approved 13-point body, 12-point supporting text and 17-point detail title. The sidebar headings and native toolbar establish hierarchy. Long titles wrap in the reader and have full hover/accessibility text in the single-line list. Cyrillic passages remain readable. The panel keeps its small monospaced timer.
- **Spacing and layout rhythm:** The sidebar is inset from the window, with 22-point corners and a draggable gap. The player floats with matching corner treatment. The native toolbar aligns window and navigation controls. Non-ready call rows use 74 points for their third status line; Ready rows use 56. Narrow content scrolls while the player stays visible.
- **Colors and materials:** Native `glassEffect(.regular)` is reserved for navigation and controls. The transcript has a plain content background, following Apple's [material guidance](https://developer.apple.com/design/human-interface-guidelines/materials). The library follows system appearance and accent color. The recording strip remains dark, with cyan activity, red Finish and gray inactive states.
- **Images and assets:** Source-application icons come from `NSWorkspace`; control glyphs come from SF Symbols. There are no fabricated logos, copied Telegram avatars or replacement bitmap controls. Native screenshots are sharp 2× PNGs.
- **Copy and content:** Transcript and state data are synthetic. The library identifies itself as a design study. The recording strip's normal visible text is elapsed time; source identity and explanations are available in help, accessibility text and menu status. The connection fixture uses `example.invalid` and saves no credentials.

## Native verification

**Passed:** `run-20260908-113150-28307`, 2026-09-08, macOS 26.6.2 arm64. All 9 tests passed; 0 failed; 0 skipped. Xcode reported 228.459 seconds. The prior run was interrupted at the owner's request for a call; this run resumed with the same source. [Verification metadata](evidence/native/verification.json) records the command, timestamps, source hashes and capture hashes. The supplemental `run-20260908-114414-4233` passed the settings/reading-state scenario after a test-only capture correction. All application sources are identical to the full passing run; the metadata retains both test-source snapshots and identifies the four replaced captures.

The independent XcodeGen project uses public XCUITest APIs. Computer Use's earlier helper failure did not prevent this route from operating the app. macOS required local authentication twice; both requests were completed by the owner. Authentication timeouts are retained as failed environment runs, never treated as passes.

The nine scenarios cover:

1. Native library, call selection, Design Controls, panel actions and toolbar placement.
2. Description accessibility audit for the library and panel.
3. Keyboard commands for Design Controls, Settings and window closing.
4. Light/dark, narrow/long-title, export, fullscreen, minimize/reopen and Dock activation policy.
5. Cross-process text focus before and after panel clicks, including another application's fullscreen window.
6. Sidebar resizing/hide/show, passage selection, silent playback, seeking, scrolling and recording details.
7. Start/mute/unmute, 192 × 44-point panel, dragging/hide/reveal, Finish and background-processing menus.
8. Unavailable and pending microphone, saving, save-failure retry, uncertain stop, interruption and cancellation.
9. General/Connection/Diagnostics settings and processing/no-speech/offline/failed reading states.

The accessibility audit excludes only an empty virtual Touch Bar with no controls on this Mac. Actual panel labels and enabled states are asserted separately. Focus checks send a real pointer event anchored to the foreground fixture; clicking a background XCUIElement directly would activate that app before delivering the event.

Raw xcresult bundles, automatic screen recordings and complete device metadata remain in ignored `.build/ui-tests/`. Curated artifacts contain only named prototype captures, scoped accessibility descriptions and verification/source hashes.

## Limits and acceptance boundary

This is local prototype acceptance. Real capture, microphone input, global gestures, ASR, server requests, credentials, sync and durable storage are simulated or absent. Spoken VoiceOver output was not exercised; the automated check covers descriptions and the explicitly asserted control states. The macOS 15 fallback compiles behind availability checks but was not run on a macOS 15 host.

The owner-selected recording contract remains unchanged. The later [#67 resolution](https://github.com/apshenichniy/trigo/issues/67#issuecomment-5583747807) records overall owner acceptance and retention; [#68](https://github.com/apshenichniy/trigo/issues/68#issuecomment-5583749276) records the delegated v1 defaults. This report remains local prototype evidence, not acceptance of production capture, ASR or persistence.

## Checklist

- [x] Inspect the owner reference and native implementation in the same comparison input.
- [x] Use native Liquid Glass, system toolbar controls, menus, sliders and SF Symbols.
- [x] Correct the toolbar alignment and verify its Settings route.
- [x] Preserve the earlier selected typography and recording strip.
- [x] Pass the complete native suite after the divider correction.
- [x] Review the final corrected screenshots and record their verification hashes.
