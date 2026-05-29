# Ignition Designer — gotchas, pro tips, workflow rules

This file is the accumulated library of lessons from working on Ignition
projects. Read top-to-bottom before starting any Designer task. Append new
entries the moment you learn one (per the criteria in SKILL.md).

Two entry formats are used. Pick whichever fits:

- **One-liner pro tip** — for small recurring rules ("Use X for Y").
- **Detailed entry** — Symptom / Root cause / Fix for substantive gotchas.

Every entry has a `_Discovered: YYYY-MM-DD_` line so we can groom later.

---

## Workflow rules

These describe how to interact with Designer / the gateway / the user. Amend
them when you learn a better pattern.

### Check the component's built-in props BEFORE building a custom version
Ignition's stock components are richer than they look from a glance at the
"Add Component" menu. Before wiring a custom search input, custom pager,
custom selection toolbar, custom filter bar, etc., open the docs page for
the component you're using and skim its prop categories — there's almost
always a built-in feature for the obvious UX you're about to reinvent.

Quick examples that have bitten this skill:
- `ia.display.table` has `props.filter.enabled = true` — a built-in
  filter field with live row-count and as-you-type narrowing. We built a
  whole custom search field + bidirectional binding + `parts/list` :search
  param + onChange handlers to clear selection on filter, instead of just
  setting that one boolean.
- Same component has `props.pager.*` for pagination behavior (although
  `pager.pageSize` happens to be unreadable from gateway scripts; see the
  separate gotcha).

The component docs URLs follow:
```
https://www.docs.inductiveautomation.com/docs/8.3/appendix/components/perspective-components/<palette>/<component>
```
e.g. `perspective-display-palette/perspective-table`. The component
reference is grouped by palette (Display / Input / Container / etc.).
WebFetch them and grep the prop table for anything close to your custom
feature. If a built-in covers it, USE THE BUILT-IN. Custom is more code,
more drift surface, and almost always inferior to the stock UX (no
results count, no debounce, harder accessibility, etc.).
_Discovered: 2026-05-29_

### Direct disk edits are fine — just follow the propagation sequence
You CAN edit `view.json`, `code.py`, named-query `query.sql`, and
`resource.json` directly while the user has Designer open, provided you
follow the propagation sequence (next gotcha) and warn the user about the
conflict-on-update-project they'll see if the resource is currently open
in Designer.

Use a paste-into-Designer snippet instead when:

- The user has unsaved REAL changes on the resource (asterisk + the user
  hasn't asked you to discard them) — disk-editing then telling them to
  Revert Changes would throw away their work.
- The change is structural and easier through Designer's GUI than as JSON
  (e.g. column render modes, event subscriptions on a component).

Otherwise, prefer direct disk edits — they leave a git diff and don't
require the user to do tedious GUI clicks. _Discovered: 2026-05-21_

### Two cache layers between disk and Designer — both need refreshing
Disk edits do not reach Designer for free. There are two caches:

1. **Gateway side** — filesystem → gateway's in-memory project model. Refreshes
   only on a project scan (or gateway restart).
2. **Designer side** — gateway's model → Designer's local cache. Refreshes only
   on project open or "File → Update Project" (Cmd+Shift+U on Mac).

Either step alone is insufficient. Scan without Update Project: Designer keeps
showing the old version when you reopen the file. Update Project without scan:
the gateway still has the old version, so Designer pulls the old version.

**The propagation sequence** (for any disk edit to a Perspective view, project
script, or named query):

```bash
# 1. Make the disk edit.
# 2. Trigger the gateway scan.
TOKEN=$(cat <wherever-you-store-the-local-API-token>)  # gitignored
curl -s -X POST -H "X-Ignition-API-Token: $TOKEN" \
  http://<gateway-host>:<port>/data/api/v1/scan/projects
# Local default: http://localhost:9088
```

Then in Designer:

3. Cmd+Shift+U (File → Update Project).
4. If the file is currently open in Designer, see the "opening a view marks it
   dirty" gotcha below — close + reopen, or use the conflict-resolution dialog.

This applies equally to brand-new resource directories and to edits of existing
files. Without a scan, neither case shows up. _Discovered: 2026-05-21_

### Opening a view in Designer marks it locally dirty even without edits
Just opening a view (without typing or clicking anything inside it) puts it in
Designer's "modified" state — the resource name turns italic and an asterisk
appears. The next "Update Project" sees that as a local edit and pops the
**Resolve Conflicts** dialog ("Resources that you have changed have also been
changed remotely").

The dialog will show **many more changes than you actually made** — typically
30+ for a single one-line edit. That's because Designer's in-memory JSON is
normalized differently from on-disk: key order, whitespace, `=` vs `=`
escape style, etc. Almost all of those entries are formatting noise, not real
differences. There's usually also a `thumbnail.png` entry showing
"Resource Deleted" on the gateway side — Designer regenerates thumbnails on
save, so this is safe to discard.

Two clean resolutions:

- **One-click in the dialog:** the "Use all from: **Gateway**" button at the
  bottom-left applies the gateway version to every entry at once. Don't try
  to inspect each change — they're mostly normalization noise.
- **Revert Changes first:** right-click the resource in the project tree →
  *Revert Changes* before Cmd+Shift+U. That clears the asterisk without
  triggering the dialog at all.

For the typical "I edited a view on disk while it was open in Designer"
workflow, *Revert Changes* is the smoothest — single right-click, then
Cmd+Shift+U, no dialog. Use the dialog only if Designer has REAL unsaved
edits you don't want to throw away. _Discovered: 2026-05-21_

### Hard-refresh the Perspective session after any Designer change
Browser-side Perspective sessions cache the view bundle. After any view edit
(even after Designer is saved), tell the user to hard-refresh the session
tab (Cmd+Shift+R) or they'll keep seeing the old behavior. _Discovered: 2026-05-21_

### Asterisk = unsaved local change
A `*` after a resource name in Designer's project browser (e.g. `onEditCellCommit*`)
means Designer has unsaved local edits to that resource. While the `*` is
there, edits you make to the file on disk are ignored. To discard Designer's
local copy and force-reload from disk: close the resource without saving (or
close the whole project / Designer without saving). _Discovered: 2026-05-21_

---

## Designer JSON file format

### View.json files use `=` and `'` Unicode escapes
Designer serializes embedded Python script strings with `=` as `=` and
`'` as `'`. Standard `grep`, `sed`, and Claude's `Edit` tool treat the
escape sequence as literal text in their pattern. Don't try to match `=` or
`'` — match the escape sequence, or use Python `json.load` + `json.dump` to
read-modify-write the file programmatically. _Discovered: 2026-05-21_

### Hand-written resource.json signatures are tolerated
You can write `resource.json` files with `"lastModificationSignature":
"0000...0000"` and Designer will re-sign on first save. It may show a "modified
outside Designer" notice but won't reject the resource. Useful when scaffolding
named queries / views from disk. _Discovered: 2026-05-21_

---

## Perspective views, components, and bindings

### `event.row` on table events is a row INDEX, not a row dict
For the Perspective Table's `onEditCellCommit` (and likely other cell events),
`event.row` is the row index (a `long`), not the row data. Calling `dict(event.row)`
raises `'long' object is not iterable`.

**Fix:** look up the row from the table's data:
```python
def rowAt(table_data, row_index):
    if hasattr(table_data, 'getColumnCount') and hasattr(table_data, 'getValueAt'):
        out = {}
        for i in range(table_data.getColumnCount()):
            col = table_data.getColumnName(i)
            out[col] = table_data.getValueAt(row_index, i)
        return out
    return dict(table_data[row_index])
```

Then in the event handler: `rowDict = partsAdmin.rowAt(self.props.data, event.row)`.
_Discovered: 2026-05-21_

### `onCellClick` does NOT exist on the Perspective Table
The Table exposes `onRowClick`, `onRowDoubleClick`, plus the cell-edit
events (`onEditCellStart`, `onEditCellCancel`, `onEditCellCommit`). There is
no `onCellClick`. For column-specific click handling (e.g. open a different
popup when clicking the Image column vs the Molds column), use `render: "view"`
on the column and put an embedded sub-view in each cell that fires its own
`onClick` or `onActionPerformed`. _Discovered: 2026-05-21_

### Default to NO `position.basis` / `position.grow` / `position.shrink`
Don't reflexively add explicit sizing to every new flex child. Perspective
elements have sensible natural sizes (labels = text width, inputs = default
width, buttons = content + padding); cluttering each child with `basis`,
`grow`, `shrink` produces brittle layouts and noisy diffs.

Add explicit sizing ONLY when the layout literally requires it — i.e. when
something must fill remaining space inside a flex parent. Examples that DO
need it in this codebase:
- A scrolling `ia.display.table` inside a column-flex parent → `grow: 1`
  (otherwise it collapses to header-only height).
- The main content pane of a popup (image preview, textarea) when it should
  span between the title and the action-button row → `grow: 1`.

For spacing between siblings, use per-child `style.marginX` (see the `gap`
gotcha above), not `basis`/`grow`. _Discovered: 2026-05-27_

### `style.fontWeight` must be a STRING, not a number, even for numeric weights
Writing `"fontWeight": 600` (a JSON number) trips Designer's schema
validator — even though `"600"` is one of the values offered by the
dropdown in the PROPS panel. Selecting `"600"` from the dropdown rewrites
it as a string and clears the warning.

Quote ALL numeric font weights:
```json
"style": { "fontWeight": "600" }   // ✓
"style": { "fontWeight": "bold" }  // ✓
"style": { "fontWeight": 600 }     // ✗ schema warning
```
Same logic likely applies to other typographic numerics; default to strings
in `style.*` unless you know a key takes a number.
_Discovered: 2026-05-27_

### `gap` on `ia.container.flex` is NOT in the schema — it's a silent no-op
Setting `props.gap` on a flex container looks reasonable (it's a real CSS
property) but Designer's schema validator rejects it and the runtime never
emits `style.gap` to the DOM. `getComputedStyle(container).gap` returns
`normal`. The warning appears in Designer's PROPS panel header as
`"gap: is not defined in the schema and additional properties are not
allowed"`, but if you're editing JSON on disk you'll miss it entirely.

For real spacing between children of a flex container, put `margin` (or
`marginTop`/`marginLeft`/etc.) inside each child's `style`, e.g.:
```json
"props": { "style": { "marginTop": "10px" } }
```
Per-child margins compose naturally with the container's `direction` and
`alignItems` props. _Discovered: 2026-05-27_

### `ia.input.radio-group`: array prop is `radios`, label is `text`, initial selection is per-item `selected: True`, runtime selection is `props.value`
The 8.3.4 schema looks like:
```json
{
  "radios": [
    {"text": "Option A", "value": "a", "selected": true},
    {"text": "Option B", "value": "b"}
  ],
  "direction": "row" | "column"
}
```
The schema's prop names are non-obvious — multiple foot-guns on one component:

- **Array prop**: `radios` (NOT `options`). Using `options` is silently ignored and you get a single "Radio button" placeholder.
- **Per-item label**: `text` (NOT `label`). Using `label` gives you the right number of radios but every label reads "Radio button".
- **Initial selection**: per-item `selected: True`. Top-level `selectedValue` / `value` props passed in JSON do NOT control initial selection — they're rendered as the first radio regardless. To drive initial selection off a binding (e.g. an input param), put a SCRIPT TRANSFORM on `props.radios` that emits the array with `selected` flipped:
  ```python
  cur = value or ''
  return [
      {'text': 'A', 'value': 'a', 'selected': cur == 'a'},
      {'text': 'B', 'value': 'b', 'selected': cur == 'b'},
  ]
  ```
- **Reading the user's pick** from a Save/Apply script: `radio.props.value` (NOT `selectedValue` — that attribute doesn't exist and raises `AttributeError`). `radio.props.index` is the 0-based index. Both update on click. Wrong prop names fail silently from the user's POV — the script raises and `system.perspective.closePopup` never runs, so the popup just "doesn't close." Always wrap Save/Apply scripts in `try/except` that `logger.error(traceback.format_exc())` so the error appears in the gateway log.
- **Playwright drives this fine**: a DOM click on the radio wrapper's label DOES propagate to the gateway-side `props.value`. (Earlier I thought it didn't — that was actually the `selectedValue` AttributeError above failing silently.) Both popup structure AND the end-to-end apply path are auto-testable.
_Discovered: 2026-05-27_

