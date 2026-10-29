# Design research: a premium all-in-one macOS utility

**Scope:** Screenshot capture, clipboard history, launcher, window management, and drop shelf.  
**Research date:** October 28, 2026.  
**Target platform:** macOS 26, implemented primarily in SwiftUI.

## Executive recommendation

Build **one consistent interaction system, not one giant window**.

The strongest combination is:

- **Raycast’s command grammar:** search, selection, primary action, contextual actions.
- **CleanShot’s capture lifecycle:** capture first, then decide whether to copy, annotate, save, or keep.
- **Paste’s content recognition:** previews that make previously copied material recognizable.
- **Shottr’s precision:** reversible cropping, zooming, and keyboard adjustment.
- **Dropover’s context preservation:** a temporary place to put something without losing the current task.
- **Arc’s spatial continuity:** related states feel like transformations of the same object.
- **Linear’s restraint:** dense information with quiet navigation and consistent hierarchy.
- **Apple’s material hierarchy:** glass for controls and navigation, not indiscriminately behind everything.

**The product should feel like a coherent layer of macOS, not a dashboard containing five utilities.**

---

## 1. Evidence and measurement boundaries

I examined official product documentation, screenshots, design articles, release notes, public design galleries, and independent reviews. This was public-source research, not instrumented testing of installed native apps.

Three distinctions matter throughout:

- **Documented:** Explicitly stated by the product or Apple.
- **Observed:** Visible in inspected screenshots or video frames.
- **Proposed:** My recommended implementation, not an extracted competitor specification.

### What can and cannot be measured reliably

Most products do **not** publish their native panel dimensions, row heights, corner radii, blur parameters, or animation curves.

A 2,000-pixel-wide marketing image does not establish a 1,000-point window. It may include wallpaper, scaling, cropping, shadows, or compositing. Accordingly:

- I report useful screenshot proportions where available.
- I do not manufacture competitor point values from unknown image scaling.
- The final design system supplies concrete **point-based implementation targets**.

An unusually useful exception is <citation refs="L9O7N7A_zWPWRFwxg-IaV">Paste’s older official Dribbble UI kit, which explicitly labels typography and corner-radius tokens</citation>. Those values are historical reference material, not verified Paste 6 specifications.

### Version caveats

- <citation refs="CxXBPuzyYY6WllhDTlhwb,GgnUuck8qdWUkjD6d7RoP">Raycast v2 adopts Liquid Glass and a hybrid architecture; its older 2022 redesign is not a complete description of the current app.</citation>
- <citation refs="tY3xVGMhtF83ZwQ9wyatd">Paste 6 introduced its Liquid Glass redesign in September 2025.</citation>
- <citation refs="6a-wGJcRRdEnLgrfulzF8">Linear refreshed its interface again in March 2026.</citation>
- <citation refs="SJOYYaTJVOXxWxFxjSeQ7">Arc announces that its desktop apps will stop working on December 22, 2026.</citation> It remains a valuable historical design reference, but not a model for product continuity.

---

# 2. Product studies

## 2.1 Raycast: a stable grammar for many capabilities

### Layout

<citation refs="CxXBPuzyYY6WllhDTlhwb,8zkLVQ_K1PHhS1cLlpoWK">Current Raycast separates a compact launcher, expanded command interfaces, and a conventional Settings window. Interface size can be Default, Large, or Larger, independently of compact versus expanded presentation.</citation>

Observed patterns:

- Compact launcher: one wide rounded search surface.
- Leading identity/search affordance, large input, trailing secondary action and keycap.
- Expanded views preserve the search-first structure.
- Settings: inset sidebar, searchable configuration, grouped controls, and individual extension entries.
- In the inspected Settings image, the sidebar occupies approximately **28% of the window width**. This is an image proportion, not a fixed layout specification.

<citation refs="hTjBchayFhlXi-aMuN3zA">Raycast’s historical redesign explicitly consolidated navigation context, feedback, primary actions, and shortcut hints into a bottom action bar.</citation> The transferable idea is a predictable place for “what happens next.”

### Extensions and settings

<citation refs="7XUmFTK6M73MNn-Fmkz9M,WbX-XBHfLRVkIqYihr9Td">Extensions use constrained List, Grid, Detail, Form, and ActionPanel primitives. Search supports fuzzy matching, while secondary filtering can appear beside the search field. Extension guidance explicitly discourages flashing “No results” before asynchronous loading completes.</citation>

This consistency is more important than identical colors. Users learn the host once and transfer that knowledge to new extensions.

<citation refs="8zkLVQ_K1PHhS1cLlpoWK">Settings search with `⌘F` can find settings, extensions, and commands and jump to their configuration.</citation>

### Materials, typography, and motion

<citation refs="GgnUuck8qdWUkjD6d7RoP">Raycast v2 combines native window effects with transparent WebViews and native overlay windows. Its engineering discussion specifically addresses blank frames, stale content, and stuttering during compact-to-expanded resizing.</citation>

Observed visual character:

- Translucent outer surface.
- Fine light edge and broad rounded corners.
- Neutral hierarchy with color concentrated in app identities and meaningful states.
- System-like typography, but no verified current font-size or radius specification.

**Premium lesson:** Rendering continuity is part of visual design. A beautiful panel that flashes empty during expansion feels cheaper than a simpler panel that is always ready.

### Keyboard-first behavior

<citation refs="VHrsRQmC082OeZ5mooMbP,lnaKfak2y0kq9V3WFu5pH,8zkLVQ_K1PHhS1cLlpoWK">

