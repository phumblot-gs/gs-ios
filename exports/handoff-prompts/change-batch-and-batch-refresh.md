# Reference detail: "Change batch" button + Batch detail auto-refresh

Hand this verbatim to the Android session. Two related changes
the iOS app just shipped — repercute-les sur la même UI.

---

## 1. Stock-item card on the reference page

### What changes

Each stock-item card on the reference detail screen has a
"current status" + a primary button to change it. We now also
display the current **batch** and let the user move the stock
item to a different one.

| Before | After |
|---|---|
| Row "EAN: 2309309834098" | Row "Batch: <batch_name>" |
| Single primary button "Change status" | Two side-by-side buttons: secondary "Change batch" (left), primary "Change status" (right) |
| Buttons had SF Symbol icons | Plain text labels (no icons) |

The reference's EAN is already shown at the top of the screen
(on the reference card), so removing it from the stock-item card
isn't a loss.

### "Change batch" picker

Tapping the secondary button opens a modal sheet with:

- **Paginated list** of batches (`/stock/batch`, see the earlier
  reference-search prompt for the offset-as-header pagination
  convention).
- **Search field** at the top — client-side substring filter on
  `smalltext`, `code`, `type`, case-insensitive. Matches against
  whatever pages are already loaded (no extra HTTP per
  keystroke).
- **Scan button** (toolbar leading) — opens the barcode scanner;
  on hit, calls `/stock/batch?code=<scanned>` for the exact
  lookup and feeds the result through the same `onSelect`
  callback.
- **`+` button** (toolbar trailing) — opens the existing
  "Create a new batch" flow; on creation, the new batch is
  auto-selected as the move target.
- **Tap a row** → immediate PATCH (no confirmation step), sheet
  dismisses, parent splices the updated stock item into local
  state so the row refreshes without a re-fetch.

A checkmark marks the row of the batch the stock item is
currently in.

### PATCH call

```
PATCH /v3/stock/<stock_item_id>
Authorization: Bearer <token>
Content-Type: application/json

{
  "stock_item_status": <CURRENT status, preserved verbatim>,
  "batch_id": <NEW batch id>
}
```

**Critical**: re-send the **current** `stock_item_status`. The
endpoint validates the field, but the value must be unchanged so
the move is batch-only. The `smalltext` / `extra` fields from
the OpenAPI example payload are optional — don't send them
(otherwise you risk overwriting existing values with empty
ones).

### Resolving the batch name for display

The GS API has **no** `GET /stock/batch/<id>` endpoint — there's
only the paginated listing at `/stock/batch`. So you can't fetch
a single batch by id.

Strategy (mirror iOS):
- On the reference detail screen's first `.task` (or
  `LaunchedEffect(Unit)`), pre-fetch up to 2 pages of
  `/stock/batch` (~200 entries) into a `Map<Int, Batch>` cache
  scoped to the screen.
- Render `batchByID[item.batchId]?.displayName` if hit, else
  fallback to `"Batch #${item.batchId}"`.
- Beyond 200 batches the fallback is acceptable; tapping
  "Change batch" then loads the full paginated list anyway, so
  the user always sees the correct name in the picker.
- Pull-to-refresh on the reference screen should wipe this cache
  too.

### Kotlin sketch

```kotlin
// ViewModel
private val _batchByID = MutableStateFlow<Map<Long, Batch>>(emptyMap())
val batchByID: StateFlow<Map<Long, Batch>> = _batchByID

suspend fun loadBatchesForLookup() {
    if (_batchByID.value.isNotEmpty()) return
    val collected = mutableMapOf<Long, Batch>()
    var offset = 0
    repeat(2) {  // cap at 2 pages
        val page = runCatching { batchService.page(offset) }.getOrNull() ?: return@repeat
        page.items.forEach { collected[it.id] = it }
        if (!page.hasMore) return@repeat
        offset = page.nextOffset
    }
    _batchByID.value = collected
}

suspend fun moveStockItem(item: StockItem, newBatch: Batch) {
    val updated = stockService.update(
        id = item.id,
        payload = StockUpdatePayload(
            stockItemStatus = item.status.code,   // preserved
            batchId = newBatch.id,
        )
    )
    spliceUpdatedStockItem(updated)
    // optimistically cache the picked batch so the label updates
    // even before /stock refetches
    _batchByID.update { it + (newBatch.id to newBatch) }
}
```