### `ia.display.table` pager: `activePage` is writable from scripts, `pageSize` is not
Per-component prop access in gateway scripts is asymmetric on the table's pager object. `self.view.getChild('root').getChild('partsTable').props.pager.activePage = N` works fine — useful for "jump to last page after inserting a row" workflows. But reading `props.pager.pageSize` raises `AttributeError: 'com.inductiveautomation.perspective.gateway.script' object has no attribute 'pageSize'`. If you need page-size-dependent math in your script, hard-code the value (Perspective default is 25) and leave a comment to keep them in sync if you ever override the table's page size. _Discovered: 2026-05-28_

### Selected-row data goes stale across refreshes — re-pull from DB for popup params
A view-scope custom prop like `view.custom.selectedRow` (set from `onRowClick`) holds a SNAPSHOT of the row at click time. After a popup writes to the DB and bumps `session.custom.refreshNonce`, the TABLE's `props.data` refreshes — but `selectedRow` does NOT auto-refresh. If the user re-opens the same popup without clicking the row again, your popup-launching script will hand it stale field values from `selectedRow`. Two options that work:
- For small/cheap reads, fetch the fresh field from the DB at popup-open time with a scalar named query (e.g. `parts/getStatus` taking `:id`, returning the single field).
- For multi-field popups, look up the row in the table's CURRENT `props.data` by id. Watch out: the data may be a cell-wrapped list (`{'value': x, 'style': ...}`) if you have a styling transform — unwrap before passing.