- `⌘K`: contextual Action Panel.
- Typing inside it filters actions.
- In lists/grids/details, `Return` invokes the primary action and `⌘Return` the secondary.
- Forms deliberately use `⌘Return` for primary submission.
- `Esc` closes the action panel or returns from a submenu.
- Main navigation can unwind toward root; an alternative setting closes immediately and resets to root for next time.

</citation>

The Mac Settings documentation identifies `⌥Space` as the default invocation shortcut, while another shortcuts page differs. Do not assume every installation uses `⌘Space`.

### Onboarding and pain points

<citation refs="v5kTyqxqidi7pfI6XBgA9">Raycast’s quickstart teaches tasks progressively: search, actions, Quicklinks, shortcuts, then extensions.</citation>

Reported friction includes breadth becoming overwhelming and individual workflows feeling less polished. <citation refs="GgnUuck8qdWUkjD6d7RoP">The vendor’s May 2026 technical discussion also acknowledged higher typical memory consumption in v2 and cold-window tradeoffs.</citation> These are historical vendor observations, not a benchmark of the current build.

**Borrow:** The interaction grammar, shortcut teaching, searchable settings, and consistent extension components.  
**Avoid:** Exposing the entire feature inventory on first launch.

---

## 2.2 CleanShot X: turn a capture into a usable object

### Three distinct surfaces

CleanShot’s strongest design decision is separating:

1. **Capture selection:** Choose what to capture.
2. **Quick Access thumbnail:** Decide what to do with the result.
3. **Pinned screenshot:** Keep a reference visible.

<citation refs="cq7ctKngZFyq6AQH1C3U6">Its capture interface exposes Area, Fullscreen, Window, Scrolling, Timer, OCR, and Recording, alongside dimensions and aspect-ratio controls.</citation>

Observed layout:

- Capture modes form a labeled horizontal group.
- Geometry controls occupy a separate adjacent group.
- Selected mode uses a brighter rounded tile.
- Labels beneath icons make occasional functions discoverable.

In the inspected **888 × 319-pixel image**, the mode group is approximately **540 × 60 image pixels**, with a separate **215 × 60** dimensions group. These are source-image measurements, not native points.

### Quick Access

<citation refs="cq7ctKngZFyq6AQH1C3U6,RWxNw3xsdZ7kpFFpuKv7n">The corner thumbnail supports drag-and-drop, copy, save, annotation, configurable sizing and placement, auto-close behavior, and restoration of a recently closed overlay.</citation>

In inspected video frames:

- The screenshot dominates at rest.
- Active/hover state exposes actions over a darkened preview.
- Copy and Save retain text labels.
- Close, Pin, Annotate, and Upload occupy predictable corners.
- Multiple captures form a stack.
- The active capture has a blue outline.

**Premium lesson:** The result is immediately manipulable without forcing an editor or export dialog.

### Annotation editor

Observed structure:

- Top toolbar: image operations, drawing tools, object styling.
- Central canvas: overwhelmingly dominant.
- Bottom strip: zoom, output actions, and a conspicuous **Drag Me** affordance.
- Active annotation tool uses blue.
- Color selection is a compact popover, not a permanent inspector.

<citation refs="cq7ctKngZFyq6AQH1C3U6,RWxNw3xsdZ7kpFFpuKv7n">The editor supports light/dark appearance, editable project files, additional images, saved colors, and background/padding controls.</citation>

The important affordance is **Drag Me**: it makes an otherwise hidden cross-app capability explicit.

### Keyboard and motion

<citation refs="RWxNw3xsdZ7kpFFpuKv7n,r2m2jptQQYuzjn6e2aNfY">Quick Access documents `⌘C` Copy, `⌘S` Save, `⌘W` Close, `⌘U` Upload, and `⌘E` Annotate. Option-clicking Copy can preserve the image instead of closing it.</citation>

<citation refs="RWxNw3xsdZ7kpFFpuKv7n">Release notes document a subtle Quick Access animation.</citation> Exact durations and easing curves were not established.

### Pain points

<citation refs="4ojGBY9-7-_e-sX-lbCeb">A detailed reviewer found the default thumbnail too small to verify captures and initially missed size/auto-close preferences.</citation> That is a defaults and discoverability problem, not an absent feature.

<citation refs="BjaSkD9f-WRRn0SBkOynT,RWxNw3xsdZ7kpFFpuKv7n">A historical Sequoia-beta failure involved capture selection interfering with permission dialogs; CleanShot subsequently recorded a related fix.</citation>

**Borrow:** Immediate post-capture action, reversible dismissal, explicit dragging, separate pinned-reference mode.  
**Avoid:** Entering a click-intercepting capture overlay before permission readiness is resolved.

---

## 2.3 Paste: recognition-first clipboard retrieval

### Layout

<citation refs="IdUlOHeWDXLeRB4_KbC0G">Paste appears across the bottom of the active display, resizes vertically, and transitions into Compact Mode as its height decreases.</citation>

Observed structure:

- Top strip: search, Clipboard, named pinboards, add.
- Below: a horizontal timeline of content cards.
- Partially visible edge cards communicate continuation.
- Pinboards use both names and colored dots.
- Strong selection outline distinguishes the active card.

Card previews are content-specific:

- Text retains a readable excerpt.
- Links expose title, domain, and imagery.
- Code receives code-like treatment.
- Images remain visually dominant.
- Files expose recognizable type and name.
- Source app and copy time provide provenance.

In one official **1680 × 800 illustration**, fully visible cards are approximately **220 × 220 image pixels**, separated by roughly **30 image pixels**. This establishes square-card proportions, not native dimensions.

### Historical explicit tokens

