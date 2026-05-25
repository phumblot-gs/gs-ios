# Batch detail: filter zone (ref + EAN + statuses)

Hand this brief to the Android session. Adds a server-side
filter UI above the batch contents list, mirroring what just
landed on iOS.

---

## Three filters above the contents list

A new "Filters" section sits between the batch metadata card
and the paginated contents:

| Control | Behaviour |
|---|---|
| **Ref** text field | Free-text substring search on `reference.ref`. Sent server-side as `?ref=*<value>*` (wildcards mandatory for substring on GS — exact match without). |
| **EAN** text field + scan button | Exact-match search on `reference.ean`. The button opens a barcode scanner; on hit, the scanned payload fills the field. Sent server-side as `?ean=<value>` (verbatim, no wildcards — scans want exact). |
| **Statuses** multi-select | Dropdown menu with one toggle per enabled status (from `DevSettings.enabledStockItemStatuses`). Default selection = all enabled (≈ no filter). |

The three controls are **server-side**: every change rebuilds
the paginated request. Typing is debounced 300 ms; toggling a
status fires immediately.

## API contract

```
GET /v3/stock
  ?batch_id=<id>
  &ref=*<query>*           (optional, only when non-empty)
  &ean=<query>             (optional, only when non-empty)
  &stock_item_status=<encoded>   (optional)
Authorization: Bearer <token>
offset: <header, see paginated-list prompt>
```

### Encoding `stock_item_status`

Three cases — the iOS code:

| Selection | Param sent |
|---|---|
| All enabled statuses checked (default) | **omitted** — no filter |
| Empty selection (user unchecked everything) | **omitted** — same fallback, no-op UI |
| Exactly one status | `stock_item_status=10` |
| Multiple but not all | `stock_item_status=in:10,12,15` |

**Caveat**: the `in:<csv>` operator is the GS API convention we
already use elsewhere (e.g. `picturestatus=gte:10` in
PictureService), but it's not formally documented for
`stock_item_status`. iOS ships with this assumption — verify on
your tenant. If GS rejects `in:`, fall back to firing N parallel
`/stock?…&stock_item_status=N` requests and merging the results
client-side (dedupe by `reference.ref`, page each independently).

## Default selection behaviour

When the screen mounts:
- `selectedStatuses = settings.enabledStockItemStatuses` (the
  whole set).
- That set equals the full enabled set → param omitted → no
  filter applied → user sees everything in the batch.

When the user unchecks one or more:
- Set becomes a proper subset → `in:` CSV is sent.
- Display label updates ("N selected" or "All").

The summary label uses three states:
- `All` — every enabled status is checked.
- `None` — none are.
- `N selected` — partial selection.

## Refresh on filter change

Every filter mutation must restart pagination from offset = 0.
On iOS we replace the `PaginatedLoader` instance with a new one
that captures the current filters; Android equivalent depends
on your pagination stack (Paging 3 with `PagingSource.invalidate()`,
or a manual `Flow<List<…>>` that re-emits).

Pattern:

```kotlin
class BatchDetailViewModel(
    private val batchID: Long,
    private val stockService: StockService,
    private val settings: DevSettings,
) : ViewModel() {

    data class Filters(
        val ref: String = "",
        val ean: String = "",
        val selectedStatuses: Set<Int>,
    )

    private val _filters = MutableStateFlow(
        Filters(selectedStatuses = settings.enabledStockItemStatuses)
    )

    val filters: StateFlow<Filters> = _filters
    val items: StateFlow<List<ReferenceStock>> = _filters
        .debounce { f ->
            // status changes fire immediately, ref/ean are
            // debounced — but a single MutableStateFlow only
            // emits whole snapshots. Use 300 ms wholesale; the
            // status toggle UX still feels instant.
            300.milliseconds
        }
        .distinctUntilChanged()
        .flatMapLatest { filters ->
            paginatedFlow(filters)
        }
        .stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())

    private fun paginatedFlow(filters: Filters): Flow<List<ReferenceStock>> =
        flow {
            val items = stockService.page(
                batchID = batchID,
                ref = filters.ref.trim().takeIf { it.isNotEmpty() },
                ean = filters.ean.trim().takeIf { it.isNotEmpty() },
                statuses = filters.selectedStatuses
                    .takeIf { effective ->
                        effective.isNotEmpty()
                            && effective != settings.enabledStockItemStatuses
                    },
            )
            emit(items)
        }

    fun setRef(v: String)    { _filters.update { it.copy(ref = v) } }
    fun setEAN(v: String)    { _filters.update { it.copy(ean = v) } }
    fun toggleStatus(id: Int) {
        _filters.update { f ->
            f.copy(selectedStatuses = f.selectedStatuses.toggle(id))
        }
    }
}

private fun <T> Set<T>.toggle(value: T): Set<T> =
    if (contains(value)) this - value else this + value
```