Reading `props.data` immediately after bumping `refreshNonce` races the refresh; the DB-query path avoids the timing concern entirely. _Discovered: 2026-05-28_

### `self` in a component event handler is the COMPONENT
Not the view. Use `self.view` to reach view-scope state (`self.view.custom.search`,
`self.view.params.foo`), `self.props.x` for the component's own props,
`self.session` for session-scope. _Discovered: 2026-05-21_

### `messageHandlers` may silently fail to fire — use a `session.custom` counter + property-change script for cross-view refresh
On at least Ignition 8.3.4, `system.perspective.sendMessage()` can broadcast
to a `messageType` that has no actual consumer. Placing `messageHandlers`
arrays at any of: the view top level, the root container, intermediate
containers, the target component, or even the sender component itself can
all yield zero handler invocations — confirmed empirically across six
simultaneous placements with identical messageType and full
{page,session,view}Scope=true.

**Working alternative for cross-view refresh signals:**

1. Declare a `session.custom.<name>` integer prop (e.g. `refreshNonce`),
   `persistent: true`.
2. On the target view, declare `view.custom.<name>` (same type), bound to
   the session prop via a property binding:
   ```json
   "propConfig": {
       "custom.refreshNonce": {
           "persistent": true,
           "binding": {
               "type": "property",
               "config": {"path": "session.custom.refreshNonce"}
           },
           "onChange": {
               "script": "\tself.getChild('root').getChild('partsTable').refreshBinding('props.data')"
           }
       }
   }
   ```
3. The "trigger" side (popup save, action button on another view) writes:
   `self.session.custom.refreshNonce = (self.session.custom.refreshNonce or 0) + 1`
4. Property-change scripts on view.custom DO fire reliably (unlike
   messageHandlers in this scenario), so the onChange invokes
   `refreshBinding` on the bound component.