<citation refs="L9O7N7A_zWPWRFwxg-IaV">The inspected older official Paste macOS UI kit labels these values:</citation>

- Corner radii: **5 pt small, 10 pt normal, 14 pt large**, plus a fully rounded treatment.
- Body: **13 pt / 16 pt line height**, regular.
- Callout: **12 / 15**, regular.
- Title 3: **15 / 20**, regular.
- Title 2: **17 / 22**, regular.
- Title 1: **22 / 26**, regular.
- Large title: **26 / 32**, regular.

These are useful evidence that premium Mac UI does not require oversized typography or heavy weights. They should **not** be presented as Paste 6’s current tokens.

### Materials and motion

<citation refs="tY3xVGMhtF83ZwQ9wyatd">Paste 6 describes a floating translucent Liquid Glass window, rounded items, vivid system-palette accents, and smoother transitions between sizes and previews.</citation>

Observed distinction:

- Outer shelf: strongly influenced by wallpaper.
- Inner cards: more opaque and readable.
- Preview/editor: visually related to the originating card.

That separation is important. The container can feel atmospheric while actual clipboard content remains stable.

### Keyboard behavior

<citation refs="Q-BzOKrluNrj92dFblQbr,xCW3M_K2axIga3cggJNSg">

- `⇧⌘V`: show/hide.
- Type immediately to search.
- `←` / `→`: navigate cards.
- `Return`: paste selected item.
- `⇧Return`: paste as plain text.
- `⌘1–9`: quick paste.
- `Space`: Quick Look.
- `⌘F`: focus search; repeat to expose filters.
- `Tab`: move between search and results.
- While actively searching, Return first moves into results; a subsequent Return pastes.

</citation>

The final distinction prevents accidental paste while the user is still constructing a search.

### Onboarding and pain points

<citation refs="UoOW7dDsYYT88TfEPdLqk">Direct Paste requests Accessibility at first use. Without it, Paste can still copy an item to the system clipboard for manual pasting.</citation> This is an excellent graceful-degradation pattern.

<citation refs="DY53Hg3LM6zJgG8KnAIiQ">App Store reviews report search failures/latency, preferences for denser text-only views, persistent visibility, and objections to subscriptions.</citation> Dates are incomplete for some extracted reviews; they do not establish current defect prevalence.

<citation refs="KPTs-TxUbG7X7rDYWnVqw">A clip can belong to one pinboard at a time.</citation> Visually, pinboards may resemble tags, but behavior is closer to folders.

**Borrow:** Content-sensitive previews, provenance, visible filter tokens, permission fallback.  
**Avoid:** A beautiful horizontal carousel as the only efficient way to search a large archive.

---

## 2.4 Shottr: precision and forgiveness

### Layout and workflow

<citation refs="e54hPnU39Hrq7yVMvRMus,jEbswbzZLworC1pRbXXos">Shottr recommends capturing the screen first, then selecting and cropping inside the editor. This freezes the moment and allows zooming and adjustment before committing.</citation>

Observed editor structure:

- Dense top toolbar.
- Export actions immediately accessible.
- Large canvas.
- Contextual properties float near the upper-right canvas area.
- Image dimensions and zoom remain visible.
- Tools can overflow behind an ellipsis in narrower windows.

This sacrifices some discoverability to maximize canvas space.

<citation refs="e54hPnU39Hrq7yVMvRMus">The first Area Capture can ask whether the user prefers the editor or a floating thumbnail, then remember that choice.</citation>

### Precision controls

<citation refs="jEbswbzZLworC1pRbXXos">

- Arrow keys move a selection by one image pixel.
- `⌘Arrow` resizes it.
- Shift increases the step to ten pixels.
- `⌘0` returns to 100%.
- `⌘2` zooms to the selection.
- `Q` and `W` inspect opposite selection corners.
- Return applies the crop.

</citation>

**Premium lesson:** Precision is not just a magnifier. It is the ability to correct an imperfect first action cheaply.

### Materials, typography, and motion

Observed:

- Quiet pale chrome and compact icon controls.
- Blue active-state accents.
- Small selection handles.
- A separate bottom action strip in the floating-thumbnail illustration.

Exact native geometry and typography were not established.

<citation refs="Qth4IG_wQFgzbZc-FNrRA">Shottr advertises 17 ms capture and approximately 165 ms to display a screenshot.</citation> These are vendor performance claims, not independently measured results or animation durations.

### Keyboard and pain points

<citation refs="e54hPnU39Hrq7yVMvRMus">The current guide documents `⌘⇧C` for image copying, `⌘S` for saving, and automatic editor hiding after copy/save, with Reopen restoring the retained image.</citation>

Do not assume Escape is universally side-effect-free: historical documentation and reviews describe different behaviors across states and versions.

<citation refs="Kxyp839WBYLJmXZli2ljs">Known limitations include scrolling-capture conflicts and the need to rasterize appended images before some pixel operations affect them.</citation>

<citation refs="7Dqhxga6vasUTGkQcUs2j">A hands-on reviewer also found some powerful controls difficult to discover and OCR feedback too fleeting.</citation>

**Borrow:** Capture-then-refine, pixel nudging, retained results, immediate export.  
**Avoid:** Important decisions hidden in disappearing notifications or unexplained icon-only controls.

---

## 2.5 Dropover: preserve context without stealing focus

### Layout

Observed compact shelf:

- Small rounded container.
- Grabber at top.
- Close and action controls in upper corners.
- Central file preview.
- Bottom title/count capsule.

Expanded detail stays associated with that same object, exposing grid/list views, selection, file metadata, and actions.

