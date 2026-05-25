# Reference search — implementation brief

Hand this verbatim to the Android session. It explains the exact
GS API contract behind the iOS "Search references" screen + a
suggested Kotlin/Compose implementation.

---

## What it should do

A search screen reachable from the Scanner tab (sibling of the
live barcode scanner). The user types in a search field; below
it, a paginated list of `Reference` rows shows. Tapping a row
opens the reference detail.

Behaviour:

- **Empty query** → server returns the most recent references.
  Show them as-is.
- **Non-empty query** → match on `smalltext` (display name + SKU
  + brand are all part of `smalltext`). The iOS app wraps the
  value in `*` wildcards (`smalltext=*pink*`) for substring match.
- **300 ms debounce** before firing the search — avoid one HTTP
  per keystroke.
- **Infinite scroll** — when the user reaches the bottom of the
  list, fetch the next page using the `offset` header.

## GS REST contract

### Endpoint

```
GET <baseURL>/reference
```

`baseURL` is `https://api-19.grand-shooting.com/v3` for the
default tenant. The numeric shard (`19`) is configurable in
Settings (`DevSettings.gsAPIShard`).

### Headers

| Header | Value |
|---|---|
| `Authorization` | `Bearer <token>` — current OAuth access token, or the dev API key stored in the Keystore as a fallback. |
| `Accept` | `application/json` |
| `offset` | **The offset is a request HEADER, not a query param.** Integer, 0-based. Send only when paginating (omit for the first page). |

### Query parameters

All optional. Most useful ones for the search screen:

| Param | Type | Notes |
|---|---|---|
| `smalltext` | string | Multi-field substring search. **Wrap with `*` on both sides** for substring match: `smalltext=*pink*`. Without wildcards GS expects an exact match. |
| `ref` | string | Single-shot exact lookup by catalog ref. Used by the barcode scan flow when the user has set `searchAttribute = .ref`. |
| `ean` | string | Single-shot exact lookup by EAN. Used by the barcode scan flow when `searchAttribute = .ean` (the default). |

For the **search-screen use case** you only need `smalltext` —
the user types freely, you wrap with `*…*`, you send. Empty
query = no params at all (server returns the recent feed).

### Response

Body: a JSON array of `Reference` objects. Headers carry the
pagination metadata:

| Response header | Meaning |
|---|---|
| `X-Total-Count` | Total number of items matching the query on the server. May be missing on some queries — treat as `null` then. |
| `X-Offset` | Offset of the first item returned in this page. |
| `X-Count` | Number of items returned in this page. |

**Computing `hasMore`:** when `X-Total-Count` is present,
`hasMore = X-Offset + X-Count < X-Total-Count`. When it's
absent, conservatively assume `hasMore = (X-Count > 0)` and stop
when the server returns an empty page.

The next page is fetched by setting the `offset` request header
to the previous `nextOffset = X-Offset + X-Count`. The page size
is **fixed by the server** — you don't send a `limit`.

### Reference shape

Full schema lives in
`Packages/GSAPIClient/Sources/GSAPIClient/openapi.yaml` (search
for `Reference:`). The minimum fields the row needs:

```json
{
  "reference_id": 12,
  "ref": "FW19_ALDA_PINK",
  "ean": "2309309834098",
  "smalltext": "Pink leather handbag Alda",
  "univers": "RTW",
  "gamme": "Accessories",
  "family": "Handbags",
  "category_id": 1
}
```

Note that `reference_id` is sometimes a string, sometimes a
number depending on the endpoint — the iOS client decodes both
with a fallback. Worth doing the same in Kotlin (a
`@JsonNames(["reference_id"])` with a custom `Int`-or-`String`
deserializer).

## Sample requests

First page, empty query:

```
GET /v3/reference HTTP/1.1
Host: api-19.grand-shooting.com
Authorization: Bearer eyJhbGciOi…
Accept: application/json
```

User types "pink", debounced for 300 ms, first page:

```
GET /v3/reference?smalltext=*pink* HTTP/1.1
Authorization: Bearer eyJhbGciOi…
Accept: application/json
```

Second page of the same query:

```
GET /v3/reference?smalltext=*pink* HTTP/1.1
Authorization: Bearer eyJhbGciOi…
Accept: application/json
offset: 50
```

(50 is whatever `X-Offset + X-Count` evaluated to on page 1.)

## Suggested Kotlin / Compose implementation

Sketch — adjust to your existing DI / HTTP setup.

### Retrofit / Ktor service

Using Retrofit for concreteness:

```kotlin
interface ReferenceApi {
    @GET("reference")
    suspend fun search(
        @QueryMap query: Map<String, String>,
        @Header("offset") offset: Int? = null,
    ): Response<List<ReferenceDto>>
}
```

`@QueryMap` lets you pass the optional `smalltext` /
`ean` / `ref` filters without hard-coding them. `@Header("offset")`
sends it as a header when not null.

### Paginated repository

```kotlin
class ReferenceSearchRepository(private val api: ReferenceApi) {

    data class Page(
        val items: List<Reference>,
        val nextOffset: Int?,   // null when there's nothing more
    )

    suspend fun search(query: String, offset: Int = 0): Page {
        val q = if (query.isBlank()) emptyMap() else mapOf("smalltext" to "*$query*")
        val response = api.search(query = q, offset = offset.takeIf { it > 0 })

        val items = response.body().orEmpty().map { it.toDomain() }
        val total = response.headers()["X-Total-Count"]?.toIntOrNull()
        val pageOffset = response.headers()["X-Offset"]?.toIntOrNull() ?: 0
        val count = response.headers()["X-Count"]?.toIntOrNull() ?: items.size

        val hasMore = total?.let { pageOffset + count < it } ?: (count > 0)
        return Page(items, nextOffset = if (hasMore) pageOffset + count else null)
    }
}
```

### ViewModel with debounce + paging

```kotlin
class ReferenceSearchViewModel(
    private val repo: ReferenceSearchRepository,
) : ViewModel() {

    private val _query = MutableStateFlow("")
    val query: StateFlow<String> = _query

    data class UiState(
        val items: List<Reference> = emptyList(),
        val isLoading: Boolean = false,
        val error: String? = null,
        val nextOffset: Int? = 0,   // 0 = need to load page 1
    )

    private val _state = MutableStateFlow(UiState())
    val state: StateFlow<UiState> = _state

    init {
        viewModelScope.launch {
            _query
                .debounce(300.milliseconds)
                .distinctUntilChanged()
                .collectLatest { refresh(it) }
        }
    }

    fun setQuery(value: String) { _query.value = value }

    private suspend fun refresh(q: String) {
        _state.value = UiState(isLoading = true)
        runCatching { repo.search(q, offset = 0) }
            .onSuccess { page ->
                _state.value = UiState(items = page.items, nextOffset = page.nextOffset)
            }
            .onFailure { e ->
                _state.value = UiState(error = e.localizedMessage)
            }
    }

    fun loadMoreIfNeeded(lastVisibleIndex: Int) {
        val s = _state.value
        val next = s.nextOffset ?: return
        if (s.isLoading) return
        if (lastVisibleIndex < s.items.size - 5) return   // hysteresis

        viewModelScope.launch {
            _state.value = s.copy(isLoading = true)
            runCatching { repo.search(_query.value, offset = next) }
                .onSuccess { page ->
                    _state.value = s.copy(
                        items = s.items + page.items,
                        nextOffset = page.nextOffset,
                        isLoading = false,
                    )
                }
                .onFailure { e ->
                    _state.value = s.copy(isLoading = false, error = e.localizedMessage)
                }
        }
    }
}
```

### Compose UI