```kotlin
// Compose UI — stock-item card body
Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
    RowKV(label = "Status", value = item.status.displayName)
    RowKV(label = "Batch", value = batchDisplayName(item))

    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        OutlinedButton(
            onClick = { showBatchPicker = true },
            enabled = !batchUpdating && !statusUpdating,
            modifier = Modifier.weight(1f),
        ) {
            if (batchUpdating) {
                CircularProgressIndicator(Modifier.size(16.dp))
                Spacer(Modifier.width(8.dp))
                Text(stringResource(R.string.moving))
            } else {
                Text(stringResource(R.string.change_batch))
            }
        }
        Button(
            onClick = { showStatusSheet = true },
            enabled = !statusUpdating && !batchUpdating,
            modifier = Modifier.weight(1f),
        ) {
            if (statusUpdating) {
                CircularProgressIndicator(Modifier.size(16.dp))
                Spacer(Modifier.width(8.dp))
                Text(stringResource(R.string.updating))
            } else {
                Text(stringResource(R.string.change_status))
            }
        }
    }
}
```

## 2. Batch detail page — refresh on return

### What changes

When the user is on the batch detail screen, taps a row to push
the reference detail, moves the stock item to another batch
inside that screen, and then taps back — the batch detail's list
of contents now refreshes automatically so the moved item
disappears.

### Why it's needed

Without this, the user sees a stale list. The status-change
flow has a similar concern (status badges can drift) but only
the **batch move** removes the row from the current batch
entirely, so missing the refresh is the most visibly wrong.

### Implementation pattern (mirrors iOS)

iOS uses `.onAppear` + a `didFirstAppear` flag so the first
display doesn't double-fetch alongside the initial `.task`
load. On Android with Compose, the moral equivalent:

```kotlin
@Composable
fun BatchDetailScreen(batch: Batch, ...) {
    var didFirstAppear by rememberSaveable { mutableStateOf(false) }
    val lifecycleOwner = LocalLifecycleOwner.current

    DisposableEffect(lifecycleOwner) {
        val obs = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) {
                if (didFirstAppear) {
                    viewModel.refresh()
                } else {
                    didFirstAppear = true
                }
            }
        }
        lifecycleOwner.lifecycle.addObserver(obs)
        onDispose { lifecycleOwner.lifecycle.removeObserver(obs) }
    }

    // Initial load via LaunchedEffect(Unit) → already handled
    // by your normal "load on first compose" pattern. Don't
    // remove it — both code paths coexist; the flag prevents
    // the double-fetch.
    ...
}
```

Alternative if you use Navigation Compose's `savedStateHandle`
or a more reactive pattern: post a "stock item moved" event
from the reference detail's ViewModel and have the batch
detail's ViewModel listen for it. Either works — the iOS
version is the simpler lifecycle-based one.

### Edge case to avoid

Don't refresh on every recomposition or every config change —
only on actual resume from a child screen. The `didFirstAppear`
flag (saveable across config changes) handles this.

## API summary

- `GET /v3/stock/batch?offset=…` — paginated listing (offset is
  a HEADER, see earlier prompt). Optional `?code=<exact>` for
  scan lookup.
- `PATCH /v3/stock/<stock_item_id>` — body
  `{stock_item_status, batch_id}`, both required. Preserve
  status, supply new batch_id.
- No `GET /v3/stock/batch/<id>` exists; resolve names via the
  paginated list cache.

## String resources to add

| Key (en source) | fr | pl |
|---|---|---|
| `Change batch` | `Change batch` | `Zmień partię` |
| `Change status` | `Change statut` | `Zmień status` |
| `Moving…` | `Déplacement…` | `Przenoszenie…` |
| `Batch` (label on the card) | `Batch` | `Partia` |
| `Pick a batch` (picker title) | `Choisir un lot` | `Wybierz partię` |
| `Search by name, code or type` (placeholder) | `Recherche nom, code ou type` | `Szukaj po nazwie, kodzie lub typie` |

(Free to translate the FR more cleanly — iOS settled on "Change
statut" / "Change batch" for visual brevity. If Android conventions
prefer fuller verbs, "Changer de batch" / "Changer de statut" are
fine.)

## iOS reference sites

- `GSApp/Scan/ReferenceDetailView.swift` — see
  `stockItemSection`, `moveToBatch(_:)`, `spliceUpdatedStockItem(_:)`,
  `loadBatchesForLookup()`, `batchLabel(for:)`.
- `GSApp/Scan/BatchPickerSheet.swift` — search + scan + create
  combined sheet.
- `GSApp/Scan/BatchDetailView.swift` — see the `didFirstAppear`
  flag + the `.onAppear` refresh hook.
- `Packages/GSAPIClient/Sources/GSAPIClient/Services/StockService.swift`
  — `UpdatePayload` + `update(id:payload:)`.
