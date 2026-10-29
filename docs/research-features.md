# macOS Utility Super-App Research

**Research date:** October 28, 2026  
**Scope:** 22 apps, using official product sites, documentation, repositories, and App Store listings.

### How to read this report

- **Prices:** USD unless another currency is shown. Taxes, regional pricing, and promotions can change checkout totals.
- **Hotkeys:** `⌘` Command, `⌥` Option, `⌃` Control, `⇧` Shift. **Global** works outside the app; **contextual** works only in its interface.
- **Unverified** means the inspected sources did not establish a current factory default. It does not mean the feature is absent.
- **Signature UX** identifies distinctive interactions worth studying, not a measured ranking of user satisfaction.
- Feature lists cover the core product, with paid additions identified. Third-party extension catalogs are summarized rather than enumerated.

---

# 1. App-by-app research

## 1. CleanShot X

**Official:** [cleanshot.com](https://cleanshot.com/features)

**Purpose:** A complete screenshot, annotation, screen-recording, and sharing suite.

### Core features

- <citation refs="RWi96Cz86syxZefdToV6c">**Capture:** Fullscreen, area, window, timed capture, vertical and horizontal scrolling capture, repeatable selection, precise dimensions/aspect ratios, crosshair magnification, and screen freezing. Window captures support transparent backgrounds, shadows, wallpaper, solid colors, or custom backgrounds.</citation>
- <citation refs="RWi96Cz86syxZefdToV6c">**Image editing:** Crop, resize, rotate, flip, straight/curved arrows, shapes, text, freehand drawing, highlighter, numbered steps, spotlight, blur/pixelation, color picker, image overlays, and editable project files. Presentation backgrounds include padding, alignment, shadows, and reusable presets.</citation>
- <citation refs="RWi96Cz86syxZefdToV6c,JGCI0An6kqDbrfhaT8ony">**Recording:** Screen/window/area recording to MP4 or GIF; microphone and system audio; webcam overlay; cursor, click, and keystroke visualization; recording timer; desktop-clutter hiding; automatic Do Not Disturb. The current site also advertises Studio editing with trimming, smart zooms, cursor smoothing, background styling, and post-recording camera/cursor adjustments.</citation>
- <citation refs="RWi96Cz86syxZefdToV6c">**Extraction and reference:** On-device OCR, QR reading, pinned always-on-top screenshots, opacity/size controls, click-through Lock Mode, and recoverable local capture history up to one month.</citation>
- <citation refs="Pr0ujdSVjHitABP7WEIXw,RWi96Cz86syxZefdToV6c">**Cloud:** One-click uploads, shareable links, video transcription, comments, and content search. Pro adds unlimited storage subject to fair use, custom branding/domain, and team/security controls. Cloud is optional.</citation>

### Signature UX

<citation refs="RWi96Cz86syxZefdToV6c">**Quick Access Overlay:** A small floating thumbnail after capture offers copy, save, annotate, upload, and drag-out actions. The full editor is optional, not an obligatory interruption.</citation>

### Default hotkeys

- **Global capture defaults:** Unverified. Capture/OCR/recording shortcuts are configurable; do not assume macOS screenshot bindings are automatically CleanShot defaults.
- <citation refs="mqpSbr4BKMkinoLS1jbvB">**Overlay:** `⌘C` copy; `⌘S` save; `⌘W` close; `⌘U` upload; `⌘E` annotate.</citation>

### Price

<citation refs="Pr0ujdSVjHitABP7WEIXw,ZWe1B3nBOwiXJO3rCTcCQ">**Basic: $35 one-time**, perpetual use, one year of updates, 1 GB Cloud. Optional updates renewal: **$19/year per seat**. **Pro: $10/user/month billed annually**, including ongoing app updates and expanded Cloud features.</citation>

---

## 2. Shottr

**Official:** [shottr.cc](https://shottr.cc/)

**Purpose:** A lightweight screenshot tool with unusually strong pixel-level inspection and editing.

### Core features

- <citation refs="-qSbkb2_NsdOGc7rM4l_s,DCdYWgeVGEQlJYhMusQ-G">**Capture:** Fullscreen, area, active/selected window, previous area, delayed capture, and scrolling capture. Configurable window backgrounds and shadows.</citation>
- <citation refs="-qSbkb2_NsdOGc7rM4l_s,DCdYWgeVGEQlJYhMusQ-G">**Editing:** Crop, resize, arrows, text, shapes, counters, freehand, highlighter, spotlight, magnifier callouts, hand-drawn styling, text-only pixelation/erasure, object removal, image overlays, expandable canvas, transparency, and two-frame before/after GIFs.</citation>
- <citation refs="-qSbkb2_NsdOGc7rM4l_s,rUPhbBE5_40jsW6FSD5Tf">**Precision:** Deep zoom, pixel-by-pixel selection changes, automatic selection adjustment, rulers/distance measurement, guides, color copying, OKLCH support, and WCAG/APCA contrast measurement.</citation>
- <citation refs="-qSbkb2_NsdOGc7rM4l_s">**Utility features:** OCR, QR extraction, line-break removal, floating pinned screenshots, copy/save automation, drag-out export, Shottr Cloud uploads, direct S3-compatible uploads, URL-scheme integration, and Raycast/Alfred integration.</citation>

**Boundary:** Primarily a still-image tool, not a screen-video recorder.

### Signature UX

<citation refs="GUjWSn18Z0ZiBgIbUIb6K,DCdYWgeVGEQlJYhMusQ-G">**Capture first, crop precisely afterward.** Users can work in a full editor or a small near-cursor thumbnail. Copying/saving dismisses the editor, while reopening restores the capture.</citation>

### Default hotkeys

- **Global:** Current complete factory bindings unverified. `⌘⇧2` appears in historical documentation, but is not sufficient evidence for every current installation.
- <citation refs="DCdYWgeVGEQlJYhMusQ-G">**Editor:** `Return` crop; `Delete` erase selection; `⌘O` OCR selection; `⌘⇧C` copy image; `⌘S` save; `⌘⇧S` Save As.</citation>
- <citation refs="rUPhbBE5_40jsW6FSD5Tf,-qSbkb2_NsdOGc7rM4l_s">**Precision:** `⌘+ / ⌘−` zoom; `⌘0` actual size; `⌘2` zoom selection; arrows move selection one pixel; `⌘`+arrows resize; add `⇧` for ten pixels; `Space`+drag pans; `Tab` copies the color under the cursor.</citation>

### Price

<citation refs="GsET-ziW8-MQwlJ57U1kM,nWRHE9c-MjX7DquNo-PYF">Free indefinitely with reminders after 30 days; commercial use requires a license. **Basic $12**, **Friends Club $30**, both one-time; one user, up to five computers. Friends Club adds experimental features/support. Lifetime future upgrades are not explicitly guaranteed.</citation>

---

## 3. Raycast

**Official:** [raycast.com](https://www.raycast.com/) · [Manual](https://manual.raycast.com/quickstart)

**Purpose:** A keyboard-first launcher that combines search, utilities, integrations, automation, and AI.

### Core features

- <citation refs="JskRWsMA805x8-QybpKCa,1kZ0PS6kQt0wNgRGKaf4f">**Search and launching:** Apps, files, folders, commands, Quicklinks, favorites, aliases, fallback searches, metadata previews, and configurable per-command hotkeys.</citation>
- <citation refs="wqzLdqIX_24E4hycU-mf7,7Tf_OqcSzNcUJZiUCqpdp">**Clipboard and snippets:** Text/image/file/link/color history, type filters, pinning, renaming/editing, image OCR/QR extraction, reusable snippets, keyword expansion, dynamic placeholders, tags, and import/export.</citation>
- <citation refs="6lRKxtV9OWzKUIJUtEQ01,KtGK4ADQAdysh2ffmWZM9">**Everyday utilities:** Parameterized web searches and deeplinks, selected-text arguments, calculator, unit/currency/date conversions, emoji, and symbols.</citation>
- <citation refs="EokCVydXNehYSFVYy5doU,he1wvMhDLj9RvDghjCNGI">**Window management:** Halves, thirds, quarters, sixths, center/maximize/restore, display movement, and Spaces operations. Paid custom commands/layouts add exact sizing and multiwindow arrangements.</citation>
- <citation refs="BNNmnwoMo8GC64ZCb2Fak,5mrpozECtxgGX5hIn_c5H">**Notes and screenshots:** Markdown notes, tasks, search, screenshot/recording search, OCR-based screenshot retrieval, watched folders, and paste-latest-screenshot. Screenshot retrieval is not a full capture/annotation editor.</citation>
- <citation refs="DaO8mR1ZUy38YcMplJyET,zcRtlnzXeHkQbB0_Nk2eL">**Focus and meetings:** Timed focus sessions, app/site blocking, breaks, floating Focus Bar, calendar search/creation, availability copying, meeting joining, camera preview, and menu-bar agenda.</citation>
- <citation refs="Mu3YA9Pl_yRvA_wxKRcfk,zgh-W_QSINctWiW-U2Xjp,7BcTQ7NKkqn8ZVS9q6qb0">**Automation:** System commands, local Script Commands, arguments/output views, public/private extensions, developer APIs, and custom integrations.</citation>
- <citation refs="_ewRPS5XtHPfF4pSf3aQI,PDZtSRV8kH6ClyyWkfw_-">**Paid AI:** Quick AI, persistent chat, attachments, screen context, reusable commands, projects, agents/skills, tools, scheduled automation, MCP, dictation, and translation. Supports provider models, BYOK, local/custom providers, and connected subscriptions under paid-plan rules.</citation>

### Signature UX

<citation refs="KtGK4ADQAdysh2ffmWZM9,1kZ0PS6kQt0wNgRGKaf4f">**Summon → type → act.** The Action Panel exposes secondary operations without leaving the result list. Frequent commands graduate from search to aliases or direct hotkeys.</citation>

### Default hotkeys

- <citation refs="1kZ0PS6kQt0wNgRGKaf4f">**Global:** `⌥Space`. Replacing Spotlight with `⌘Space` is optional, not the factory default.</citation>
- <citation refs="F_D2_NdYSBRombUslUxX0,KtGK4ADQAdysh2ffmWZM9">**Contextual:** `⌘K` Action Panel; `Return` primary action; `⌘Return` secondary action; `⌥Return` tertiary action; `⌘Y` Quick Look where supported; `Esc` back/dismiss; `⌘,` settings; `Tab` Quick AI from Root Search.</citation>
- Clipboard, notes, window actions, scripts, and Hyper Key mappings are user-configured.

### Price

<citation refs="he1wvMhDLj9RvDghjCNGI,PDZtSRV8kH6ClyyWkfw_-">**Free:** Core utilities/extensions, three-month clipboard retention, five notes. **Pro $10/month or $96/year**; **Pro+ $20/month or $192/year**; **Max $50/month or $480/year**. Monthly AI allowances are respectively 500, 3,000, and 7,500 credits. Paid plans include sync, unlimited notes/history, and other premium utilities. No perpetual paid license.</citation>

---

## 4. Alfred

**Official:** [alfredapp.com](https://www.alfredapp.com/)

**Purpose:** A fast Mac launcher with a mature keyboard-driven automation system.

### Core features

- <citation refs="bURDq8JWvWeU_fvEwx-Af,XJs0sAM1sZIikzkAuwk8w">**Free:** App launching; file/content/tag search; usage-ranked results; custom web searches; calculator; dictionary/spelling; system commands; Quick Look; Large Type; usage statistics.</citation>
- <citation refs="Os80_w5sDiY3CIWoju_6Q,SDna0MzIYxFFir-5UHJ9F">**Powerpack automation:** Visual workflows with triggers, inputs, filters, scripts, actions, and utilities; API integration; rich result views; workflow sharing/Gallery; automation tasks.</citation>
- <citation refs="VZsePeojQbPnzhCI7jf1W,cKn4FWruwWR4hFzS8vOYc">**Content actions:** Universal Actions for selected text/URLs/files; searchable clipboard history; app exclusions; clipboard merging; snippet collections and automatic text expansion.</citation>
- <citation refs="Os80_w5sDiY3CIWoju_6Q,nAznOvFQxlDQa9FaHd5H8">**File and app tools:** Keyboard directory navigation, file filters, recent documents, multi-file File Buffer, copy/move/email actions, Contacts, Music mini-player, Terminal integration, themes, preference sync, and 1Password bookmark integration. Alfred Remote is a separate iOS companion.</citation>

### Signature UX

<citation refs="VZsePeojQbPnzhCI7jf1W,Os80_w5sDiY3CIWoju_6Q">Combines **verb-first launching** with **object-first Universal Actions**: select something anywhere, then choose what to do with it. Complex workflows become a short keyword or hotkey.</citation>

### Default hotkeys

- <citation refs="XJs0sAM1sZIikzkAuwk8w,cKn4FWruwWR4hFzS8vOYc">**Global:** `⌥Space` launcher; `⌥⌘C` Clipboard History, after enabling recording. History is initially disabled for privacy.</citation>
- <citation refs="XJs0sAM1sZIikzkAuwk8w">**Contextual:** `⌘1–9` numbered result; `⌘Return` reveal file; `⇧` or `⌘Y` Quick Look; `→` file actions; `⌘↓` browse folder; `Backspace` parent folder; `⌥→` act on File Buffer.</citation>
- <citation refs="VZsePeojQbPnzhCI7jf1W,XJs0sAM1sZIikzkAuwk8w">**Documentation conflict:** Universal Actions is listed as `⌘/` in its guide but `⌥⌘\` in the cheat sheet. Treat this as version/configuration-dependent, not a universally verified default.</citation>

### Price

<citation refs="RcO3B_QkAR8KKe969LNK8,voACMHYVpdxodnarycmQP">Free core. **Powerpack £34 one-time:** one user, two personal Macs, current major version. **Mega Supporter £59:** personal Macs and lifetime Alfred upgrades. The current shop also promises Alfred 6 to new buyers; the inspected download page still offered Alfred 5.</citation>

---

## 5. Paste

**Official:** [pasteapp.io](https://pasteapp.io/)

**Purpose:** A visual clipboard history and reusable-content workspace across Apple devices.

### Core features

- <citation refs="kJtCCuNCJqYv4NIH_lGfY,JAaRE_F-sZpTSUSwbYK2S">Text, links, images, files, and colors; original formatting; configurable retention from one day to forever. **Default retention is 30 days**, while pinned content survives cleanup.</citation>
- <citation refs="4azqvvJqBJec6jR0988Bu,FoHdssW3jqHyC5IsjXPhV">Search content/titles/metadata and text inside images; filter by app, date, device, or type; named/color-coded Pinboards; shared iCloud Pinboards with access permissions.</citation>
- <citation refs="uFymnC0ozureyXESdHQui,gHFxAF3yquaxtpKgLUB-J">Rich previews, Quick Look, item editing/renaming, image rotation, text extraction, new text items, multiselect, drag-and-drop, batch paste, and plain-text paste.</citation>
- <citation refs="G70VlZ9ng-T_-tTt9muth,i_4IT8MUgoxvER1HuN2rs">**Paste Stack:** Collect multiple copies and paste them sequentially; reverse direction; remove consumed items. Numbered Quick Paste retrieves positions 1–9 while Paste is open.</citation>
- <citation refs="RrbECEyc1kUhnktS0MYuo,Up90TGNbcj6jnYX8d958p,cToa-w8YEEPgf9A55hYhP">Optional iCloud sync, app exclusions, capture pause, confidential-item filtering, screen-sharing hiding, on-device context-based suggestions, and a local MCP server for approved AI clients.</citation>

### Signature UX

<citation refs="uFymnC0ozureyXESdHQui">A **horizontal visual timeline at the bottom of the display**, showing content previews, source app, and copy time. Resize it into Compact Mode or switch to permanent Pinboards.</citation>

### Default hotkeys

- <citation refs="jqFntD-xZ2Uk6c1-Lk5XH">**Global:** `⇧⌘V` show/hide; `⇧⌘C` activate Paste Stack.</citation>
- <citation refs="jqFntD-xZ2Uk6c1-Lk5XH">**Inside Paste:** `Return` paste; `⇧Return` plain text; `⌘1–9` Quick Paste; `⇧⌘1–9` plain-text Quick Paste; `Space` preview; `⌘F` search; `⌘E` edit; `⌘R` rename; `⌘N` new text; `⇧⌘N` new Pinboard; `⌘←/→` switch Pinboard; `⌘T` pause capture.</citation>

### Price

<citation refs="cToa-w8YEEPgf9A55hYhP,rHUY7lxjUL-4lnsMgIV7N">**$3.99/month**, **$29.99/year**, or **$99.99 lifetime**. Family: **$59.99/year**, up to six people. Personal plans cover Mac/iPhone/iPad; lifetime includes future updates but not Family Sharing. Seven-day trial.</citation>

---

## 6. Maccy

**Official:** [maccy.app](https://maccy.app/) · [Repository](https://github.com/p0deje/Maccy)

**Purpose:** A minimal, local, keyboard-first clipboard history manager.

### Core features

- <citation refs="3KENVlutZjXviJagzFH1F,sT4g5oNcwEXBsjlajLRic,1YWzwAoXos00WelsGa_NM">History for plain/rich text, images, and file URLs. Current source defaults to **200 entries**, with a settings range of 1–999.</citation>
- <citation refs="93shE8MlVpLP5i9APJlMs,q-WoOXI5xIDd8WgLc04lj">Exact, fuzzy, regex, and mixed search; permanent pins with individual shortcut keys; pin reordering/editing; image previews; OCR-related preview improvements; source-app icons and color swatches.</citation>
- <citation refs="3KENVlutZjXviJagzFH1F">Copy-only or automatic-paste behavior, plain-text paste, ignored/allowed apps, regex/type exclusions, confidential/transient-item filtering, pause/ignore-next-copy, history clearing, clear-on-quit, and Shortcuts actions.</citation>
- <citation refs="6F9TU7lGE0-SAKZGLDUFX,q-WoOXI5xIDd8WgLc04lj">Local clipboard storage. No official built-in iCloud history sync, cross-device app, Pinboard workspace, or sequential paste stack was verified.</citation>

### Signature UX

<citation refs="3KENVlutZjXviJagzFH1F,sT4g5oNcwEXBsjlajLRic">A compact native popup, positioned at the cursor by default: **open → type → choose**. Much less visual chrome than a full clipboard workspace.</citation>

### Default hotkeys

- <citation refs="3KENVlutZjXviJagzFH1F">**Global:** `⇧⌘C` opens Maccy.</citation>
- <citation refs="3KENVlutZjXviJagzFH1F,e78wKhVAWvP4mvU4AMqvf">**Popup:** `Return` copies by default; `⌥Return` pastes; `⇧⌥Return` pastes plain text; `⌥P` pin/unpin; `⌥Delete` delete; `⌥⌘Delete` clear unpinned; `⇧⌥⌘Delete` clear everything; `⌃Space` preview. Automatic-paste preferences change the selection behavior.</citation>
- <citation refs="3KENVlutZjXviJagzFH1F">`⌥`-click menu icon toggles ignoring capture; `⇧⌥`-click ignores the next copy.</citation>

### Price

<citation refs="6F9TU7lGE0-SAKZGLDUFX,q-WoOXI5xIDd8WgLc04lj,UdHjVvuxJSISCdvDcyGux">**Free** via official GitHub/Homebrew; **$9.99** on the US App Store to support development. MIT open source; no subscription.</citation>

---

## 7. PastePal

**Official:** [indiegoodies.com/pastepal](https://indiegoodies.com/pastepal)

**Purpose:** A power-user clipboard workstation with collections, queues, transforms, and flexible interfaces.

### Core features

- <citation refs="mO8en_eJvvwbeOfHYNTD6,gDb6S_AlRkzJuF3LBqxOR">Text/rich text, images, links, PDFs, colors, emoji, and file references; searchable history; source-app/type/date filters; collections, tags, naming, locking, and manual snippets.</citation>
- <citation refs="peGGhmaLVs80OrQROhhHm,7Cf7mZjKDLEwUWpLQ-KHa,aatZATUex94zz7QkQPJs6">Main Window, four-edge Side Window, pinned or detached window, hover-triggered Hot Edge, and release-to-select Quick Mode.</citation>
- <citation refs="UhFpv6GF277MbfTd5NEv_,zEz_FQls_-c4s2_wsQm6U">Up to ten paste queues; sequential or paste-all operation; insertion order; separators; case, JSON, Base64, URL, sorting/hash, whitespace, tracking-parameter transforms, and custom JavaScript transforms.</citation>
- <citation refs="TyvdWCcFbwL7LfAQ2_Wih,gDb6S_AlRkzJuF3LBqxOR,YD3LJBkSMrRfjawktMjmz,45_m6QSp91zH1OPOKzwki">Image OCR, screen-region text capture, QR/barcode reading, plain-text conversion, previews, drag-and-drop, automatic cleanup, recoverable Trash, CSV export, and app/type/pattern exclusions.</citation>
- <citation refs="O0CEtMM2uwIV3aekMv-8-,zfVvbOUHeAP13ViGypnzQ,apGLskuqMG1YodFZXedyD">Optional iCloud sync, nearby-device Peer Share, screen-sharing hiding, and MCP access for approved clients. iCloud sync is off by default.</citation>

**File caution:** <citation refs="ugz9OqQkONGAy7i4MO_gq">Finder-dragged files are references, not backups; dragging them back into Finder can move the original.</citation>

### Signature UX

The distinctive pattern is **a clipboard drawer that adapts to where the user works**, plus keyboard-release Quick Mode and multiple persistent queues.

### Default hotkeys

- **Global:** Activation, capture, and queue actions are configurable; factory key combinations were not established by the inspected docs.
- <citation refs="NOmbMwn3aLRcm0UeFEcR6">**Side Window:** `Return` paste; `⇧Return` plain text; `Space` preview; `⇧Space` plain-text preview; `⌘F` search; `⌘1–9` numbered clip; `⌘L` lock; `⌘I` details; `⌘[/]` previous/next collection; `⌘V` paste from stack.</citation>

### Price

<citation refs="Z8C-XpEGrl09yMVag61nd,9cnWy2iZGeWrsXlT7SIts,MByzIG1mAh_ixD8P-fTQC">**$14.99 one-time Pro unlock**, three-day full-feature trial. Universal App Store purchase covers Mac/iPhone/iPad and Family Sharing, with future updates. Standalone is also **$14.99**, but covers one Mac activation without iOS or Family Sharing.</citation>

---

## 8. Bartender

**Official:** [macbartender.com](https://www.macbartender.com/)

**Purpose:** Advanced menu-bar organization, overflow access, and contextual automation.

### Core features

- <citation refs="76OoGG4L-L1r17LWBtww2,-NI-QJjRMQFVrlFGzpzSI">Hide/reveal/reorder items; spacing; groups and separators; overflow Bartender Bar; keyboard search; hover/click/scroll/swipe activation; pointer-positioned access.</citation>
- <citation refs="rBxLEGEcg9VBikxNAUb17,76OoGG4L-L1r17LWBtww2">Menu-bar styling, per-Space appearance, presets, monitor-specific setups, and automations based on battery, power, network, location, time, schedules, or scripts.</citation>
- <citation refs="r_YTyh3hHfuMYktRdVV_X,76OoGG4L-L1r17LWBtww2">Command Bar, custom action widgets, Shortcuts/App Intents, AppleScript, configuration import/export/backups, and an option to work without Screen Recording permission by showing app icons instead of captured menu-item images.</citation>
- <citation refs="rBxLEGEcg9VBikxNAUb17">**Pro-only Top Shelf:** Notch/island interface with audio controls, weather, calendar, one-day clipboard history, file shelf/AirDrop, and coding-agent activity monitoring.</citation>

### Signature UX

<citation refs="76OoGG4L-L1r17LWBtww2">**Keep the bar quiet until needed.** Hidden items appear on hover or gesture; search and the pointer-positioned bar avoid hunting across a crowded menu bar.</citation>

### Default hotkeys

- **Global defaults:** Unverified. Show/hide, search, Focus Mode, presets, individual items, and pointer-bar actions are configurable.
- <citation refs="r_YTyh3hHfuMYktRdVV_X">**Contextual clipboard results:** `↑/↓` select; `Return` activate/paste.</citation>

### Price

<citation refs="r2Y18xNNgX44fyT6wqjb0,76OoGG4L-L1r17LWBtww2,R-bcCiH7grX48fWLz_Dyd">Official advertised prices: **Bartender 7 $25 one-time**, **Pro $20/year**, **Mega Supporter $80 lifetime launch price**. Launch text uses $24.99/$19.99, so final checkout rounding is unverified. Standard includes version-7 updates; Pro includes future majors while subscribed; Mega includes lifetime upgrades. Personal license covers personally owned/used Macs.</citation>

---

## 9. Ice

**Official:** [icemenubar.app](https://icemenubar.app/) · [Repository](https://github.com/jordanbaird/Ice)

**Purpose:** Free, open-source menu-bar hiding, organization, and appearance customization.

### Core features

<citation refs="IJ8o21AqN5gGAD8keicxM">Hidden and always-hidden sections; hover/click/scroll/swipe reveal; automatic rehide; hide app menus when they overlap revealed items; drag-and-drop layout editor; separate Ice Bar for overflow/notch situations; menu-item search; beta item-spacing controls; tint, shadow, border, rounded/split styling; login launch and automatic updates.</citation>

**Important boundary:** <citation refs="IJ8o21AqN5gGAD8keicxM">Profiles, item groups, individual spacers, conditional triggers, and widgets are unchecked roadmap items in the inspected repository, not shipped features.</citation>

### Signature UX

<citation refs="NId76qcHGvgPTCi1PqAxO,8xyRLvWGtdRjIlK02VtVU">A lightweight divider-based organization model, with a secondary Ice Bar and fuzzy search that can activate the selected menu item.</citation>

### Default hotkeys

- <citation refs="QbH3-mSLlAw4t9vhdu4EU,J6V79dve8MvgODr_03dz8">**Global:** None assigned in the inspected source. Users assign hidden-section, always-hidden-section, search, Ice Bar, divider, and app-menu toggles.</citation>
- <citation refs="p_O_54Wo9tOR5AtL6iCm_,8xyRLvWGtdRjIlK02VtVU">**Search:** `↑/↓`, `Return`, `Esc`. `⌥`-click the control item toggles always-hidden items when enabled; right-click opens its menu.</citation>

### Price

<citation refs="IJ8o21AqN5gGAD8keicxM">**Free**, donation-supported, GPL-3.0 open source.</citation>

---

## 10. Rectangle

**Official:** [rectangleapp.com](https://rectangleapp.com/)

**Purpose:** Free keyboard- and drag-based window snapping and positioning.

### Core features

<citation refs="1fcjdzmoRBsqQODJrH7Kn,jqu1h327WWWQgHg3qmfZ_">Halves, quadrants, thirds/two-thirds, fourths, sixths; maximize/almost-maximize/maximize-height; center/restore; enlarge/shrink; move without resizing; previous/next display; repeated-command cycling; portrait-aware layouts; edge/corner snapping with previews; custom snap areas; Todo reserved-space mode; ignored apps; keyboard/mouse-button shortcuts; JSON settings import/export; URL-scheme actions. Current repository also documents row/column multiwindow tiling and stacked-window cycling.</citation>

### Signature UX

<citation refs="jqu1h327WWWQgHg3qmfZ_">Drag to a screen region and see a **footprint preview before release**. Repeating a command can cycle through related sizes instead of requiring another shortcut.</citation>

### Default hotkeys

For the **Rectangle/Magnet-style preset**:

<citation refs="93gy9jSC-fsXq8vJu1NzD">
- `⌃⌥←/→/↑/↓`: left/right/top/bottom half.
- `⌃⌥U/I/J/K`: top-left/top-right/bottom-left/bottom-right.
- `⌃⌥Return`: maximize; `⌃⌥C`: center; `⌃⌥Delete`: restore.
- `⌃⌥= / −`: larger/smaller.
- `⌃⌥⇧↑`: maximize height.
- `⌃⌥⌘←/→`: previous/next display.
- `⌃⌥D/F/G`: first/center/last third.
- `⌃⌥E/T`: first/last two-thirds.
</citation>

<citation refs="93gy9jSC-fsXq8vJu1NzD,PRlkxGu0BrZiVRA2SdC2r">A selectable Spectacle preset uses different bindings, including `⌘⌥`+arrows for halves. Existing installations may retain older/custom bindings.</citation>

### Price

<citation refs="1fcjdzmoRBsqQODJrH7Kn,VCHiyvNp4IddzsSBvt2sr">**Free**, MIT open source.</citation>

**Separate product:** <citation refs="daAHGo3H4Q6NTnOD_wbn_,Io6jg47U4PWt6llv7BLtR,MzK3TN5ijtM5uwbxCqWUd">Rectangle Pro adds gesture-based Window Throw, arbitrary placements, workspace layouts, custom snap panels, edge stashing, and advanced automation. Observed regional price: **₩13,656 one-time**, three devices, ten-day trial. Lifetime use does not guarantee every future paid upgrade.</citation>

---

## 11. Magnet

**Official:** [magnet.crowdcafe.com](https://magnet.crowdcafe.com/)

**Purpose:** A polished paid window manager centered on snapping and familiar shortcuts.

### Core features

<citation refs="_70fpsxTx4swKeN6rzfx5,b5wVzZshdXFDIvXSqoyiQ,JKTiayDODVw3KFYujmH4V">Halves, quarters, thirds/two-thirds, maximize, center, restore, and display movement; configurable edge trigger areas; snapping previews; keyboard shortcuts; menu-bar actions; green-window-button integration; unlimited custom commands; appearance/layout customization; optional iCloud sync; portrait monitors and up to six external displays. It arranges windows within a Space, not across Spaces.</citation>

### Signature UX

<citation refs="b5wVzZshdXFDIvXSqoyiQ,XqfKvCZuovl_SXJLN_seS">Drag to an edge/corner, preview, release. Bottom-edge gestures create thirds, with continued movement expanding into two-thirds.</citation>

### Default hotkeys

Officially published stock bindings, not a fresh-install test of the latest release:

<citation refs="XqfKvCZuovl_SXJLN_seS">
- `⌃⌥`+arrows: halves.
- `⌃⌥U/I/J/K`: quarters.
- `⌃⌥⌘←/→`: previous/next display.
- `⌃⌥C`: center.
- `⌃⌥Return`: maximize.
- `⌃⌥Delete`: restore.
</citation>

Third/two-third current default bindings were not verified from official material.

### Price

<citation refs="_70fpsxTx4swKeN6rzfx5,b5wVzZshdXFDIvXSqoyiQ">**$4.99 one-time** on the US App Store. No subscription or IAP; developer advertises free updates.</citation>

---

## 12. PopClip

**Official:** [popclip.app](https://www.popclip.app/)

**Purpose:** A contextual action toolbar that appears beside selected text.

### Core features

- <citation refs="UjF7b9nwDRAf6z-A9aebm">Cut/copy/paste, web search, detected-link opening, Dictionary lookup, selected file-path reveal, and spelling suggestions. Custom search engines, multiple-link opening, exact-phrase search, and plain-text actions.</citation>
- <citation refs="4T1sg2Z-Aeka7aOb0jST3,YTAbFJC8UeAjhZJKVYBjC">Extension actions for transformations, translation, sharing, and app/service integrations; action folders/separators, ordering, duplicates, custom labels/icons, and extension updates.</citation>
- <citation refs="t9DITZrzzGI9saHNvx692,cIoH36ZFO8J5fdpU7zWGh">iCloud sync of extensions/settings, app/site exclusions, configurable appearance, automatic-appearance toggle, optional keyboard invocation, and AppleScript triggering.</citation>

### Signature UX

<citation refs="xJTk2nXUAg0mblTn3XC-N">**Select text and act beside it**, without moving to a launcher. Long-press for about 0.5 seconds can summon actions without a selection. Holding `⌘` while selecting suppresses the toolbar.</citation>

### Default hotkeys

- <citation refs="t9DITZrzzGI9saHNvx692">**Global:** No preassigned activation combination verified. The developer’s `⌃⌘P` example is a personal choice, not a default.</citation>
- <citation refs="xJTk2nXUAg0mblTn3XC-N,UjF7b9nwDRAf6z-A9aebm">**Keyboard mode:** `←/→` choose action; `↑/↓` enter/leave folders; `Return` execute; `Esc` dismiss. `⇧` with cut/copy/paste uses plain text; `⌥` with Search requests an exact phrase; `⇧` with Search/Open Link uses a background tab where supported.</citation>

### Price

The [live purchase page](https://www.popclip.app/buy) displayed South Korean pricing:

- **Standard: ₩18,000 one-time.**
- **Lifetime: ₩43,000 one-time.**

<citation refs="lVgRZgT4PbacOWDvF3EVg,nyIzDXOhWAriCnFwKyX-l">Standard includes two years of updates and continued use afterward; Lifetime includes future product updates. Personal use on up to five Macs. Fully functional trial begins purchase reminders after 250 actions.</citation>

---

## 13. TextSniper

**Official:** [textsniper.app](https://textsniper.app/)

**Purpose:** Extract editable text from anything visible on screen.

### Core features

<citation refs="VKSDR-uphk3So3aYe91b7,VcCo8GDqXWz-QT63ojg2e,DGxc8TT8EuQwUKcEP3Umr">On-device OCR from images, PDFs, videos, games, and other apps; automatic language detection; multilingual and vertical CJK recognition; preserve/remove line breaks; custom vocabulary; repeat previous region; QR/barcode decoding; optional link opening; additive extraction across multiple captures; persistent accumulated-text history; text-to-speech; adjustable speech rate; iPhone/iPad camera/scanning input; configurable sound and notification behavior.</citation>

**Boundary:** Additive Clipboard accumulates extracted text; it is not general clipboard history.

### Signature UX

<citation refs="VKSDR-uphk3So3aYe91b7,VcCo8GDqXWz-QT63ojg2e">**Hotkey → draw a rectangle → paste text.** No document import, editor window, or export workflow.</citation>

### Default hotkeys

- <citation refs="VKSDR-uphk3So3aYe91b7">**Global:** `⌘⇧2` Capture Text.</citation>
- <citation refs="VcCo8GDqXWz-QT63ojg2e">**Capture-mode documented defaults:** `⌘L` line-break toggle; `⌘H` additive-history toggle; `⌘S` text-to-speech toggle. These are customizable and historically documented. Other global actions require assignment.</citation>

### Price

<citation refs="5jICLFcxXUtzbklWbxxLC,-uH04ov6a2hdoJOplsWC0,DGxc8TT8EuQwUKcEP3Umr">Direct listings advertise **$7.99 for one Mac** or **$9.99 for three Macs**. The fetched US App Store price is **$9.99**. All are one-time purchases; major future upgrades may cost extra. Some official homepage price text conflicts with the listings, so direct checkout pricing remains unverified.</citation>

---

## 14. Dropover

**Official:** [dropoverapp.com](https://dropoverapp.com/)

**Purpose:** A temporary floating shelf for collecting, processing, and moving dragged content.

### Core features

- <citation refs="TwJGyQ0-yPQCRpOcE_lut,DmSoofsgXRfw8_F7uBwUW">Files, folders, images, links, and text; multiple shelves; naming/color coding; favorites; edge docking; recent-shelf recovery; Quick Look, rename/reorder/remove, and clipboard integration.</citation>
- <citation refs="TwJGyQ0-yPQCRpOcE_lut,2Y1NmRTUVB73ix1FrZtYx">Image resizing/conversion, OCR, ZIP creation, Instant Actions, folder watching, screenshot collection, Share-menu/AirDrop actions, Command Bar, custom scripts, Shortcuts, Services, and launcher integrations.</citation>
- <citation refs="Djai0yWWCnenplOP4mbbe">Cloud upload providers and Dropover Cloud sharing, including passwords, expiry, link revocation, and direct-download options. Dropover Cloud advertises 1 GB free/10 GB Pro.</citation>

**File behavior:** <citation refs="2Y1NmRTUVB73ix1FrZtYx">Adding a Finder file stores a reference. It does not automatically copy or upload the file.</citation>

### Signature UX

<citation refs="TwJGyQ0-yPQCRpOcE_lut">**Shake while dragging → drop onto shelf → release the mouse → navigate → drag out.** The shelf removes the need to hold a drag while searching for the destination.</citation>

### Default hotkeys

<citation refs="J2q5_s--HBRtd5qxywoyp">
- **Global, enabled:** `⌥⇧Space` new shelf; `⌥⇧A` shelf from clipboard; `⌥⇧S` select shelf.
- **Assigned but disabled initially:** `⌥⇧R` recent shelf; `⌃⌥W` close all; `⌥⇧D` toggle docked shelves.
- **Active shelf:** `Space` Quick Look; `⌘K` Command Bar; `⌘W` close; `⇧D` dock; `⌘C/V` copy/paste contents; `Return` action menu.
</citation>

### Price

<citation refs="TwJGyQ0-yPQCRpOcE_lut,DmSoofsgXRfw8_F7uBwUW">**$7.99 one-time Pro unlock**. Full 14-day trial; afterward free use continues with a three-second shelf-interaction delay.</citation>

---

## 15. Yoink

**Official:** [yoink.app/mac](https://yoink.app/mac/)

**Purpose:** An automatically appearing edge shelf for moving files and app content between destinations.

### Core features

<citation refs="SSIdm5Lj2xPL5E26Bmy-8,dzy8Qz7bLHB5XRkDoaL1C,sKaU0ydRTA3x2oR57qCdZ">Finder files and draggable content; multi-file Stacks; thumbnails and Quick Look; pinned/locked items; recall of removed items; reveal in Finder; clipboard history; app exclusions; Handoff; Continuity Camera; Share extensions; Services/Quick Actions; Shortcuts, Terminal, and Automator integration; menu-bar drop target; customizable edge/cursor placement.</citation>

<citation refs="jpniLd3ZkoetdYcvADeSJ">Recent Photos integration exposes original RAW files, unedited originals, bursts, and Live Photo video, preserving supported original video properties.</citation>

### Signature UX

<citation refs="SSIdm5Lj2xPL5E26Bmy-8">**Begin dragging and the edge shelf appears automatically.** Multi-file drops become a single Stack, keeping the staging area compact.</citation>

### Default hotkeys

<citation refs="sKaU0ydRTA3x2oR57qCdZ">
- **Global:** `F5` show/hide.
- Hold `F5` about one second: restore previously removed items.
- Double-press `F5`: add clipboard contents.
- During dragging: `⌥` forces copy; `⌘` forces move.
- The “Add Selected Files to Yoink” Finder Service has a user-assigned shortcut, not a verified default.
</citation>

### Price

<citation refs="SSIdm5Lj2xPL5E26Bmy-8,NeKwB9PKmhZo-F5AnPdPL">**$8.99 one-time**; 28-day direct trial. Direct personal license has two activations. Published terms include free updates/upgrades while the app exists. iPhone/iPad app is a separate purchase; Setapp is another access channel.</citation>

---

## 16. Amphetamine

**Official:** [Mac App Store](https://apps.apple.com/us/app/amphetamine/id937984704)

**Purpose:** Keep the Mac awake manually or while specified conditions remain true.

### Core features

<citation refs="27BlKnSceJZPgFi_C-ZoJ">
- Sessions that run indefinitely, for a duration, until a time, while an app runs, or while a file downloads.
- Separate controls for system sleep, display sleep, screensaver, locking, and periodic pointer movement.
- Conditional Triggers for displays, mirroring, USB/Bluetooth devices, apps/frontmost app, battery/charging, power adapter, networks/IP/DNS/VPN, audio output, mounted volumes, CPU use, and idle time.
- Drive Alive, low-battery stopping, inactivity locking, AppleScript, remaining-time display, and customizable menu icons/sounds.
</citation>

<citation refs="27BlKnSceJZPgFi_C-ZoJ,5-D-bKRt2xXU0_x10P4s9">Closed-lid operation exists, but Apple Silicon power-state changes can require the separately installed Power Protect helper/configuration. It is not universally helper-free.</citation>

### Signature UX

**Temporary sessions instead of permanent system-setting changes.** A manual timer handles the simple case; Triggers automate recurring situations.

### Default hotkeys

- <citation refs="rO6saRzNqRHWc1-rGJ--s">Global session/menu/display/screensaver shortcuts are configurable; exact factory assignments were not verified.</citation>
- <citation refs="rO6saRzNqRHWc1-rGJ--s">**Menu context:** `⌘F` starts “While File is Downloading…”, not a global command.</citation>

### Price

<citation refs="27BlKnSceJZPgFi_C-ZoJ">**Completely free**, without ads, IAPs, or a Pro unlock.</citation>

---

## 17. iStat Menus

**Official:** [bjango.com/mac/istatmenus](https://bjango.com/mac/istatmenus/)

**Purpose:** Detailed, customizable system monitoring directly in the menu bar.

### Core features

<citation refs="FeqUS41ApSdCbuOVjHcdn,re3WcvssYzdxCUnrSZc6v,ofzSdubRWtpMWpGiQkqU5">
- **CPU/GPU:** Usage, cores, histories, load, frequency, uptime, and top processes; supported GPU memory/temperature readings.
- **Memory:** Pressure, compression, swap, history, and top consumers.
- **Disk:** Capacity, activity, per-app usage, and S.M.A.R.T.
- **Network:** Upload/download, history, per-app bandwidth, IP addresses, and connectivity.
- **Power/sensors:** Battery state, Bluetooth battery levels, temperatures, fans, voltage/current/power, and supported frequencies.
- **Clock/weather:** Calendar events, world clocks, sun/moon information, current weather, and detailed forecasts.
- **Rules:** Threshold/state notifications and actions.
- **Customization:** Colors, order, visible sections, and Combined mode.
</citation>

<citation refs="afc9Q-pLe8EFxgWNlxhCB">Fan control is available in the direct version, not the App Store version. Some readings require iStat Menus Helper.</citation>

### Signature UX

<citation refs="Pi1e4OgrTajdJbWL5_MtD,_ssa3v_gE4-E1Cn63ss7p">**Glanceable numbers first, detailed graphs on click.** Combined mode consolidates many modules into one menu-bar item.</citation>

### Default hotkeys

<citation refs="JAgu0zL4cWkrq_gnjR55X">User-configured through Rules to open/close module menus. No fixed factory combination is documented.</citation>

### Price

- The [live direct-purchase panel](https://bjango.com/mac/istatmenus/) displayed **₩18,029 single** or **₩22,540 family**, plus applicable local tax.
- <citation refs="re3WcvssYzdxCUnrSZc6v,CijGXNK6NQ4RVgEzHJKUJ">US App Store: **$11.99**. Direct licenses cover the current major release; standard allows three primarily personal computers, family up to five household computers. Fourteen-day direct trial.</citation>
- <citation refs="VSFopqygQEw_mxBM-M8-2,re3WcvssYzdxCUnrSZc6v">Direct licenses include six months of weather; additional nonrenewing packs start at **$2.49/12 months**. App Store weather instead lists **$0.99/month or $4.99/year** subscriptions.</citation>

---

## 18. Stats

**Official:** [mac-stats.com](https://mac-stats.com/) · [exelban/stats](https://github.com/exelban/stats)

**Purpose:** Free, open-source menu-bar system monitoring.

### Core features

<citation refs="LrF9-6SdVzMXIXvDw0rIj,AK7pCyG-jU-QlfmCwYlYv,INCQK1gEDS98AKkKVCCPu">CPU usage/frequency/temperature/top processes; GPU utilization/memory/temperature where supported; RAM pressure/swap/top consumers; disk capacity/activity/SMART; sensors and fan speeds; network rates/traffic/IPs; battery health/cycles/time/power source; Bluetooth battery levels; clocks/calendar/time zones; customizable widgets, sampling intervals, per-core/cluster views, and optional desktop widgets.</citation>

<citation refs="INCQK1gEDS98AKkKVCCPu,zcGmn1X696vw81w016yFT">Fan control is legacy/unmaintained. Hardware sensor availability varies; Sensors and Bluetooth are comparatively expensive polling modules.</citation>

### Signature UX

<citation refs="LrF9-6SdVzMXIXvDw0rIj">Small, independently configurable indicators open detailed module popups. Users choose the measurements they care about rather than opening a large dashboard.</citation>

### Default hotkeys

<citation refs="IHRCjEz1GBpbbfy1RwAMN,16cOqSK3eCuXRWXbK3OCw">Per-module popup shortcuts exist but are **unassigned by default** in the inspected source.</citation>

### Price

<citation refs="LrF9-6SdVzMXIXvDw0rIj,OB_1gGKEFc38kaso7Z2rJ">**Free**, MIT open source, without a subscription for the local app. Separately linked hosted monitoring services are not included in that statement.</citation>

---

## 19. Hand Mirror

**Official:** [handmirror.app](https://handmirror.app/)

**Purpose:** An instant camera and microphone check before a call.

### Core features

<citation refs="PHBH_t1N4qis_n-0_rp56,bUhVc-fTMx03fKXxyN8XR">Menu-bar camera preview; floating preview; camera/microphone selection. Plus adds microphone-level checking, Polaroid-style Snaps with drawing, macOS Reactions controls, resizable/draggable always-on-top Smart Window, zoom/crop/window masks, custom shape/border radius, saved position, custom icons, and notch activation.</citation>

### Signature UX

<citation refs="PHBH_t1N4qis_n-0_rp56">**Click the menu-bar icon or below the notch and immediately see yourself.** The preview can sit near the physical camera, then disappear when no longer needed.</citation>

### Default hotkeys

- **Global toggle:** A keyboard shortcut is supported, but its factory combination was not verified.
- <citation refs="bUhVc-fTMx03fKXxyN8XR">**Camera window:** `Space` takes a Snap; `Escape` is handled in the camera window. Current release notes explicitly limit these keys to that window.</citation>

### Price

<citation refs="bUhVc-fTMx03fKXxyN8XR,PHBH_t1N4qis_n-0_rp56">Free core. **Hand Mirror Plus $6.99 one-time**, including future Plus features. A **$12.99 “Generous”** purchase and optional tips support the developer.</citation>

---

## 20. BetterDisplay

**Official:** [betterdisplay.pro](https://betterdisplay.pro/)

**Purpose:** Advanced external-display control, scaling, brightness, and virtual-screen management.

### Core features

- <citation refs="D0waRc2EfTHvUhejhllIA">HiDPI scaling and custom resolutions; resolution slider/favorites; refresh rate/VRR, rotation, color modes/profiles, and XDR presets; display configuration protection; visual display arrangement and adaptive layout controls.</citation>
- <citation refs="D0waRc2EfTHvUhejhllIA">Hardware DDC and software brightness/dimming; volume/mute/input/power controls; native-key integration; synchronized brightness, including nits-based normalization; HDR/XDR extra brightness on compatible displays.</citation>
- <citation refs="D0waRc2EfTHvUhejhllIA">Virtual screens, headless-display modes, mirroring, display connect/disconnect, auto-disconnect of the built-in screen, local streaming, Picture in Picture for displays/windows, cropping/rotation, teleprompter flipping, and Sidecar adaptations.</citation>
- <citation refs="D0waRc2EfTHvUhejhllIA">Color temperature/contrast/sharpening/geometry adjustments, custom 3D LUTs, video filters, EDID overrides/export, connection diagnostics, HDMI-CEC and supported network TV/receiver controls.</citation>
- <citation refs="D0waRc2EfTHvUhejhllIA">Shortcuts/App Intents, CLI, URL/HTTP integration, per-display scripts on connection/sleep events, custom OSDs, and Control Center-style sidebar.</citation>

**Boundary:** Hardware, connection, Mac model, macOS version, and license tier determine availability.

### Signature UX

<citation refs="D0waRc2EfTHvUhejhllIA,WpaSmGY6lVZKAAS-mhAGz">Treat external monitors more like built-in Apple displays: **native brightness/volume keys, immediate OSD feedback, and per-display sliders instead of monitor buttons**.</citation>

### Default hotkeys

<citation refs="WpaSmGY6lVZKAAS-mhAGz">
- Native brightness and volume/mute handling is enabled by default, subject to permissions/support.
- `F14/F15` alternative brightness keys are enabled by default.
- `⇧⌥` with brightness/volume: fine adjustment.
- `⌃`+brightness: built-in display.
- `⌃⌘`+brightness: external displays.
- `⌥`+brightness/audio: Displays/Sound settings.
- `⌘`+brightness-down: mirroring action.
</citation>

Other custom actions require assignment.

### Price

<citation refs="VlnNEDPrVSnPthENyh8wn">Free features for nonbusiness users. **Pro $21.99 / €19.99 one-time**, fourteen-day trial, current major version plus at least one year of updates including major releases during that year. Business use requires a license even for continued use of otherwise-free features.</citation>

---

## 21. Itsycal

**Official:** [mowglii.com/itsycal](https://www.mowglii.com/itsycal)

**Purpose:** A tiny menu-bar calendar with agenda access and keyboard navigation.

### Core features

<citation refs="z8keFaDro813PmsX_irUs,sz674bPqVqKN-bgGntymJ,FGRW2A5Q54AL1YRcO3waZ">Month view and selected calendar events; create/delete events; virtual-meeting links; ISO week numbers; configurable first weekday; optional hourly sound; custom menu-bar date/time text; dark/light themes; text-size choices; extra calendar rows/up to two months; pin-open behavior; date jumping; Vim motions with repeat counts; URL scheme; integration with the default calendar app.</citation>

**Boundary:** The repository describes event creation/deletion, not full event editing.

### Signature UX

<citation refs="sz674bPqVqKN-bgGntymJ">Click the date, glance at the month and agenda, optionally **pin the popup**, and navigate dates without opening a full calendar app.</citation>

### Default hotkeys

- **Global opening:** User-assigned.
- <citation refs="sz674bPqVqKN-bgGntymJ">**Popup:** `←/→` month; `↑/↓` year; `⇧←/→` day; `⇧↑/↓` week; `Space` today; `P` pin; `W` week numbers; `⌘N` new event; `⌘J` join first active meeting; `⌘O` open calendar; `⇧⌘T` go to date; `⌥⌘R` refresh; `⌃J/K` add/remove rows. Vim equivalents and numerical repeat counts are supported.</citation>

### Price

<citation refs="z8keFaDro813PmsX_irUs,FGRW2A5Q54AL1YRcO3waZ">**Free**, MIT open source.</citation>

---

## 22. Command X

**Official:** [sindresorhus.com/command-x](https://sindresorhus.com/command-x)

**Purpose:** Add familiar cut-and-paste file movement to Finder.

### Core features

<citation refs="48UlorrLAdvqDJNFRPCyJ,FydxnB8Roh60yLF6lXsd8">Intercepts cut/paste in Finder and translates them into Finder’s native copy/move commands; runs in the background; supports files and folders, with ForkLift support also advertised. Files remain untouched until paste occurs.</citation>

**Limitations:** <citation refs="48UlorrLAdvqDJNFRPCyJ">Keyboard-only, not Finder’s Paste menu item; cannot dim “cut” files; interferes with cutting text in Finder filename-edit/search fields. Enter the destination folder before pasting.</citation>

### Signature UX

**No new interface to learn.** It restores cross-platform muscle memory for one frequent task.

### Default hotkeys

<citation refs="48UlorrLAdvqDJNFRPCyJ">`⌘X` marks files for moving; `⌘V` moves them. Internally this maps to `⌘C`, followed by Finder’s `⌥⌘V`.</citation>

### Price

<citation refs="48UlorrLAdvqDJNFRPCyJ,FydxnB8Roh60yLF6lXsd8">**$4 one-time** on the US App Store.</citation>

---

# 2. Product implications

## Build shared capabilities, not 22 separate mini-apps

My recommendation is a **local-first command and content layer** with several lightweight interfaces:

1. **Command palette:** Search and execute everything.
2. **Content drawer:** Clipboard history, screenshots, snippets, and extracted text.
3. **Floating shelf:** Temporary drag-and-drop staging.
4. **Contextual toolbar:** Actions on selected text or an existing item.
5. **Menu-bar popovers:** Status, quick controls, and optional monitoring.

A screenshot should be one shared object that can be annotated, OCR-searched, pinned, copied, or dragged to a shelf. Those should not become separate copies in unrelated databases.

## Cross-cutting MVP requirements

These are product recommendations rather than claims about every competitor:

- **Local operation by default:** No account required for capture, history, window management, or basic utilities.
- **Permission-on-demand:** Ask for screen recording, accessibility, camera, microphone, and calendars only when enabling the relevant feature.
- **Privacy controls:** Excluded apps, confidential-pasteboard filtering, retention limits, pause capture, and immediate deletion.
- **Central shortcut registry:** Detect conflicts and distinguish global from contextual bindings. Paste Stack and Maccy both use `⇧⌘C`; launchers both default to `⌥Space`.
- **Shared action system:** The same “Copy plain text,” “Extract text,” or “Move to collection” action should work from the palette, drawer, and shelf.
- **Optional modules:** Monitoring and advanced display functionality should not impose background cost on users who disable them.
- **Explicit file semantics:** Clearly distinguish a file reference, copied file, moved original, and uploaded object.
- **Safe extensibility:** Scripts, AI, and MCP access should be opt-in with visible access boundaries. Local storage alone does not prevent an authorized external client from uploading retrieved content.

---

# 3. Deduplicated feature matrix and MVP priorities

**Priority definitions**

- **MUST:** Required for a coherent first release.
- **SHOULD:** Strong early follow-up or public-beta feature.
- **NICE:** Specialist, operationally expensive, or later-stage capability.

**Scope assumption:** A focused MVP should excel at **capture → retrieve → act**, plus window control. It should not attempt full Raycast, CleanShot, and BetterDisplay parity simultaneously.

Capabilities appear once below. For example, OCR belongs to **Text tools**, even when invoked from Capture or Clipboard. Representative apps refer back to the sourced profiles above.

## Capture

| Deduplicated capability | Representative apps | Priority |
|---|---|---|
| Area, window, and fullscreen screenshots; precise selection; repeat last region | CleanShot X, Shottr | **MUST** |
| Floating post-capture thumbnail with copy, save, edit, dismiss, and drag-out | CleanShot X, Shottr | **MUST** |
| Crop/resize; arrows, shapes, text, highlighter, numbered steps; opaque redaction | CleanShot X, Shottr | **MUST** |
| Recent-capture recovery using the shared history store | CleanShot X, Raycast | **MUST** |
| Scrolling capture, including long pages and panels | CleanShot X, Shottr | **SHOULD** |
| Pin screenshots above other windows; resize, opacity, click-through | CleanShot X, Shottr | **SHOULD** |
| Timed capture, frozen screen, shadow/background controls | CleanShot X, Shottr | **SHOULD** |
| Background/padding presets and multi-image composition | CleanShot X, Shottr | **SHOULD** |
| Pixel ruler, color picker, contrast checking, magnifier callouts | Shottr | **NICE** |
| MP4/GIF recording, system/mic audio, webcam, cursor/click/key overlays | CleanShot X | **NICE** |
| Smart zooms, cursor smoothing, recording studio/editor | CleanShot X | **NICE** |
| Hosted sharing, expiry/passwords, comments, transcription, team branding | CleanShot X, Shottr | **NICE** |

## Clipboard

| Deduplicated capability | Representative apps | Priority |
|---|---|---|
| Local history for text, rich text, images, links, and file references | Paste, Maccy, PastePal, Raycast | **MUST** |
| Instant search with keyboard navigation and clear copy/paste actions | All clipboard apps | **MUST** |
| Plain-text paste and preservation of original rich content | Paste, Maccy, PastePal | **MUST** |
| Source-app/type/date metadata, previews, and Quick Look | Paste, PastePal, Maccy | **MUST** |
| Favorites/pins that survive cleanup | Paste, Maccy, PastePal | **MUST** |
| Retention limits, app exclusions, secret filtering, pause, clear history | All clipboard apps | **MUST** |
| Collections/Pinboards, labels/tags, rename and edit | Paste, PastePal | **SHOULD** |
| Ordered paste stack/queue and multi-item paste with separators | Paste, PastePal | **SHOULD** |
| Compact list and optional visual-card drawer backed by the same history | Maccy, Paste, PastePal | **SHOULD** |
| Numbered quick access and permanent pinned-item shortcuts | Paste, Maccy, PastePal | **SHOULD** |
| Export/import, recoverable Trash, duplicate handling | PastePal; partial elsewhere | **SHOULD** |
| Cross-device sync and nearby-device sharing | Paste, PastePal | **NICE** |
| Shared/team collections with access permissions | Paste | **NICE** |
| Context-aware suggestions and permissioned MCP access | Paste, PastePal | **NICE** |

## Launcher

| Deduplicated capability | Representative apps | Priority |
|---|---|---|
| Global command palette with fuzzy search and recent/frequent ranking | Raycast, Alfred | **MUST** |
| App launching and search across the super-app’s own commands/content | Raycast, Alfred | **MUST** |
| Action Panel: one result, multiple discoverable operations | Raycast, Alfred | **MUST** |
| Aliases, favorites, direct action hotkeys, conflict detection | Raycast, Alfred | **MUST** |
| Basic file/folder search, reveal, open, and preview | Raycast, Alfred | **SHOULD** |
| Calculator and unit/date/currency conversions | Raycast, Alfred | **SHOULD** |
| Parameterized web searches, Quicklinks, app deeplinks | Raycast, Alfred | **SHOULD** |
| Local scripts, arguments, URL scheme, Shortcuts integration | Raycast, Alfred | **SHOULD** |
| Selected-object action chooser | Alfred | **SHOULD** |
| Visual workflow builder and public extension marketplace | Alfred, Raycast | **NICE** |
| AI chat, model routing, agents, scheduled AI work, provider billing | Raycast | **NICE** |

## Window

| Deduplicated capability | Representative apps | Priority |
|---|---|---|
| Halves, quarters, thirds/two-thirds, maximize, center, restore | Rectangle, Magnet, Raycast | **MUST** |
| Customizable global snapping shortcuts | Rectangle, Magnet, Raycast | **MUST** |
| Edge/corner dragging with a destination preview | Rectangle, Magnet | **MUST** |
| Move between displays; handle portrait displays and app minimum sizes | Rectangle, Magnet | **MUST** |
| Per-app exclusions and reliable previous-size restoration | Rectangle, Magnet | **MUST** |
| Repeated-command size cycling, gaps, larger/smaller, custom placements | Rectangle, Raycast, Magnet | **SHOULD** |
| Multiwindow row/column tiling and saved layouts | Rectangle, Rectangle Pro, Raycast | **SHOULD** |
| Restore layouts on monitor changes; app/window-title matching | Rectangle Pro | **NICE** |
| Pointer-based move/resize and radial Window Throw | Rectangle Pro | **NICE** |
| Edge stashing, reveal tabs, cross-Space movement | Rectangle Pro | **NICE** |

## Menu bar

| Deduplicated capability | Representative apps | Priority |
|---|---|---|
| One consolidated menu-bar entry for the super-app’s own modules | iStat Menus Combined, Raycast | **MUST** |
| Hide/reveal third-party items; normal/hidden/always-hidden sections | Bartender, Ice | **SHOULD** |
| Overflow drawer that remains usable around the notch | Bartender, Ice | **SHOULD** |
| Hover/click/scroll reveal and predictable auto-rehide | Bartender, Ice | **SHOULD** |
| Search and activate menu-bar items from the shared palette | Bartender, Ice | **SHOULD** |
| Drag-and-drop item ordering and spacing controls | Bartender, Ice | **SHOULD** |
| Work/presentation presets, monitor-aware setups, conditional reveal | Bartender | **NICE** |
| Groups, spacers, labels, extensive styling | Bartender; partial Ice | **NICE** |
| Custom widgets and notch/island dashboard | Bartender Pro | **NICE** |

## Drop shelf

| Deduplicated capability | Representative apps | Priority |
|---|---|---|
| Temporary file/text/link/image staging with drag-in/drag-out | Dropover, Yoink | **SHOULD** |
| Shake-to-summon, edge-on-drag, or explicit shortcut activation | Dropover, Yoink | **SHOULD** |
| Multiple-item stacks, preview, remove, and reveal in Finder | Dropover, Yoink | **SHOULD** |
| Pin items and restore recently closed/removed contents | Dropover, Yoink | **SHOULD** |
| Explicit copy/move/reference behavior | Dropover, Yoink | **SHOULD** |
| Send shared capture/clipboard objects directly to a shelf | Dropover, Yoink | **SHOULD** |
| Multiple named shelves, edge docking, colors, favorites | Dropover | **NICE** |
| ZIP, image conversion/resizing, watched folders, Instant Actions | Dropover | **NICE** |
| AirDrop/Share-menu routing and cloud-provider uploads | Dropover, Yoink | **NICE** |
| Handoff, Continuity Camera, original Photos-media extraction | Yoink | **NICE** |

## System monitor

| Deduplicated capability | Representative apps | Priority |
|---|---|---|
| Optional CPU, memory-pressure, network-rate, battery, and disk-free indicators | Stats, iStat Menus | **SHOULD** |
| Click-through histories and top resource-consuming processes | Stats, iStat Menus | **SHOULD** |
| Adjustable sampling and strictly disabled polling for inactive modules | Stats, iStat Menus | **SHOULD** |
| Threshold alerts for disk space, load, battery, and connectivity | iStat Menus | **SHOULD** |
| Per-core/cluster GPU and CPU detail; temperature/power sensors | Stats, iStat Menus | **NICE** |
| Per-app network/disk accounting and SMART diagnostics | iStat Menus, Stats | **NICE** |
| Bluetooth accessory batteries and desktop widgets | Stats, iStat Menus | **NICE** |
| Fan control and temperature-based fan curves | iStat Menus direct; legacy Stats | **NICE** |

## Text tools

| Deduplicated capability | Representative apps | Priority |
|---|---|---|
| Shared on-device OCR for screen regions and stored images | TextSniper, CleanShot X, Shottr, PastePal | **MUST** |
| Index extracted image text in shared history search | Paste, PastePal, Raycast | **MUST** |
| Preserve/remove line breaks and combine repeated extractions | TextSniper, Shottr | **SHOULD** |
| QR/barcode extraction through the same capture engine | TextSniper, Shottr, PastePal | **SHOULD** |
| Contextual selected-text toolbar with copy/search/open/dictionary | PopClip | **SHOULD** |
| Shared transforms: case, whitespace, URL cleanup, JSON, encoding | PastePal, PopClip extensions | **SHOULD** |
| Reusable snippets and keyword expansion with dynamic placeholders | Alfred, Raycast | **SHOULD** |
| Configurable toolbar actions and per-app/site exclusions | PopClip | **SHOULD** |
| Custom JavaScript transforms and extension actions | PastePal, PopClip | **NICE** |
| Custom OCR vocabulary, text-to-speech, camera/scanned-document input | TextSniper | **NICE** |
| Translation, dictation, and AI rewriting | Raycast, PopClip integrations | **NICE** |

## Misc

| Deduplicated capability | Representative apps | Priority |
|---|---|---|
| Keep-awake toggle with duration, visible status, and automatic expiry | Amphetamine | **SHOULD** |
| Finder cut/paste behavior with clear limitations and safe fallback | Command X | **SHOULD** |
| Calendar popup, agenda, today navigation, and meeting-link launch | Itsycal, Raycast | **SHOULD** |
| One-click camera preview and microphone-level check | Hand Mirror | **SHOULD** |
| External-display brightness/volume using native keys | BetterDisplay | **SHOULD** |
| Conditional keep-awake triggers and Drive Alive | Amphetamine | **NICE** |
| Calendar event creation, world clocks, hourly chime | Itsycal, iStat Menus | **NICE** |
| Floating camera masks, notch trigger, Snaps, Reactions | Hand Mirror | **NICE** |
| Display profiles, refresh/rotation, DDC input switching, synchronized brightness | BetterDisplay | **NICE** |
| HiDPI overrides, HDR boosting, virtual screens, PiP/streaming, EDID/TV control | BetterDisplay | **NICE** |
| Focus sessions and app/site blocking | Raycast | **NICE** |
| Weather and rich forecast data | iStat Menus, Bartender Pro | **NICE** |
| Lightweight searchable notes and task lists | Raycast | **NICE** |