```kotlin
@Composable
fun ReferenceSearchScreen(
    viewModel: ReferenceSearchViewModel,
    onPick: (Reference) -> Unit,
) {
    val query by viewModel.query.collectAsState()
    val state by viewModel.state.collectAsState()
    val listState = rememberLazyListState()

    // Auto-load more when scrolled near the bottom.
    LaunchedEffect(listState) {
        snapshotFlow { listState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0 }
            .distinctUntilChanged()
            .collect { lastVisible -> viewModel.loadMoreIfNeeded(lastVisible) }
    }

    Column {
        OutlinedTextField(
            value = query,
            onValueChange = viewModel::setQuery,
            placeholder = { Text("ref, label, sku, ean…") },
            leadingIcon = { Icon(Icons.Default.Search, null) },
            modifier = Modifier.fillMaxWidth().padding(12.dp),
        )

        when {
            state.items.isEmpty() && !state.isLoading && state.error == null -> {
                Text("No references found.", modifier = Modifier.padding(24.dp))
            }
            state.error != null -> {
                ErrorRow(state.error!!) { viewModel.setQuery(query) /* retry */ }
            }
            else -> LazyColumn(state = listState) {
                items(state.items, key = { it.ref }) { ref ->
                    ReferenceRow(ref) { onPick(ref) }
                }
                if (state.isLoading) {
                    item { Box(Modifier.fillMaxWidth().padding(16.dp)) {
                        CircularProgressIndicator(Modifier.align(Alignment.Center))
                    } }
                }
            }
        }
    }
}
```

## Lessons learned (already paid for on iOS)

These are the gotchas. Read them before debugging.

1. **`offset` is a HEADER, not a query param.** First time
   through the GS docs everyone tries `?offset=50` first and
   gets ignored / page 1 again. Send it via the `offset:` HTTP
   header.

2. **Substring matching needs wildcards.** Without `*…*` around
   the user's input, `smalltext=pink` returns *exact-match* rows
   only. Always wrap.

3. **`X-Total-Count` is optional.** Some queries (especially
   broad ones) omit it. Detect "got an empty page" as the stop
   condition, don't rely on `total` alone.

4. **`reference_id` type drift.** Some endpoints return it as a
   number, some as a string. The shape is identical otherwise.
   Write the deserializer to accept both — see how iOS does it
   in `Packages/GSAPIClient/Sources/GSAPIClient/Domain/Reference.swift:79`.

5. **Auth header at the last moment.** The OAuth token may
   rotate between request creation and execution. Inject
   `Authorization` in an OkHttp `Interceptor` (not when building
   the Retrofit call), so each retry picks up the latest token.

6. **401 → refresh, then retry once.** The iOS app does this
   automatically via `GSAuthSession.shared.currentToken()`. On
   Android, wrap it in an OkHttp `Authenticator` so the retry is
   transparent to the calling code.

7. **Retry-with-backoff before surfacing errors.** Transient GS
   slowness happens. The iOS app retries 3× with 0.8 s / 1.8 s
   gaps before showing a red banner. Wrap your call in something
   equivalent — flow `retryWhen` works fine.

8. **Don't show "no results" while loading.** During the
   debounced refresh, `items` will be empty AND `isLoading`
   true. Guard the empty-state UI with both conditions, or you
   flash "No references found" for one frame on every keystroke.

## iOS reference files

If the Android Claude session needs to verify behaviour:

- API surface: `Packages/GSAPIClient/Sources/GSAPIClient/Services/ReferenceLookupService.swift`
- HTTP client + pagination: `Packages/GSAPIClient/Sources/GSAPIClient/Pagination/GSHTTPClient.swift` (lines 148–162 + 166–211)
- Pagination decode: `Packages/GSAPIClient/Sources/GSAPIClient/Pagination/PaginationInfo.swift`
- iOS UI flow: `GSApp/Scan/ReferenceSearchView.swift`
- Schema (authoritative): `Packages/GSAPIClient/Sources/GSAPIClient/openapi.yaml`, schema `Reference`
- Domain model + decode quirks: `Packages/GSAPIClient/Sources/GSAPIClient/Domain/Reference.swift`
