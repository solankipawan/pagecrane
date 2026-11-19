# Pagecrane — Architecture & Design Spec

> Working name was **PDFit**; renamed to **Pagecrane** because PDFit and Pagefold are both already used on the App Store.

All-in-one, offline-first PDF and image utility for iOS and Android.
Scan → edit → compress → share, with all processing done on the device.

---

## 1. Platform decision

| Option | Verdict |
|---|---|
| **Flutter 3.x (recommended)** | One codebase. Draws its own UI, so the glass effects and animations look the same on both platforms. Ships both Cupertino and Material 3 widgets, and has good plugins for scanning, PDF and images. |
| React Native (New Arch) | Also works, but the glass/blur effects and 60fps camera overlays need more native modules (Skia/Reanimated/VisionCamera frame processors). |

The rest of this doc assumes **Flutter**. Heavy processing happens in native code or in Dart isolates, so the UI thread never does pixel work.

### Core packages

| Concern | Package | Notes |
|---|---|---|
| Doc scanning (edge detect, auto-crop) | `cunning_document_scanner` | Uses **VisionKit** on iOS and **ML Kit Document Scanner** on Android: native edge detection, perspective correction and auto-capture. |
| Custom camera fallback | `camera` + `opencv_dart` | For a fully branded scanner UI: contour detection → 4-point warp, run in an isolate. |
| PDF render / view | `pdfrx` (PDFium) | Fast page rendering and text selection. |
| PDF create / merge / split | `pdf` (create), `syncfusion_flutter_pdf` (merge/split/annotate/sign) | Syncfusion has a community licence; check the terms before release. |
| Image ops | `image` (Dart, in an isolate) and `flutter_image_compress` (native) | Native compression handles HEIC/JPEG/PNG/WebP. |
| Storage / index | `drift` (SQLite) + `path_provider` | Files live in the app sandbox. The DB holds metadata, folders and the search index (FTS5). |
| Encryption at rest | `flutter_secure_storage` (key) + AES-GCM via `cryptography` | Optional "Secure Vault" folder protected by Face ID or fingerprint (`local_auth`). |
| Share / export | `share_plus`, `file_picker` | The system share sheet covers WhatsApp, Mail, Drive, iCloud Files. |
| State / routing | `flutter_riverpod`, `go_router` | |
| Motion | `flutter_animate`, built-in `HapticFeedback` | |
| Signature capture | `signature` | Saved as a transparent PNG, then stamped onto the PDF. |

---

## 2. Architecture

Clean architecture with feature modules. Each feature has its own `data / domain / presentation` folders.

```
┌───────────────────────────── Presentation (Flutter widgets) ─────────────────────────────┐
│  Dashboard · Scanner · Review · Files · Viewer/Annotator · Tools (Merge/Split/Compress)  │
│  Image Resizer · Converter · Settings          ← Riverpod Notifiers (UI state only)      │
└───────────────▲──────────────────────────────────────────────────────────────────────────┘
                │ use-cases (pure Dart)
┌───────────────┴───────────────── Domain ─────────────────────────────────────────────────┐
│  ScanDocument · ApplyFilter · MergePdfs · SplitPdf · CompressPdf · ResizeToTargetSize    │
│  ConvertImage · AnnotatePdf · SearchFiles      Entities: Doc, Page, Folder, Job          │
└───────────────▲──────────────────────────────────────────────────────────────────────────┘
                │ repository interfaces
┌───────────────┴───────────────── Data / Platform ───────────────────────────────────────┐
│  FileRepository (drift + sandbox FS)   PdfEngine (pdfium / syncfusion)                   │
│  ImageEngine (isolate pool + native)   ScannerBridge (VisionKit / ML Kit / OpenCV)       │
│  ShareService   VaultCrypto   ThumbnailCache (LRU, disk)                                 │
└──────────────────────────────────────────────────────────────────────────────────────────┘
```

**Job queue.** Every heavy operation (merge, compress, OCR, convert) is a `Job` on a `JobRunner`. The runner uses a pool of 2–4 isolates and reports progress as a stream. The UI shows a progress pill that you can tap to expand. Jobs survive navigation, and only one of each kind runs per file at a time.

**Speed targets:** cold start under 1.2s (deferred plugin init, skeleton dashboard), scan to preview under 300ms, thumbnail cache hit under 16ms.

### Flutter project layout

