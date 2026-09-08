# Design QA — desktop UX study

**Final result: blocked**

The owner approved the library and recording-panel bases. The complete prototype handoff is blocked on native interaction and remaining screen verification. The inspected panel render has no remaining actionable layout finding; this does not constitute a pass for the entire study.

## Findings

- **P1 — Required native interaction evidence is unavailable.** Native computer use returns `Sky Computer Use native pipe closed before response`; resetting its session and reacquiring the prototype did not restore access. The earlier library capture succeeded. Dragging, focus preservation, hiding/revealing, the full start/mute/finish walkthrough, fullscreen and the menu/settings screens remain unverified. Restore native computer use and complete the same synthetic scenarios before a full prototype handoff.
- **P2 — Narrow/dark library coverage remains incomplete.** SwiftUI ImageRenderer omits this library's AppKit-backed scrolling content and inserts unsupported-view markers for menus and its slider. Those outputs were rejected and moved into ignored `.build/unsupported-library-renders/`. Keep the approved live library screenshot as evidence and capture narrow, long-title and dark states from the actual window when native automation is available. Do not redesign the application around a renderer limitation.
- **P3 — Panel material and glow differ slightly from the generated artwork.** The native component uses a flat dark surface, SF Symbols, native color rendering and a restrained pulse. The selected image has soft shading and a broader glow. The control order, compact proportions, timer placement and semantic state colors are preserved. These surface differences are follow-up polish; the selected image remains the visual source of truth.

## Source and implementation artifacts

| Surface | Source visual truth | Rendered implementation | State / dimensions |
| --- | --- | --- | --- |
| Library, original direction | `designs/library-option-1-original.png` | `evidence/library-first-pass.png` | Ready call, light theme; source 1487 × 1058 pixels; native window 1216 × 864 points; CUA output 1081 × 768 pixels |
| Library, owner-approved type revision | Owner's request for ordinary standard macOS fonts, then approval of `evidence/library-standard-fonts.png` | `evidence/library-standard-fonts.png` | Same ready sample; 1216 × 864-point native window, CUA output 1081 × 768 pixels |
| Recording panel | `designs/recording-panel-with-timer.png` | `evidence/rendered/panel-recording.png` | Active synthetic recording at 04:12; source 1774 × 886 pixels with surrounding canvas; native component 192 × 44 points rendered at 4× to 768 × 176 pixels |
| Panel states | Approved compact layout plus the recording contract | `evidence/rendered/panel-*.png` | Muted, unavailable, pending, saving, start, interruption, save failure and uncertain stop; each 768 × 176 pixels |

The generated panel source includes a light presentation canvas and magnification; the native render contains only the component. Comparisons align the component regions and their relative geometry, not the surrounding canvas. No claim of pixel-for-pixel density equivalence is made. The library source and native captures have effectively the same frame aspect ratio; the native screenshot was downsampled by the capture tool. Browser CSS dimensions and deviceScaleFactor do not apply to this native prototype.

## Comparison history

1. The original selected library image and the first native screenshot were opened together in one comparison input. The sixth visible turn was clipped earlier in the implementation (**P2**), and menu glyphs were undersized. Turn spacing and the menu glyph frames were corrected. The owner then explicitly replaced the large typography with standard macOS sizes.
2. The revised native library was captured and shown. It uses semantic system text styles and tighter supporting spacing. The owner explicitly approved that revision as the base. Original image typography and old window-title placement are superseded by this approval.
3. The approved timer-panel image and `evidence/panel-first-render.png` were opened together. The initial renderer used a relatively heavy timer, a filled microphone glyph, a narrower meter and a brighter red (**P2**). The implementation was changed to a smaller light monospaced timer, an outline microphone, revised control/meter proportions and a darker red Finish button.
4. The approved timer image and the revised `evidence/rendered/panel-recording.png` were opened together again. The muted, unavailable, pending and saving renders were inspected in that same comparison input. The remaining start/interruption/recovery renders were then opened. Controls fit their component bounds; the time sits above the single meter; microphone states remain distinct; inactive saving controls and levels are visible. No additional P0/P1/P2 layout issue was found in these component renders.

The panel comparison is itself a focused component comparison: at 4×, each glyph, timer and level segment is readable. The live library capture and accessibility text supplied readable content and control names. Additional focused captures of the unverified native states remain part of the blocker above.

## Required fidelity surfaces

- **Fonts and typography:** Approved library uses system body/headline 13 points, callout 12, subheadline 11 and title2 17 on the verified local macOS font scale. The compact panel uses small light monospaced digits. Cyrillic sample text and metadata remained readable in the live library capture. Narrow/dark native typography still needs live capture.
- **Spacing and layout rhythm:** The library retains its date-grouped sidebar, paragraph reader and bottom player. The panel is 192 × 44 points with microphone, central timer/level stack, Finish and Hide. Rendered states do not clip. Narrow/fullscreen behavior is unverified.
- **Colors and tokens:** The library follows native appearance colors. The panel explicitly uses dark appearance regardless of the library theme, with cyan activity, red Finish and gray inactive states. The inspected renders confirm the dark surface; window-level appearance switching still needs native verification.
- **Image quality and assets:** App icons come from installed applications through NSWorkspace; controls use SF Symbols. No fabricated logos or handmade icon artwork replace native assets. The selected ImageGen outputs and their rejected alternatives are preserved. Offscreen panel renders are sharp 4× PNGs.
- **Copy and content:** All transcript text is synthetic Russian; product controls use English. The library visibly says it is a design study. The panel's only normal visible text is elapsed time. Source names and explanations live in tooltips/accessibility labels and menu status. Speaker and processing semantics remain provisional until their own decisions are resolved.

## Implementation checklist

- [x] Preserve the owner-selected source images and the standard-font native screenshot.
- [x] Build the isolated native prototype with Swift 6.
- [x] Render and inspect the compact panel states from actual SwiftUI components.
- [x] Distinguish local-save uncertainty from unconfirmed stopping in the fixture explanations.
- [ ] Restore native UI access and confirm that the running app uses the latest build.
- [ ] Verify panel dragging, nonactivation, hide/reveal and the full action sequence.
- [ ] Capture and review menu-bar idle/recording/processing layouts and setup/settings.
- [ ] Capture narrow, long-title and dark library states from the actual native window.
- [ ] Complete keyboard/VoiceOver and reduced-motion checks relevant to the design.
- [ ] Obtain overall owner agreement before resolving the design decision.

No capture, physical microphone, global gesture, ASR, network or durable-storage acceptance is claimed. No production code or build target is changed.