<citation refs="e5uOjiGJH9_qIPcAUj5Sx">Dropover 5.1 explicitly enlarged the shelf slightly, softened corners/shadows, and introduced glass-like depth on macOS 26. It also describes returning from detail to the previous state and position.</citation>

No authoritative shelf size in points was found. A release-note illustration depicts a nearly square shelf, approximately **190 × 195 image pixels** within an **800 × 402 frame**.

### Activation and focus

<citation refs="YIpO5bflwAKwGQ8zgdbPf,pBEqpcMYTmwHuD-cr-0Kg">Activation paths include shaking during a drag, holding a modifier, keyboard shortcuts, the menu bar, and optional notch-related interaction.</citation>

The more important behavior is <citation refs="YovaZZHoLSD88lZdkQ7rX">that showing a shelf does not take focus by default. Keyboard interaction requires activating the shelf, either by clicking or through shelf selection.</citation>

This prevents a helper surface from disrupting the task it is meant to support.

### Keyboard and motion

<citation refs="lVjx_mHAgbwFQwj2BtRtx">

- `⌥⇧Space`: new shelf.
- `⌥⇧A`: clipboard shelf.
- `⌥⇧S`: select a shelf.
- Active shelf: `⌘K` Command Bar, Space Quick Look, Return action menu, `⌘W` close.
- Keyboard shortcuts are configurable.
- The inspected official table does not establish a universal Escape-to-close behavior.

</citation>

<citation refs="YovaZZHoLSD88lZdkQ7rX,e5poHiTZz4i6l_ZzbBDVQ">Recent releases improve appearance/drop/detail animations, preview actions before execution, allow dragging away to cancel, and place completion feedback below the shelf rather than over its contents.</citation>

### Ownership and pain points

<citation refs="JWrSvfY6uCPHlyY8Or3Qd,TJWTkyBPtWWFIpeK9HEs-">Finder files placed on a shelf remain references. A pinned shelf is not a backup; source files can become unavailable.</citation>

<citation refs="_2SjmTBtQYRthloUP6aVo,DlyLF92e1De7uvW2rT8Kn">Historical user reports mention shake effort, shelf clutter, activation preferences, and overloaded action menus.</citation> Later releases address some adjacent concerns, so these are design risks rather than a current missing-feature list.

<citation refs="i1LpUmCXFfdYwwIOHklzM">Screenshot monitoring also depends on a screenshot reaching disk; macOS’s floating thumbnail can delay that.</citation>

**Borrow:** Cursor-local staging, non-focus-stealing appearance, spatially continuous expansion, explicit operation semantics.  
**Avoid:** Making shaking the only discoverable activation mechanism.

---

## 2.6 Arc: spatial identity, with conceptual costs

### Layout and visual character

<citation refs="EI1-rLfenw6vn6dgof5t5">Arc organizes Favorites, Pinned Tabs, folders, Spaces, and temporary tabs in a persistent sidebar, with optional hiding and per-Space color themes.</citation>

Observed design qualities:

- The sidebar is an organizing place, not merely navigation.
- A rounded content viewport sits within the surrounding browser frame.
- Color can establish workspace identity.
- The command bar appears as a distinct floating surface over the current page.
- Typography and controls remain comparatively quiet beside the colored shell.

Its historical theme controls support color intensity, gradients, and grain. That is a useful lesson in **bounded personalization**, not a reason to add gradients throughout a utility.

### Keyboard

<citation refs="dXDPJ14eCj_Efr-uUmHzx,ovaXMyqSHtnEWU_MB92sH">

- `⌘T`: command bar/new tab.
- `⌘L`: edit current URL.
- `⌘S`: show/hide sidebar.
- `⌘⇧C`: copy current URL.
- `⌃Tab`: recent-tab switching.
- The command bar exposes navigation, organization, settings, and actions.

</citation>

Arc cleverly attaches command discovery to an existing high-frequency shortcut instead of demanding that users learn a separate “power-user mode.”

### Premium quality and pain points

Premium interpretation:

- Coherent personality.
- Strong spatial grouping.
- Contextual rather than permanent controls.
- A feeling that transitions belong to the same workspace.

No reliable current spring or duration specification was found.

<citation refs="MnBDNBAPWGNTT13UdFVQY">Independent design criticism identifies undiscoverable drag-to-bookmark behavior and controls revealed only on hover.</citation>

More significantly, <citation refs="L385meBNePJbMQa8gBkyz">The Browser Company documented confusion and churn around synchronized tabs across windows, including accidental closing and divergent state.</citation>

**Borrow:** Spatial continuity and recognizable context.  
**Avoid:** Making familiar actions behave differently simply to create product identity.

---

## 2.7 Linear: premium through subtraction

### Layout and hierarchy

<citation refs="HZ9qlS_P3kr2C_YfpEkcK">Linear describes an inverted-L global structure: sidebar plus top navigation, with view-level controls and optional detail/property panels.</citation>

An inspected Inbox screenshot divides approximately into:

- Global sidebar: **12%**.
- Notification list: **19%**.
- Main detail: **54%**.
- Properties: **15%**.

These are screenshot proportions, not fixed widths.

<citation refs="6a-wGJcRRdEnLgrfulzF8">The 2026 refresh dims the sidebar, reduces icon size/count, removes colored team-icon backgrounds, softens separators, and makes desktop tabs more compact.</citation>

### Typography and color

<citation refs="HZ9qlS_P3kr2C_YfpEkcK">The 2024 redesign documented Inter Display for headings, Inter for other text, and an LCH-based theme system driven by base color, accent, and contrast.</citation>