```
lib/
├── main.dart
├── app/
│   ├── app.dart                  # MaterialApp.router + theme switching
│   ├── router.dart               # go_router: shell route with bottom nav
│   └── theme/
│       ├── tokens.dart           # colors, radii, spacing, durations (see §4)
│       ├── app_theme.dart        # ThemeData light/dark, Material 3 dynamic color
│       └── glass.dart            # GlassSurface widget (BackdropFilter + specular edge)
├── core/
│   ├── jobs/job_runner.dart      # isolate pool + progress streams
│   ├── haptics.dart              # light/medium/success wrappers
│   ├── platform/adaptive.dart    # Cupertino vs Material switches
│   └── widgets/                  # Skeleton, PressableScale, AdaptiveSheet, EmptyState
├── features/
│   ├── dashboard/                # quick tools, recents, storage card
│   ├── scanner/
│   │   ├── data/scanner_bridge.dart        # VisionKit / ML Kit / OpenCV impls
│   │   ├── domain/filters.dart             # MagicColor, Grayscale, BW, Photo
│   │   └── presentation/
│   │       ├── scanner_screen.dart         # camera + quad overlay + batch tray
│   │       ├── review_screen.dart          # crop, rotate, filter, reorder
│   │       └── widgets/edge_overlay.dart
│   ├── files/                    # folders, search (FTS5), sort, multi-select
│   ├── viewer/                   # pdfrx viewer + annotation layer + signature pad
│   ├── pdf_tools/                # merge (ReorderableListView), split, compress
│   ├── image_tools/              # resize, DPI/quality, target-size, convert
│   └── settings/                 # theme, default filter, vault, storage
└── l10n/
```

---

## 3. Screen-by-screen user flow

```
Onboarding (3 cards, camera permission explained before the system prompt)
   │
   ▼
┌──────────── Bottom nav: Home · Files · [ ◉ Scan FAB ] · Tools · Settings ────────────┐
│                                                                                     │
│ HOME ─┬─ Search bar ───────────────► Files (search results)                         │
│       ├─ Quick tools grid ─────────► Tool screens                                   │
│       ├─ Recent documents ─────────► Viewer                                         │
│       └─ Storage card ─────────────► Files › Large files                            │
│                                                                                     │
│ SCAN FAB ► Scanner ► (auto-capture × N pages) ► Review ► Save sheet ► Viewer/Share  │
│                                                                                     │
│ FILES ► Folders / All / Starred / Vault 🔒 ► long-press: multi-select ► actions     │
│                                                                                     │
│ TOOLS ► PDF: Merge · Split · Compress · Sign │ Image: Resize · Target KB · DPI      │
│         Convert: JPG/PNG/HEIC → PDF · PDF → JPG/PNG                                 │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

| # | Screen | Key elements | Interactions |
|---|---|---|---|
| 1 | **Onboarding** | 3 glass cards: Scan, Edit, Private | Swipe; "Continue" asks for camera permission with context first |
| 2 | **Home** | Greeting, search, 8-tile quick tools, recents (skeleton while loading), storage ring | Pull to refresh, long-press a recent file for quick actions |
| 3 | **Scanner** | Live camera, animated edge quad, Auto/Manual toggle, flash, page counter, batch tray, shutter | Auto-capture once the quad holds steady for about 0.8s. Haptic tick when locked, success haptic on capture |
| 4 | **Review** | Page carousel, filter chips (Original · Magic · Gray · B&W · Photo), crop handles, rotate, delete, reorder | A filter can apply to one page or "Apply to all". Drag to reorder pages |
| 5 | **Save sheet** | Name (auto: "Scan 18 Nov 2026"), folder, format (PDF/JPG), quality, optional password | Save → Viewer, or Share directly |
| 6 | **Files** | Segmented: Recent / Folders / Starred, search, sort (date, name, size), grid/list | Swipe a row to share/delete; multi-select bar |
| 7 | **Viewer / Annotator** | pdfrx pages, toolbar: Highlight · Pen · Text · Sign · Comment | Annotations are kept on their own layer until "Flatten on export" |
| 8 | **Merge** | Picked files as reorderable cards with page counts, total size | Drag handles, swipe to remove, "Merge (12 pages)" |
| 9 | **Split** | Page-grid thumbnails, modes: ranges ("1-3, 7"), every N pages, select pages | Live output-file count |
| 10 | **Compress** | Low / Medium / High cards, each showing an estimated size and % saved | The estimate updates as you pick a level (see §5) |
| 11 | **Image Resize** | Size mode: px · % · **target KB**, keep aspect ratio, DPI field, format | Before/after size badge, batch support |
| 12 | **Convert** | From → To pickers, drop zone, queue list | Progress per file in the job pill |
| 13 | **Settings** | Theme (System/Light/Dark), default filter, auto-capture, vault, storage cleanup | |

---

## 4. Design system

### Color palette

| Token | Light | Dark | Use |
|---|---|---|---|
| `primary` (Iris) | `#4C5BFF` | `#8A94FF` | FAB, primary buttons, selection |
| `onPrimary` | `#FFFFFF` | `#0B0D14` | |
| `bg` | `#F3F4F9` | `#0A0C12` | App background (with a soft aurora gradient) |
| `surface` (glass) | `rgba(255,255,255,0.68)` | `rgba(30,33,46,0.55)` | Cards, nav bar, sheets, with 24px blur |
| `surfaceStroke` | `rgba(255,255,255,0.9)` | `rgba(255,255,255,0.10)` | Specular edge on glass |
| `text` | `#0E1120` | `#F2F3F8` | Body text (contrast ≥ 15:1) |
| `textMuted` | `#5A6077` | `#9CA2B6` | Secondary text (≥ 4.5:1 on bg) |
| `scan` (Teal) | `#0D9488` | `#2DD4BF` | Scanner category |
| `pdf` (Rose) | `#E11D48` | `#FB7185` | PDF tools |
| `image` (Violet) | `#7C3AED` | `#A78BFA` | Image tools |
| `convert` (Amber) | `#D97706` | `#FBBF24` | Converters |
| `success` / `danger` | `#16A34A` / `#DC2626` | `#4ADE80` / `#F87171` | Status |

