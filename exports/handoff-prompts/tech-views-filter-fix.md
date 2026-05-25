# Tech-views: bench-step filter + filename matching by smalltext

Two fixes the Android side needs that the iOS side also had wrong.
Both apply to "list pictures uploaded for a reference, then bucket
them by capture mode (Measure / OCR / Presentation+Detail)".

---

## 1. Add `benchsteptype=10` to the picture-list call

GS pictures travel through a multi-step bench workflow. Step 10 is
the **technical-view** step; later steps belong to packshot
finals, colour proofs, etc. Without the filter we pick up rows we
shouldn't display in the tech-views section.

```
GET /v3/picture
  ?reference_ref=<ref>
  &shootingmethod=<shootingMethodName>
  &benchsteptype=10
  &picturestatus=gte:10
  &sort_by=-date_cre
```

(`picturestatus=gte:10` is unchanged — it keeps only stored /
validated rows, dropping in-flight upload states.)

**Sort direction**: `-date_cre` (descending) so that when GS
returns several rows with the same `smalltext` — e.g. the user
re-shot a filename, or status transitions duplicated the row —
the newest one comes first. Downstream code (`first(where:)`
for the Measurement illustration, dedup-by-filename for the
gallery) assumes newest-first.

## 2. Bucket pictures by `smalltext`, not `file_path`

Three on-screen buckets, all derived from the same picture list:

| Bucket | Pattern | Where it renders |
|---|---|---|
| Measures | `photoFilenameMeasurePattern` | Measures section (illustration thumbnail) |
| Metadata Labels | `photoFilenameOCRPattern` | Metadata section (Labels strip) |
| Tech views | everything else | Tech views section gallery |

The patterns are user-configurable templates (e.g.
`{EAN}_Measurement_{INC}.jpg`, `{EAN}_Label_{INC}.jpg`). Match
each picture's filename against the three patterns to decide
its bucket.

### The gotcha (this is what was wrong on iOS)

The picture API returns these three filename-ish fields:

| Field | Example |
|---|---|
| `smalltext` | `9782070643028_Article_1.jpg` |
| `file_path` | `JPG/9782070643028_Article-1.jpg` |
| `path` (deprecated) | `f33cdd25-…/JPG/9782070643028_Article-1.jpg` |

**GS rewrites the storage path on ingest**: the last `_N` in the
upload filename becomes `-N`, and the file lands under a `JPG/`
prefix. Only `smalltext` carries the original upload name
verbatim.

If your filename pattern was `{EAN}_Article_{INC}.jpg` and the
counter is at 1, the upload filename was `…_Article_1.jpg`. After
GS rewrites it, `file_path = JPG/…_Article-1.jpg`. Regexing
against the file_path's `lastPathComponent` **never matches** —
the `_1` is now `-1` and the regex expected `_<digits>`.

**Always match patterns against `smalltext`.** Fall back to
`file_path`'s `lastPathComponent` only when smalltext is missing
(legacy uploads).

### Kotlin sketch

```kotlin
data class Picture(
    val id: Long,
    val smalltext: String?,
    val filePath: String?,
    val path: String?,
    val thumbnail: String?,    // CDN URL
    // …
) {
    /** Filename to use when matching a local pattern. Prefer
     *  `smalltext` (preserved on upload); fall back to the
     *  storage path's last segment only when missing. */
    val matchableFilename: String?
        get() = smalltext?.takeIf { it.isNotEmpty() }
            ?: filePath?.substringAfterLast('/')
            ?: path?.substringAfterLast('/')
}

/** Returns true when `filename` could have been produced by
 *  `pattern` for the given `ean` / `ref` (any `{INC}` value). */
fun filename(filename: String, matchesPattern pattern: String, ean: String?, ref: String): Boolean {
    val eanValue = ean.takeUnless { it.isNullOrEmpty() } ?: ref
    val parts = pattern.split("{INC}")
    val regexBody = parts.joinToString("(\\d+)") {
        Regex.escape(
            it.replace("{EAN}", eanValue).replace("{REF}", ref)
        )
    }
    return Regex("^$regexBody$").matches(filename)
}

// Bucketing — `pictures` is expected newest-first
// (that's what `sort_by=-date_cre` gives us). We dedupe per
// filename keeping the FIRST occurrence (newest), then sort the
// final list by ascending filename for display.
fun bucket(pictures: List<Picture>, ean: String?, ref: String, patterns: Patterns): Buckets {
    val measure = mutableListOf<Picture>()
    val ocr = mutableListOf<Picture>()
    val techviews = mutableListOf<Picture>()
    for (p in pictures) {
        val name = p.matchableFilename ?: run { techviews.add(p); continue }
        when {
            filename(name, matchesPattern = patterns.measure, ean, ref) -> measure.add(p)
            filename(name, matchesPattern = patterns.ocr, ean, ref) -> ocr.add(p)
            else -> techviews.add(p)
        }
    }
    return Buckets(
        // For the Measure block we only ever show the latest one
        // — `.firstOrNull()` against the date-descending list.
        measure = measure.firstOrNull(),
        // Galleries: dedupe (keep first = newest), then sort
        // ascending by filename for display.
        ocr = ocr.distinctBy { it.matchableFilename }
                 .sortedBy { it.matchableFilename.orEmpty() },
        techviews = techviews.distinctBy { it.matchableFilename }
                             .sortedBy { it.matchableFilename.orEmpty() },
    )
}
```

## Pattern syntax recap

The patterns the user configures in Settings use three
placeholders:

- `{EAN}` — the reference's `ean`. Falls back to `{REF}` when the
  reference has no EAN.
- `{REF}` — the catalog reference.
- `{INC}` — 1-based capture counter, seeded from today's GS
  production so a re-capture on a different day starts back at 1.

Default templates (mirror these on Android):
- Presentation: `{EAN}_Article_{INC}.jpg`
- Detail: `{EAN}_Detail_{INC}.jpg`
- OCR: `{EAN}_Label_{INC}.jpg`
- Measurement: `{EAN}_Measurement_{INC}.jpg`

Always end with `.jpg`. Patterns that resolve to the same
filename family (e.g. someone sets Presentation and Detail to the
same template) share the `{INC}` counter so uploads never
overwrite each other.

## iOS reference sites

If verification is needed:

- `Packages/GSAPIClient/Sources/GSAPIClient/Services/PictureService.swift`
  — `listTechViews(...)` adds `benchsteptype=10`,
  `filenamesUploadedToday(...)` uses `picture.smalltext`.
- `Packages/GSAPIClient/Sources/GSAPIClient/Domain/Picture.swift`
  — `var matchableFilename: String?` extension.
- `GSApp/Scan/ReferenceDetailView.swift`
  — `latestMeasurementPicture`, `ocrPictures`,
  `presentationAndDetailPictures` all match on `matchableFilename`.
- `GSApp/Photo/TechViewsFilenameCounter.swift`
  — the regex builder (`static func filename(_:matches:ean:ref:)`)
  that the iOS code uses; mirror its semantics in Kotlin.