<citation refs="6a-wGJcRRdEnLgrfulzF8">The 2026 direction moves away from cool blue-gray toward warmer, less-saturated neutrals.</citation>

Observed:

- Mostly solid content surfaces.
- Minimal decorative elevation.
- Color communicates status rather than coating containers.
- Repeated alignment creates structure without a border around everything.

### Keyboard and interaction craft

<citation refs="ZOxFcLUTc79Q2xl2A2dVk,-YiG3vjgx_foDMLOfiw1A">

- `⌘K`: command menu.
- `/`: global search.
- `G`, then `I`: Inbox.
- `C`: create issue.
- `F`: filters.
- Filter search accepts known property values directly.

</citation>

<citation refs="UqFwA1wuKPjiazQul0w_Z">Linear’s context-menu work includes a submenu “safe triangle,” allowing diagonal pointer travel without accidentally closing the submenu.</citation> This invisible tolerance is an excellent example of premium interaction design.

### Onboarding and pain points

<citation refs="_NetodnJnGZn7hJdFUzll,PkQBfNmxuTPbyxQOLOMWU">Linear offers a public demo workspace and role-specific onboarding resources.</citation>

<citation refs="SK1BTDH27nY20nfk-zGkU,meYRmEivVpEYdLSkSJafS">Criticism includes learning curve, hidden workflows, inconsistent editing expectations, and organizational complexity despite the clean appearance.</citation>

**Borrow:** Quiet chrome, consistent density, forgiving menus, direct filtering.  
**Avoid:** Assuming visual minimalism automatically produces conceptual simplicity.

---

# 3. What macOS 26 actually suggests

## 3.1 Glass is a layer, not a theme

<citation refs="ra4dyq9kfYymCRyi2n3ip">Apple places Liquid Glass primarily in the controls/navigation layer above content. Standard materials remain appropriate within content. Regular glass is the safer choice for text-heavy interfaces; clear glass is intended for suitable rich-media backgrounds.</citation>

For this utility:

- **Good glass candidates:** floating capture toolbar, contextual action group, small transient control surface.
- **Use restraint:** launcher shell and drop shelf.
- **Prefer stable content surfaces:** clipboard text, search results, settings forms, annotation canvas.

A translucent card containing translucent controls over a translucent panel creates ambiguity, not sophistication.

<citation refs="cb_c55eA3QEIObaxdiuaa">Six Colors’ Tahoe review highlights the practical tension: glass can create hierarchy, but content underneath controls can also compromise legibility, and Mac effects are often much subtler than their iPhone equivalents.</citation>

## 3.2 Menu bar extra versus panel

<citation refs="HoykEUvn6HwGUa_4X7W6G">Apple recommends a menu for a menu bar extra unless functionality is too complex, an adaptable symbol-like image, user control over visibility, and no dependence on the extra always remaining visible.</citation>

<citation refs="Ja18fzTHBoM76mG1id0pU">SwiftUI’s `MenuBarExtra` window style supports richer popover-like content.</citation> It does not automatically provide all the focus and persistence behavior needed by a global launcher or drop shelf.

Recommended division:

- Menu bar extra: compact status and commands.
- Launcher: dedicated transient global surface.
- Drop shelves: independently managed windows/panels.
- Settings and annotation editor: normal windows.

<citation refs="Qw7rBtigaOHzeyxyTmhOT">Apple’s panel guidance concerns supplementary UI, and reserves dark translucent HUD treatment for narrower situations than “any small utility window.”</citation>

## 3.3 Native sizing and symbols

<citation refs="24W44rzpAMB5i7SdkP4TM">Apple’s accessibility guidance lists 13 pt as a macOS default text size and 28 × 28 pt as a default control size, with 20 × 20 pt as a recommended minimum.</citation> These are guidance values, not a universal mandate to override native control sizing.

Do not import an iPhone’s 44-point target into every dense Mac toolbar. Conversely, do not turn a 12-point icon into a 12-point clickable target.

**SF Symbols provenance:** Screenshots alone do not prove that competitor icons are SF Symbols. App logos, extension icons, custom annotation glyphs, and system-like symbols must be distinguished.

For the proposed app, use SF Symbols deliberately for standard actions and custom artwork only where it improves recognition.

## 3.4 Motion

<citation refs="5sCdELiT-m30v40sQsMxm">Apple recommends purposeful, brief, interruptible motion and warns against unnecessary animation in frequent interactions. Glass response is more subdued with indirect input than direct touch.</citation>

No defensible shared “premium app animation duration” emerged from this research.

The useful patterns are:

- Raycast: eliminate visual discontinuities during resizing.
- Paste: preserve card-to-preview continuity.
- CleanShot: lightweight result appearance and dismissal.
- Dropover: expand the same object and preserve its position.
- Linear: feedback and navigation should not delay work.

**Do not animate every arrow-key selection.** Selection must keep up with keyboard repeat.

---

# 4. Onboarding and permission design

## 4.1 Start with value, not a permission checklist

Recommended first-run sequence:

1. Open a functioning launcher with sample/local commands.
2. Let the user try one useful action.
3. Introduce clipboard history with an explicit privacy choice.
4. Request capture authorization when Capture is first invoked.
5. Request Accessibility when direct paste, window control, or scrolling capture needs it.
6. Offer login-at-launch and optional sync after the core behavior is understood.

No mandatory account should block local capture, launching, clipboard retrieval, or staging files.

## 4.2 Explain permissions by capability

**Screen capture**

Explain that macOS groups screenshot access under screen-recording terminology.