The `stockService.page(...)` signature on iOS:

```swift
func page(
    batchID: Int,
    offset: Int = 0,
    ref: String? = nil,
    ean: String? = nil,
    statuses: Set<Int>? = nil
) async throws -> (items: [ReferenceStock], pagination: PaginationInfo)
```

Mirror it on Kotlin. Internally it builds the query map as
described above.

## Compose UI sketch

```kotlin
@Composable
fun FiltersSection(state: Filters, vm: BatchDetailViewModel) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        // Ref — substring
        OutlinedTextField(
            value = state.ref,
            onValueChange = vm::setRef,
            label = { Text(stringResource(R.string.ref)) },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        // EAN + scan button
        Row(verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(
                value = state.ean,
                onValueChange = vm::setEAN,
                label = { Text("EAN") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Ascii),
                modifier = Modifier.weight(1f),
            )
            IconButton(onClick = { showScanner = true }) {
                Icon(Icons.Outlined.QrCodeScanner, contentDescription = "Scan EAN")
            }
        }
        // Status multi-select via DropdownMenu
        StatusFilterMenu(
            enabled = settings.enabledStockItemStatuses,
            selected = state.selectedStatuses,
            onToggle = vm::toggleStatus,
        )
    }
}

@Composable
fun StatusFilterMenu(
    enabled: Set<Int>,
    selected: Set<Int>,
    onToggle: (Int) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        OutlinedButton(onClick = { expanded = true }, modifier = Modifier.fillMaxWidth()) {
            Icon(Icons.Outlined.FilterList, null)
            Spacer(Modifier.width(8.dp))
            Text(stringResource(R.string.statuses))
            Spacer(Modifier.weight(1f))
            Text(summary(enabled, selected), color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        DropdownMenu(expanded, onDismissRequest = { expanded = false }) {
            StockItemStatus.orderedCases
                .filter { enabled.contains(it.code) }
                .forEach { status ->
                    DropdownMenuItem(
                        text = { Text(status.displayName) },
                        leadingIcon = {
                            if (selected.contains(status.code))
                                Icon(Icons.Default.Check, null)
                        },
                        onClick = { onToggle(status.code) }
                    )
                }
        }
    }
}

private fun summary(enabled: Set<Int>, selected: Set<Int>): String {
    val effective = selected intersect enabled
    return when {
        effective.isEmpty() -> /* R.string.none */ "None"
        effective == enabled -> /* R.string.all */ "All"
        else -> /* R.string.N_selected */ "${effective.size} selected"
    }
}
```

DropdownMenu's items don't dismiss on click by default — that
matches the iOS UX (user can toggle multiple statuses without
the menu closing). Tapping outside dismisses.

## Refresh-on-return interaction

The earlier handoff doc (`change-batch-and-batch-refresh.md`)
covered the lifecycle-based refresh when the user pops back from
a pushed reference detail. **That trigger should also rebuild
the loader with the current filters**, not just naively refetch
without them. On iOS this is now a single `rebuildLoader()`
method that re-binds the closure to the latest filter snapshot —
called from both `.onAppear` and `.refreshable`.

## String resources

| Key (en source) | fr | pl |
|---|---|---|
| `Filters` | `Filtres` | `Filtry` |
| `Ref` | `Ref` | `Ref` |
| `EAN` | `EAN` | `EAN` |
| `Statuses` | `Statuts` | `Statusy` |
| `Scan EAN` | `Scanner un EAN` | `Skanuj EAN` |
| `Aim at a barcode` | `Visez un code-barres` | `Wyceluj w kod kreskowy` |
| `All` | `Tous` | `Wszystkie` |
| `None` | `Aucun` | `Brak` |
| `%lld selected` (use `<plurals>` if you prefer) | `%d sélectionné(s)` | `%d zaznaczone` |

## iOS reference sites

If a behaviour clarification is needed:

- `GSApp/Scan/BatchDetailView.swift` — `filtersSection`,
  `statusFilterMenu`, `statusFilterSummary`, `rebuildLoader()`,
  `statusFilterPayload`, the debounce hooks, the
  `BatchContentsEANScanner` private view.
- `Packages/GSAPIClient/Sources/GSAPIClient/Services/StockService.swift`
  — `page(batchID:offset:ref:ean:statuses:)` extended signature.