On Android 12+, if the user turns on "Use wallpaper colors", `primary` is replaced by the Material You `ColorScheme.fromSeed(dynamic)`. The category colors stay fixed so users can still recognise each tool group.

### Type, shape, motion

- **Type:** SF Pro (iOS, system), Inter (Android/web). Scale: 34 / 28 / 22 / 17 / 15 / 13 / 11, with tabular numbers for file sizes.
- **Radii:** 12 for chips, 20 for cards, 28 for sheets, full for the FAB and pills. Continuous ("squircle") corners on iOS.
- **Elevation:** no hard shadows. Glass surfaces use a 1px top highlight plus a soft shadow `0 8 32 rgba(20,24,60,.10)`.
- **Motion:** 220ms `easeOutCubic` for UI, 350ms spring for sheets, press scale 0.96. All of this respects Reduce Motion.
- **Haptics:** `selectionClick` on chips and tabs, `lightImpact` when edges lock, `mediumImpact` on capture, success notification on save.
- **Icons:** Lucide (Android/web) and SF Symbols (iOS), 1.75px stroke, 24px grid.
- **Accessibility:** 44×44pt minimum touch targets, Dynamic Type up to XXL, every icon button has a semantic label, and the scanner announces "Document detected" and "Page 2 captured" to screen readers.

---

## 5. Key algorithms

### Compress to a target file size (image → under N KB)

```dart
/// Runs in an isolate. Returns the best JPEG under [targetBytes].
Future<Uint8List> compressToTarget(Uint8List src, int targetBytes) async {
  var img = decodeImage(src)!;
  for (var scale = 1.0; scale >= 0.2; scale *= 0.85) {          // shrink only if needed
    final frame = scale == 1.0 ? img : copyResize(img, width: (img.width * scale).round());
    int lo = 10, hi = 95; Uint8List? best;
    while (lo <= hi) {                                            // binary search on quality
      final q = (lo + hi) >> 1;
      final out = encodeJpg(frame, quality: q);
      if (out.length <= targetBytes) { best = out; lo = q + 1; } else { hi = q - 1; }
    }
    if (best != null) return best;
  }
  throw TargetTooSmallException();
}
```
It stays close to the target in about 7 encodes per scale step. The web prototype runs the same algorithm.

### PDF compression with a size estimate

1. Sort the PDF's objects: images vs. vector/text.
2. Levels: **Low** = re-encode images at q85 and 200 DPI. **Medium** = q65, 150 DPI. **High** = q45, 110 DPI, grayscale for scans.
3. **Estimate:** compress a sample of up to 3 of the largest images at each level, then work out `estimated = nonImageBytes + Σ(imageBytes × sampleRatio)`. This shows within about 300ms and is usually within ±10%. A full run happens only on confirm.

### Scanner filters (applied per pixel in an isolate, GPU shader for the live preview)

| Filter | Pipeline |
|---|---|
| **Magic Color** | Divide by a blurred background estimate (removes shadows), then contrast stretch (1st–99th percentile), saturation ×1.25 |
| **Grayscale** | Luma (0.299R+0.587G+0.114B) + contrast stretch |
| **B&W** | Grayscale → adaptive (Sauvola-style) threshold, 15px window |
| **Photo** | Light auto-levels + unsharp mask (r=1, amount 0.4) |

### Edge detection (custom-camera path)
Downscale to 480p → grayscale → Gaussian blur → Canny → find contours → largest 4-point convex polygon (`approxPolyDP`, ε=2% of perimeter) → smooth the corners over 5 frames. "Locked" means the corners move less than 1.5% of the frame diagonal for 0.8s. Output: a 4-point warp at full resolution.

---

## 6. Storage, privacy and sharing

- All files stay in the app sandbox (`ApplicationDocumentsDirectory/PDFit`, the working name, kept so earlier builds keep their documents), so they are private by default and excluded from the photo library.
- The **Vault** folder uses AES-256-GCM. The key is kept in the Keychain or Keystore and unlocked with biometrics.
- No network access is needed. Cloud services (Drive, iCloud) are reached only through the system share sheet or document picker, so the app never stores OAuth tokens.
- Search uses SQLite FTS5 over file names, folder names, and OCR text (optional, on-device ML Kit text recognition).

---

## 7. Web prototype

`prototype/` is a clickable, dependency-light HTML/CSS/JS demo of the design system:

- **Dashboard:** glass UI, quick tools, recents with skeleton loading, light/dark toggle.
- **Scanner:** live camera (or a simulated document if there is no camera), animated edge lock, auto-capture, batch tray, 5 working pixel filters, save to recents.
- **Tools:** working **Image → target KB** compressor (the binary search above), Merge with drag-to-reorder, and Compress with estimated sizes.

Open `prototype/index.html` in a browser (mobile size works best). For camera access, serve it over `localhost`.