<citation refs="oPuJNCE2drTzo_dlx6FCX,_wJyK0lUMrRrvvtuk30Bh">Where it fits the workflow, `SCContentSharingPicker` lets the user explicitly choose content and authorizes that selected content for the capture session without a separate general screen-capture permission flow.</citation>

That does not replace every custom region-capture workflow.

<citation refs="CRDU7frFKQPXPtVsvZo1x,44GVa_x3fDsuq41RGDHUh">General screen access is managed under Privacy & Security → Screen & System Audio Recording. Apple’s general capture sample documents a restart after permission is granted; this must not be generalized to every picker-based capture path.</citation>

**Accessibility**

Explain separately:

- Window management: move and resize other apps’ windows.
- Direct Paste: send the paste action to the intended app.
- Scrolling capture: scroll another app.

<citation refs="u85T7a1eGmMGNI9up-qfd">`AXIsProcessTrustedWithOptions` does not become true merely because a prompt was shown; prompting is asynchronous.</citation>

Recheck actual authorization when the app becomes active again.

**Clipboard**

Do not describe clipboard history as unrelated to privacy permissions. <citation refs="FeQ8CWEOY1zmlINwggDjl">AppKit exposes pasteboard access behavior, including ask, allow, and deny states, with distinctions for user-originated paste operations.</citation> Handle the deployed OS’s actual behavior rather than assuming unrestricted background reads.

## 4.3 A smooth permission state machine

Use explicit states:

```text
Not requested → Explanation → System authorization
                              ↓
                    Granted / Denied / Unavailable
```

Recommended behavior:

- Resolve permission before engaging a screen-wide capture overlay.
- Preserve the attempted action.
- Resume it after authorization when safe.
- If restart is necessary, explain why and preserve intent.
- On denial, keep unrelated modules usable.
- Do not repeatedly open System Settings.
- Show capability status in one searchable Permissions settings section.

<citation refs="HOF3yvnz9tTjewhjzIkCR">For a dedicated pre-alert explanation, Apple recommends neutral continuation wording rather than a fake “Allow” button that impersonates the system decision.</citation>

## 4.4 Privacy should remain visible after onboarding

Recommended controls:

- Pause clipboard recording for 15 minutes, one hour, or indefinitely.
- Exclude specific apps.
- Local-only by default; sync separately opt-in.
- Retention period and clear-history action.
- Hide sensitive previews during presentations where technically supported.
- Explicit upload actions, never automatic cloud transfer.
- Distinguish referenced files from copies owned by the app.

<citation refs="1O0t5SSQcq7y1FenSrcQL">Clipboard conventions identify transient, concealed, and autogenerated content.</citation> Respect these markers, but do not promise that they detect every secret.

---

# 5. Recurring UX risks across the category

These are recurring themes in the inspected reports, not statistically ranked complaint frequencies.

### 1. Beautiful surfaces that obscure state

Examples: unclear focus, ambiguous selection, hover-only actions, uncertain shelf ownership.

**Response:** Make active selection, keyboard focus, persistence, and ownership explicit.

### 2. Too much feature breadth

A launcher can become a second operating system. A clean sidebar can still hide a complicated conceptual model.

**Response:** Reveal capabilities through relevant actions, not a first-run feature parade.

### 3. Slow or unreliable retrieval

Clipboard search and launcher response are foundational. Users notice one missing result more than ten polished transitions.

**Response:** Prioritize local indexing, stable selection, honest loading states, and no false empty-state flashes.

### 4. Dismissal with surprising consequences

Closing may copy, discard, hide, expire, or remove a file reference depending on the app.

**Response:** Define an explicit Escape and close contract. Make recovery inexpensive.

### 5. Shortcut and focus collisions

Capture shortcuts overlap with macOS; launcher shortcuts overlap with other launchers; newly appearing shelves can intercept typing.

**Response:** Configurable shortcuts, a test step during setup, visible active target, and nonactivating background surfaces.

### 6. Permission breakage

OS changes, duplicate app copies, stale permission entries, and misleading “Screen Recording” terminology cause disproportionate frustration.

**Response:** Diagnose the actual permission and app instance. Offer precise recovery, not “try reinstalling.”

### 7. Rich previews versus information density

Large cards help recognition but hinder scanning long histories.

**Response:** Offer a compact list mode with equivalent keyboard capabilities.

### 8. Monetization interrupting the core action

A utility’s value is low-friction repetition. Delays, review prompts, and repeated upsells are especially costly mid-task.

**Response:** Keep commercial messaging outside capture, paste, drag, and window-management flows.

---

# 6. Concrete design system proposal

Everything in this section is **proposed**, not an extracted competitor specification.

## 6.1 Product architecture: one engine, several surfaces

Use one action model shared by all modules:

```text
Item → Primary action → Contextual actions → Optional detail
```

Examples:

- Clipboard item → Paste → Copy / Plain text / Pin / Delete.
- Screenshot → Copy → Annotate / Save / Pin / Add to shelf.
- File → Open → Reveal / Copy / Add to shelf.
- Window → Activate → Move / Resize / Restore.
- Command → Run → Assign shortcut / Favorite / Configure.

The same item identity should survive moving between surfaces. A screenshot added to a shelf should not become an unexplained duplicate in three histories.

### Launcher

- Default expanded frame: **680 × 480 pt**.
- Compact frame: **680 × 64 pt**.
- Search region: **56 pt**.
- Action footer: **32 pt**.
- One-line row: **36 pt**.
- Two-line row: **52 pt**.
- Result inset: **8 pt**.
- Stable top anchor during expansion.
- Clamp dimensions to the active display’s usable frame.