This pattern survives Designer's strip-on-save behavior because the
machinery lives in `custom` props and `propConfig.onChange` — both of which
Designer treats as first-class. _Discovered: 2026-05-22_
`self.view.refreshBinding('custom.search')` is a no-op if `custom.search` is a
plain value with no binding attached. To refresh a query-bound property (like a
table's data binding), call `refreshBinding` on the **component holding the
binding**, with the path to the bound property: `self.refreshBinding('props.data')`
from an event handler on that component. _Discovered: 2026-05-21_

### Custom props with `persistent: false` lose their default value on save
If you declare `custom.search` and set `propConfig.custom.search.persistent =
false`, Designer strips the value from `custom` on the next save. At runtime
the prop is `null`/`undefined`, which surfaces as the string `"null"` in
bound text fields and breaks query parameter substitution. Fix: either
(a) set `persistent: true` (defaults survive), or (b) initialize the prop in
a view-level / root-container `onStartup` event handler. _Discovered: 2026-05-21_

---

## Named queries

### Ignition `sqlType` is NOT `java.sql.Types`
Named query parameters declare a `sqlType` that uses Ignition's internal enum,
not the standard JDBC `java.sql.Types`. Observed values:

| Ignition `sqlType` | Meaning           |
|--------------------|-------------------|
| `2`                | Integer (IDs)     |
| `7`                | String / TEXT     |
| `20`               | BLOB / binary     |

Don't blindly map `12` (JDBC VARCHAR) or `4` (JDBC INTEGER) — they won't
behave the same. Look at an existing named query in the same project for the
correct value. _Discovered: 2026-05-21_

### Named query reload after disk edit
After editing a named query's `query.sql` or `resource.json` on disk, the
gateway may continue serving the cached version. Designer needs to either
re-read (close + reopen the named query, or close + reopen the project) or
get a project save. If a query suddenly behaves like its old version, suspect
caching before suspecting your SQL. _Discovered: 2026-05-21_

---

### Ignition's `ScalarQuery` injects `LIMIT 1` and breaks `INSERT … RETURNING`
**Symptom:** `org.postgresql.util.PSQLException: ERROR: syntax error at or
near "LIMIT"` from a perfectly valid `INSERT … RETURNING id` named query
of type `ScalarQuery`. The query runs cleanly via `psql`.

**Cause:** the `ScalarQuery` type appends `LIMIT 1` to the SQL to enforce
scalar return, but the LIMIT-injector misplaces it on certain statement
shapes — confirmed for `INSERT … ON CONFLICT … RETURNING` and even some
plain `INSERT … RETURNING` forms — landing the keyword between the row
body and `RETURNING`. Postgres rejects.

**Fix:** wrap the INSERT in a CTE so the outer statement is a plain SELECT.
LIMIT 1 then appends cleanly to the SELECT and Postgres is happy.

```sql
WITH ins AS (
    INSERT INTO schema.table (col1, col2)
    VALUES (:p1, :p2)
    -- ON CONFLICT/UPDATE optional
    RETURNING id
)
SELECT id FROM ins
```

The named query remains type `ScalarQuery`; only the SQL changes.
_Discovered: 2026-05-22_

### Ignition named-query parser treats `:name` in SQL comments as bind sites
The parser that finds named-query parameters scans for every `:name` token in
the SQL **regardless of context** — comments and string literals included.
Each match counts as a bind site, so Ignition tells the JDBC driver "this
prepared statement has N parameters" when Postgres (after stripping comments)
only sees one `?`.

**Symptom:** at runtime, `PSQLException: The column index is out of range:
2, number of columns: 1.` (or higher numbers if you have more `:name`
references in comments). The binding's data-quality error in the Designer
PROPS panel shows the same wording. The query works fine when run directly
via `psql`.

**Fix:** never write `:paramname` in a SQL comment. Refer to params by
bare name in commentary, e.g. write `-- the search parameter` instead of
`-- :search`. Same applies to string literals — if you ever need a literal
`:foo` in a string, escape it with `\:foo` or use `||`-concatenation to avoid
the parser. _Discovered: 2026-05-21_

---

## SQL gotchas (Postgres)

### `:param IS NULL` on a typed-string param raises "could not determine data type"
Postgres can't infer a parameter's type when it appears bare in `IS NULL` or
similar untyped contexts. Symptom:
```
org.postgresql.util.PSQLException: ERROR: could not determine data type of parameter $1
```
**Fix:** cast once via a CTE so all references inherit the type. Bonus:
`NULLIF(..., '')` folds empty strings to NULL so the WHERE clause only needs
one null branch:

```sql
WITH params AS (
    SELECT NULLIF(CAST(:search AS TEXT), '') AS search
)
SELECT ...
FROM table t
CROSS JOIN params
WHERE params.search IS NULL OR t.col ILIKE '%' || params.search || '%'
```
_Discovered: 2026-05-21_

---

## Project scripts (Jython)

### Jython 2.x, not Python 3
Ignition project scripts run on Jython 2.x. **No** f-strings, **no** PEP 604
union types (`int | None`), **no** walrus operator, **no** `dataclasses`,
**no** `typing.Self`. Use `.format()` or `%`-formatting, traditional
`Optional[int]` if you want type hints, etc. _Discovered: 2026-05-21_

### Project script changes need a Designer save (sometimes more) to load
Editing `code.py` on disk does not make the new function available to running
event handlers until either (a) Designer saves the project, or (b) the gateway
reloads the project. Until then, scripts calling the new function fail with
`'com.inductiveautomation.ignition.common.script.Pro' object has no attribute 'xxx'`.
_Discovered: 2026-05-21_

### Log to a gateway logger, not `system.perspective.print`, when debugging script failures
`system.perspective.print('...')` sends to the browser console / Designer
Output Console — invisible from the host. To debug from the gateway side
(reading `system_logs.idb`), use a named logger:
```python
logger = system.util.getLogger('partsAdmin')
logger.info('saveCellEdit ENTRY ...')
logger.error('saveCellEdit failed:\n' + traceback.format_exc())
```
Then read events with:
```
sqlite3 /usr/local/bin/ignition/logs/system_logs.idb \
  "SELECT formatted_message FROM logging_event WHERE logger_name='partsAdmin' ORDER BY timestmp DESC LIMIT 20"
```
(Copy the `.idb` out of the container first if running in Docker.) _Discovered: 2026-05-21_

---

## Gateway & connections

### JDBC encrypted passwords are per-gateway-key
Database-connection `password.data` blocks under
`config/resources/<mode>/ignition/database-connection/<name>/config.json` are
encrypted with the gateway instance's local key, not committed to git or
shareable. A fresh clone (or any gateway that didn't encrypt the password
itself) cannot decrypt it. Symptom: `FaultedDatabaseConnectionException:
password authentication failed for user "X"`.

**Fix:** re-enter the password in the Gateway UI → Config → Databases →
Connections → edit the connection → paste the password → Save. The gateway
re-encrypts with its own key and writes a new ciphertext to `config.json`.
Other devs cloning the repo will hit the same problem and have to repeat the
process. _Discovered: 2026-05-21_

### Gateway scan endpoint
For the propagation workflow (see Workflow rules → "Two cache layers"), the
scan endpoint is:

```
POST http://localhost:9088/data/api/v1/scan/projects
Header: X-Ignition-API-Token: <token>
Returns: {"scanActive": true, "lastScanTimestamp": <epoch_ms>, "lastScanDuration": <ms>}
```

Token requires a custom security level — see the next entry. If you don't
have a working token yet, `docker compose restart ignition` is the fallback
(~30 seconds of gateway downtime). _Discovered: 2026-05-21_

### Ignition 8.3 API keys need a custom security level — "Authenticated" alone gives 401/403
A fresh API key in 8.3 only has the `Authenticated` marker, which is just
"this token is valid" and does NOT grant access to any Data Model API
endpoint. Every `/data/api/v1/*` call returns 401 Unauthorized.

**Fix (Gateway UI):**
1. **Config → Security → Levels** — create a custom level, e.g.
   `API-ReadWrite`. **Parent: `Authenticated`** (not `Public`).
2. **Config → Security → General (Gateway Permissions)** — for both
   *Gateway Read Permissions* and *Gateway Write Permissions*, set
   **Match: Any Of** and add `API-ReadWrite`.
3. **Config → Security → API Keys** — edit your key, check the new level
   in the Security Level tree (you'll only see custom levels and SecurityZones
   under Authenticated; the Roles subtree is correctly disabled for API keys
   because keys are machine identities, not IdP-mapped users).
4. Same screen: **uncheck "Require secure connections for API Keys"** if you're
   on HTTP (port 9088). Otherwise the gateway silently rejects HTTP requests.

API keys cannot open Designer — Designer auth goes through the IdP. The token
is for REST endpoints only.

The "Required Designer Roles" panel inside *Project Properties → Permissions*
in Designer is a separate, role-based gate for Designer login — leave it blank
(or put `Administrator`). The API path doesn't go through that panel.

_Discovered: 2026-05-21_

### The Ignition 8.3.4 REST API does NOT expose Perspective view / script / named-query CRUD
The `/data/api/v1/resources/com.inductiveautomation.perspective/*` namespace
only exposes `fonts`, `icons`, and `themes` — there is no `views` endpoint.
Same for `script-python` and `named-query`: no per-resource REST endpoints in
the OpenAPI spec on 8.3.4. This is why the third-party `ignition-mcp` server's
`list_project_resources` / `set_project_resource` tools return 404 (see
`whiskeyhouse/ignition-mcp#6`).

**Practical implication:** the working workflow is file-system writes plus
`POST /data/api/v1/scan/projects` to make the gateway pick them up. Don't
spend time looking for a "write view via REST" endpoint — it doesn't exist on
this version.

What DOES work via REST:
- `POST /data/api/v1/scan/projects` — trigger gateway project rescan
- `GET /openapi.json` — enumerate the rest of the (large, mostly admin) API
- `GET /data/api/v1/projects/list`, `/data/api/v1/projects/export/{name}`,
  `/data/api/v1/projects/import/{name}` — whole-project ops if you need them.

_Discovered: 2026-05-21_

### Read `system_logs.idb` for the real error
Gateway stdout (docker logs or wrapper.log) typically shows truncated
exception messages. The full event log with stack traces lives in
`<Ignition install>/logs/system_logs.idb` — a SQLite database. Locations:

- **Docker**: `/usr/local/bin/ignition/logs/system_logs.idb` inside the
  container (copy out with
  `docker compose cp <service>:/usr/local/bin/ignition/logs/system_logs.idb /tmp/`).
- **Linux native install**: `/usr/local/ignition/logs/system_logs.idb`.
- **Windows native install**:
  `C:\Program Files\Inductive Automation\Ignition\logs\system_logs.idb`.

Query it directly with `sqlite3`:
```bash
sqlite3 /path/to/system_logs.idb \
  "SELECT datetime(timestmp/1000,'unixepoch'), level_string, logger_name, formatted_message
   FROM logging_event
   WHERE level_string IN ('ERROR','WARN')
   ORDER BY timestmp DESC LIMIT 30"
```
_Discovered: 2026-05-21_

---

## Playwright e2e testing (debug-tools)

### Cell-text selectors: substring is the default — use `>> text='X'` for exact match
`:has-text('1')` (Playwright's default) is a SUBSTRING match — selecting a row whose `part_number` cell reads exactly `1` will also match `10`, `100`, `11`, etc. Two alternatives that look like they should give exact match but DON'T work in our Playwright version:

- `:text-is('1')` — returns 0 matches (count silently zero, then `click()` times out).
- `:has-text(/^1$/)` — Playwright rejects the regex inside `:has-text` with `Unexpected token "/" while parsing css selector`.

What DOES work reliably for exact text inside a cell:
```python
# Click the row whose part_number cell is exactly "1":
browser.click("div.tr div.tc[data-column-id='part_number'] >> text='1'", wait=0.4)
```
The `>>` is Playwright's locator-chain operator; `text='X'` (single-quoted) is the strict-equal text engine. The downside is `>>` does NOT nest inside `:has(...)`. If you need "find the row containing exactly N, then click a different cell in that row," use `locator.filter()` with a regex:
```python
import re
row = browser._page.locator("div.tr:not(.header)").filter(
    has=browser._page.locator(
        "div.tc[data-column-id='part_number']"
    ).filter(has_text=re.compile(rf"^{re.escape(part_number)}$"))
).first
cell = row.locator(f"div.tc[data-column-id='{column}']")
```
_Discovered: 2026-05-28_

## Docs

### Ignition docs URL is version-specific
The official docs live under:
```
https://www.docs.inductiveautomation.com/docs/<version>/<topic>
```
Always use the version matching the project's gateway (read from
`docker-compose.yml` — look for `inductiveautomation/ignition:X.Y.Z` and use
`X.Y`). If you can't determine the version, use WebSearch for the topic; the
site search ranks well. _Discovered: 2026-05-21_

### The forum is high-signal for niche behavior
`forum.inductiveautomation.com` is searchable and indexed; for any behavior
that's "weird, undocumented, version-dependent," the forum usually has a
thread. Read it before guessing. _Discovered: 2026-05-21_