### Clipboard shelf

- Default height: **300 pt**.
- Screen-edge margin: **16 pt**.
- Side margins: **24 pt**.
- Default card: **220 × 220 pt**.
- Card gap: **12 pt**.
- Toolbar: **40 pt**.
- Resizable compact mode, plus a separate **36-point-row list mode**.

Keep card content opaque enough for long text and code. The shelf shell may be translucent.

### Capture toolbar and quick result

- Capture toolbar height: **52 pt**.
- Primary labeled mode target: approximately **56 × 40 pt**.
- Quick-result thumbnail: **240 pt wide**, aspect-ratio-aware.
- Maximum default preview height: **180 pt**.
- Screen-edge offset: **20 pt**.
- Visible stack: up to **three** results, then a count/recent-history affordance.
- Never cover the region being selected.

### Drop shelf

- Compact: **176 × 176 pt**.
- Expanded starting size: **400 × 440 pt**.
- Edge docking inset: **12 pt**.
- Appear near the pointer, offset away from the drag path.
- Appearing during a drag does not activate the app.
- File references display an unavailable state if the source disappears.

### Settings and editor

- Settings starting size: **900 × 640 pt**.
- Settings sidebar: **200 pt**, resizable where appropriate.
- Main content padding: **24 pt**.
- Annotation editor: normal resizable window with system toolbar sizing.
- Avoid forcing editor geometry to match the launcher.

---

## 6.2 Spacing and shape tokens

Use a four-point rhythm with a two-point optical exception.

```yaml
spacing_pt:
  micro: 2
  tight: 4
  compact: 8
  related: 12
  standard: 16
  group: 24
  section: 32
  major: 48

corner_radius_pt:
  keycap: 4
  small_control: 6
  selection_row: 8
  preview_card: 12
  custom_floating_panel: 20
  capsule: fully_rounded

control_pt:
  standard_icon_target: 28
  comfortable_icon_target: 32
  compact_row: 36
  two_line_row: 52

stroke:
  separator: one_physical_pixel
  selected_card: 2pt
```

Rules:

- Native windows and system controls retain system geometry.
- The **20-point radius is for custom floating shells**, not a replacement for macOS window corners.
- Nest shapes optically: inner content should not have a larger radius than its container.
- Use separators only when spacing and alignment cannot communicate grouping.
- Do not add a bright border, dark border, and heavy shadow to the same surface.

## 6.3 Typography

Use the system font for native integration. Avoid a custom display face in the everyday utility interface.

```yaml
type:
  micro:
    size_pt: 11
    weight: regular
    use: noncritical timestamps and metadata

  caption:
    size_pt: 12
    weight: regular
    use: secondary labels and shortcut hints

  body:
    size_pt: 13
    weight: regular
    use: results, settings, menus

  emphasized_body:
    size_pt: 13
    weight: medium
    use: important labels and selected emphasis

  section:
    size_pt: 15
    weight: semibold
    use: section and inspector headings

  search:
    size_pt: 17
    weight: regular
    use: launcher input

  title:
    size_pt: 20
    weight: semibold
    use: window content titles

  onboarding_title:
    size_pt: 26
    weight: semibold
    use: brief first-run explanations
```

Implementation rules:

- Use natural system line metrics rather than rigidly clipping text into prescribed heights.
- Use monospaced digits for dimensions, timers, and coordinates.
- Use a monospaced face for code previews, not all metadata.
- Support larger text/interface settings and allow rows to grow.
- Weight and spacing should establish hierarchy before color does.

## 6.4 Color and material tokens

Use semantic system colors at runtime. The hex values below are proposed solid-surface fallbacks and design-file references, not replacements for adaptive system behavior.

```yaml
light:
  canvas: "#F7F7F5"
  surface: "#FFFFFF"
  surface_secondary: "#EFEFED"
  text_primary: "#1B1B1D"
  text_secondary: "#606068"
  accent_fallback: "#005FCC"

dark:
  canvas: "#19191B"
  surface: "#232326"
  surface_secondary: "#2D2D31"
  text_primary: "#F5F5F7"
  text_secondary: "#B5B5BE"
  accent_fallback: "#78A9FF"

semantic:
  accent: system_accent
  destructive: system_red
  warning: system_orange
  success: system_green
  focus: system_keyboard_focus
  separator: system_separator
```

Material policy:

- **Standard windows:** system chrome.
- **Settings and long-form text:** stable system backgrounds.
- **Launcher:** restrained shell material with readable result backing.
- **Clipboard:** material shell, substantially opaque cards.
- **Capture controls:** regular Liquid Glass.
- **Drop shelf:** restrained material; content never depends on wallpaper contrast.
- **Annotation canvas:** neutral solid background.

Do not specify “blur 24 px” as if it were Apple’s Liquid Glass recipe. Use the native material APIs.

Accent policy:

- Accent denotes selection, focus, or a primary action.
- Category colors may appear in small icons/dots.
- Do not tint entire modules five unrelated colors.
- Destructive actions remain neutral until deliberately exposed, then use semantic red.

### Accessibility variants

- Reduce Transparency: switch custom translucent surfaces to opaque semantic backgrounds.
- Increase Contrast: strengthen boundaries and secondary text.
- Reduce Motion: remove scale, large translations, and bounce.
- Test light/dark on bright photos, black wallpaper, white wallpaper, and dense desktop content.
- Never encode active state through color alone.

---

## 6.5 Iconography

Use SF Symbols with consistent optical scale, generally **14–16 pt** inside **28–32 pt** targets.

Suggested vocabulary:

- Capture: `viewfinder`
- Clipboard: `doc.on.clipboard`
- Launcher: `command`
- Window layout: `rectangle.split.2x1`
- Shelf: `tray`
- Pin: `pin`
- Search: `magnifyingglass`
- Actions: `ellipsis`
- Close: `xmark`

Rules:

- Match symbol weight to nearby typography.
- Use labels for capture modes and important output actions.
- Tooltips include the action name and shortcut.
- Every icon-only control receives an accessibility label.
- Use actual app/file icons for provenance, not generic symbols when identity matters.
- Check symbol availability against the deployment target.

---

## 6.6 Motion tokens

These are starting values for prototyping and testing.

```yaml
motion:
  hover_feedback:
    duration_ms: 80
    curve: ease_out

  selection_change:
    duration_ms: 0
    note: immediate during keyboard navigation

  panel_enter:
    spring_duration_s: 0.24
    bounce: 0.0
    opacity: [0, 1]
    translation_y_pt: [6, 0]

  panel_exit:
    duration_ms: 120
    curve: ease_in
    opacity: [1, 0]

  shelf_expand:
    spring_duration_s: 0.30
    bounce: 0.04

  structural_reflow:
    duration_ms: 180
    curve: ease_in_out

  reduced_motion:
    duration_ms: 80
    effect: opacity_only
    bounce: 0
```

For non-spring custom transitions:

```text
ease-out:    cubic-bezier(0.20, 0.80, 0.20, 1.00)
ease-in:     cubic-bezier(0.40, 0.00, 1.00, 1.00)
ease-in-out: cubic-bezier(0.40, 0.00, 0.20, 1.00)
```

<citation refs="ApJBMnPzJiUEuwS7FoDO6">SwiftUI spring duration describes perceptual pace, not an exact completion deadline.</citation>

Motion rules:

- Accept input from the first visible frame.
- Opening again interrupts dismissal.
- Preserve selected-item identity during asynchronous updates.
- Do not spring every list row.
- Animate structural changes, not every content refresh.
- Use system window/control transitions without layering a second custom animation over them.
- Keep notification actions available after the animation ends.

---

## 6.7 Keyboard and focus contract

### Shared behavior

- Type immediately to search in the launcher and clipboard.
- Arrow keys navigate results without moving text focus unnecessarily.
- `Return`: primary action.
- `⌘K`: contextual actions.
- `Space`: preview, where it does not conflict with text entry.
- `⌘C`: copy selected content.
- `⌘,`: Settings.
- Context menus mirror available keyboard actions.
- Direct module shortcuts are optional and configurable.

Suggested global bindings should be offered and tested, not silently imposed over Spotlight, Raycast, or existing capture tools.

### Explicit Escape hierarchy

1. Close an open action submenu.
2. Close the action panel or preview.
3. Dismiss a transient launcher/clipboard surface.
4. In capture selection, cancel without creating a capture.
5. In the editor, cancel the current operation before considering window dismissal.
6. In a persistent shelf, dismiss transient controls, not its contents.

`⌘W` closes a persistent shelf/window. Recovery remains available.

**Never silently paste, upload, delete, or overwrite the clipboard merely because Escape was pressed.**

### Focus rules

- Launcher invocation takes keyboard focus.
- A post-capture thumbnail does not.
- A shelf appearing during a drag does not.
- Direct Paste restores the intended destination before issuing paste.
- If the destination is no longer valid, copy instead and explain the fallback.
- Search/filter state remains understandable when focus moves between input and results.

---

## 6.8 SwiftUI implementation direction

<citation refs="VCO5IRHbcL1MD1smidWWO,DWwDlF167g-eD5DOyjIEs">Standard SwiftUI/AppKit components adopt the new design when built with the appropriate SDK; unnecessary custom backgrounds can obstruct native glass and toolbar behavior.</citation>

Recommended foundation:

- `Settings` scene and `NavigationSplitView` for configuration.
- Standard toolbar items in the editor.
- `MenuBarExtra` for the compact menu-bar entry.
- SwiftUI content hosted in carefully managed AppKit windows/panels where global positioning, activation, and persistence require it.
- Native menu behavior for conventional menus.
- Shared command/action models across every surface.

For custom glass:

<citation refs="sUGuBYYqtWeCemFsWeuau,Xu5CpM1fFB7LIYBbnsFKG">Use `glassEffect` and `GlassEffectContainer` for suitable nearby controls. Container spacing affects merging behavior; it is not simply a normal layout gap. Interactive glass is supported on native macOS 26.</citation>

Use these APIs selectively. Do not wrap every clipboard card or list row in a glass effect.

---

## 6.9 Definition of “premium”

The release should satisfy these criteria before adding more visual effects:

- Warm launcher first meaningful frame targets **under 100 ms** on a stated test machine.
- Local search targets **under 50 ms** for the chosen representative archive.
- Performance is measured separately from animation duration.
- No false “No results” flash during loading.
- No focus theft from background thumbnails or drag shelves.
- No lost capture after closing a thumbnail.
- No ambiguous copy/move/upload semantics.
- Permission denial leaves unrelated functionality operational.
- Keyboard repeat remains responsive.
- Fullscreen Spaces, multiple displays, display scaling, and reduced-accessibility settings are tested.
- Every important operation has a discoverable keyboard path and a visible pointer path.
- Local utility functions remain useful without an account or network connection.

**Final direction:** a quiet, precision-oriented Mac utility with restrained glass, excellent previews, predictable keyboard behavior, and reversible actions. The premium quality should come from how reliably it preserves the user’s intent, not how much the interface reflects the wallpaper.
