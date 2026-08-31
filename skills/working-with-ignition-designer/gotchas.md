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

### Debug by binary search: isolate the failing step, don't rewrite-and-guess
When something doesn't work, STOP. Do not rewrite large chunks or stack new
guesses on top of the broken state. Localize the failure by halving the path:

1. Pick the midpoint of the failing flow (e.g. between "scan captured in the
   browser" and "row written to the DB") and check the ACTUAL value there,
   using whatever observes that point: headless-browser DOM, the gateway log
   (`system_logs.idb`), and direct `psql` inspection.
2. If the problem is already present at the midpoint, the fault is upstream, so
   halve the upstream half and check again. If the midpoint is healthy, the
   fault is downstream, so halve that.
3. Recurse until you are down to a single script line, one named-query run, or
   one prop. That pinpoints the exact break, instead of guess-and-retry.

This is the debugging counterpart to rule 2b's incremental building: build one
verified piece at a time, and when a piece breaks, bisect to find where. A
failure with no browser console error almost always means the error is
gateway-side, so read `system_logs.idb` before theorizing. _Discovered: 2026-06-02_

### Disk shows SAVED state — an unsaved Designer edit is invisible to you
When the user reports "X doesn't work" and you inspect `view.json`, `code.py`,
or `query.sql` on disk, you are reading what was last **saved**, not what is
on their screen. Designer holds unsaved edits in memory, and its Script
Console even executes against that in-memory copy — so a function can pass a
console test while the file on disk has never heard of it.

Two symptoms that look like different bugs but are the same thing:

- Disk lacks a method/edit the user is certain they made → not saved yet.
- A console test passes but the same call fails from a running session → the
  console used Designer's memory; the gateway serves the saved version.

So when disk contradicts the user, say so plainly and name both possibilities
("this isn't on disk — either it wasn't applied or the project isn't saved")
rather than assuming they skipped a step. Confirming with a one-line grep is
faster than debugging the wrong layer.
_Discovered: 2026-08-21_

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

### Never run `git checkout` / `git stash` / branch switches under the project dir with Designer open
**Symptom:** Designer refuses to save with `Failed to commit changes to view
'<path>'`. The named view is often one you are not even editing, is clean on
disk, and matches HEAD. Nothing appears in the gateway log — the failure is
entirely Designer-side, so `system_logs.idb` is a dead end here.

**Root cause:** the gateway treats the project directory as live state and
watches it. A bulk git operation rewrites many resource files at once beneath
it; the gateway re-scans and bumps resource signatures, and the open Designer
session is left holding stale baselines. Its next commit is validated against a
baseline that no longer exists and is rejected.

This is distinct from the single-file disk-edit flow above, which is safe
*because* it is followed by an explicit scan + Update Project. The problem is
the uncoordinated bulk rewrite, not disk edits as such.

**Fix:** close Designer → run the git command → reopen Designer. Reopening
pulls fresh signatures from the gateway. If you must recover without closing,
File → Update Project may resync, but a restart is the reliable move.

Ordering matters when reverting a mistaken Designer edit: revert *in Designer*
first, then close it, then clean up leftovers with git. Doing git first while
Designer still holds the resource just recreates the desync.
_Discovered: 2026-08-27_

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

### Designer Preview does NOT render popups — test popup flows in a real session
`system.perspective.openPopup` (and anything built on it, including alert /
confirmation helpers) silently does nothing in Designer's Preview mode: the
Designer's browser emulation does not support popup windows. The script runs,
the gateway accepts the call, and **no error is logged anywhere** — the popup
just never appears, which reads exactly like "my button does nothing."

Symptom triage: if a button's handler looks correct, the gateway log shows no
WARN from `perspective.actions.script`, and the screen does not even dim for a
`modal=True` popup, suspect Preview before suspecting the script. Confirm by
adding one `system.util.getLogger(...).info(...)` line at the top of the
handler — if it logs, the handler ran and Preview is eating the popup.

Corollary: error-feedback paths built on popups (a `failAlert`-style helper)
are invisible during Preview testing, so a failure that *should* alert the
user looks like a silent success. Exercise those paths in a real browser
session before believing them. _Discovered: 2026-08-14_

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

### Flex Repeater instances stretch to fill — set `useDefaultViewHeight` + the child view's defaultSize
By default a Flex Repeater stretches each repeated instance to fill the
container, so a 3-item list gives you three giant rows and a scrollbar
instead of three compact ones. The fix is a pair, and both halves are
required:

1. On the **child view**, set its **defaultSize** height to the row height.
2. On the **repeater**, set **`useDefaultViewHeight = true`** so it honors
   that instead of stretching.

**The width half is the nastier one.** `useDefaultViewWidth` also defaults to
true, so every instance renders at the child view's `defaultSize.width` no
matter how wide the repeater is. Symptom: the first child of the row shows and
everything after it is invisible — trailing labels/buttons get squeezed into
whatever the leftover pixels allow. It reads like "my button didn't get added"
rather than a layout problem. Set `useDefaultViewWidth = false` so instances
stretch, and strip the `basis` values Designer auto-adds to each child (they
compound the squeeze — see the "Default to NO basis/grow" entry below).

Alternative (and the only per-instance option): each entry in `props.instances`
may carry the reserved keys **`instancePosition`** and **`instanceStyle`**,
which the repeater applies to that instance's flex position/style rather than
passing to the view as params — e.g.
`{'instancePosition': {'basis': '44px', 'shrink': 0}, ...}`. Useful for
variable row heights, but it pushes layout into whatever builds the instances
array (often a binding transform), so prefer the defaultSize route.
_Discovered: 2026-08-13_

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

### `ia.container.tab`: `tabs[].viewPath` renders a view as the HEADER, not the pane; hand-authored child panes only render the first tab
The Tab Container's `props.tabs[]` entries configure the tab HEADERS, not the
content panes. Each entry may carry `text` (header label), `viewPath`,
`viewParams`, `runWhileHidden`, `disabled`. Verified on 8.3.4 by headless test:

- `text` sets the header label (plain text button).
- `viewPath` (with no `text`) renders that whole VIEW *as the tab header*, i.e.
  the view's content ends up crammed into the clickable tab button, not the
  body. If both `text` and `viewPath` are set, `viewPath` is ignored. So
  `viewPath` is for fancy custom tab buttons, NOT for putting a view in the tab.

The tab BODY/pane is supposed to come from the container's `children` (one per
tab, by index), but **hand-authoring those children in `view.json` only
rendered the FIRST tab's child**: the single `.content-frame` showed child[0]
for tab 0 and stayed empty for every other tab, even with a bare label as the
child (so it is not a per-embedded-view problem). Net: a hand-authored tab
container with `tabs[].text` + a child per tab reliably renders only the first
tab; the rest are blank.

To get real content in every tab, build the tabs in DESIGNER (deep-select the
container and drop an embedded view onto each tab) so the panes associate
correctly, rather than hand-authoring the `children` array. The root of a view
can itself be the tab container. _Discovered: 2026-06-02 (corrected same day after headless verification)_

### A focused button + a barcode scanner = the scan's Enter re-fires the button
A Perspective form that mixes `ia.input.barcodescannerinput` with action buttons
(Submit, Clear) has a focus trap: after the user clicks a button, that button
keeps DOM focus, and the scanner's terminating **Enter keystroke also activates
the focused button**. Symptoms: after clicking Clear or Submit, the next scan
re-runs that button's `onActionPerformed`. For example you can never advance
from the part field to the location field (every scan re-clears first), or a
second submit fires on the next scan. The scanner captures keystrokes globally,
so this happens regardless of where the scan value is routed.

**Fix:** at the end of each button's `onActionPerformed`, move focus off the
button. Focusing the root container is the documented blur workaround:
`self.parent.parent.focus()` (walk up to the view root) or
`self.view.rootContainer.focus()`. `.focus()` works on focusable components and
on the root container; `self.blur()` on the button is unreliable. _Discovered: 2026-06-02_

### Multiple `ia.input.barcodescannerinput` coexist on one screen via PREFIX/SUFFIX, not regex
Two (or more) barcode scanner inputs CAN live on the same view, each capturing
only its own barcode type, IF the types are distinguishable and you pick the
right mode. Each scanner independently watches the global keystroke stream; a
scan it does not recognize is ignored by that scanner.

- **regex mode is fragile for this.** The component accumulates keystrokes in a
  rolling buffer and does NOT flush it after a non-matching scan, so scans meant
  for the OTHER scanner pile up and corrupt the next real match (an anchored
  `^...$` regex makes the corruption sticky). Verified empirically: two scanners
  with `(\d+)Enter` and `([A-Za-z]+-\d+-\d+)Enter` cross-contaminated on
  rapid/interleaved scans. A purely numeric code is the worst case (an unanchored
  `(\d+)` grabs the trailing digits of a dashed location like `SB-2-4`).
- **prefix/suffix mode is the robust discriminator.** Encode a distinct prefix
  per type in the labels and set `props.prefix`/`props.suffix` per scanner (e.g.
  part = prefix `$` suffix `!`; location = prefix `@` suffix `!`). The component
  keys on the delimiters (no regex buffer), so there is no cross-contamination.
  When `prefix` or `suffix` is set, `regex` is ignored, and no Enter terminator
  is needed (the suffix ends the scan). Verified clean discrimination with rapid
  + interleaved scans.

The encoding (what prefix/suffix the labels carry) is a labeling decision the
customer owns, so confirm it before wiring the scanners. Driving prefix/suffix
scanners headless: type the whole encoded string (`$18!`, `@SB-2-4!`) globally,
no click and no Enter. _Discovered: 2026-06-03_

### Mobile camera barcode scanning is a separate path: Scan Barcode action + Barcode Scanned session event (Perspective App only)
The `ia.input.barcodescannerinput` component is for keyboard-wedge scanners. To
scan with a phone camera you use a different mechanism: a **Scan Barcode**
Perspective App action (on a button's onClick; renders on disk as a
`native/barcode` DOM event action) opens the device camera, and the result fires
the project's **Barcode Scanned** session event. The handler signature is
`onBarcodeDataReceived(session, data, context)`; the scanned payload is the
**`data`** param (a dict-like object: `data.text`, `data.timestamp`,
`data.barcodeType`), NOT a name called `event`. Referencing `event.text` raises a
silent `NameError` per scan (visible only in the gateway log) so the camera opens,
reads, and closes but nothing reaches the client. This works ONLY in the native Ignition
Perspective App, NOT a mobile web browser, so it cannot be exercised by the
headless Playwright driver, it needs on-device testing.

To feed the same fields as the wedge scanners, relay it: the session event
writes `session.custom.<x> = data.text`; the view binds a `view.custom` prop to
that session prop with an onChange that parses + routes the value into the form's
fields. If the barcodes carry a type prefix, route by prefix so one camera
button handles every field. Caveat: the relay's onChange only fires when the
bound value CHANGES, so scanning the identical barcode twice in a row would be a
no-op. To make repeated identical scans re-fire, keep `lastScan` a **string** and
have the view's onChange reset it (`self.session.custom.lastScan = ''`) after
routing, so the next identical scan is again a change. Do NOT switch the prop to a
dict to force the change: an object-typed session prop comes back to gateway
scripts as a `java.util.HashMap` whose values are wrapped `QualifiedValue`s (e.g.
`v['text']` reprs as `[$1!, Good, <ts>]`, not `'$1!'`), so `isinstance(v, dict)`
is False and `routeScan` gets a non-string and throws `'...HashMap' object has no
attribute 'strip'`. A scalar string prop comes back as clean unicode.
_Discovered: 2026-06-03_

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

### Persisted design-time defaults can hold REAL records — treat them as a live hazard, not diff noise
**Symptom:** a view opened without one of its params behaves as though it was
handed real data. In the case that surfaced this, two buttons opened a WO form
passing an *undeclared* param name and no `dataset`; the form silently fell
back to `params.dataset`'s persisted default, which was a complete real work
order. Every user saw the same foreign record, and saving would have written
to it.

**Root cause:** Perspective persists the design-time value of params and props
into `view.json`. Whatever was last loaded while the view sat open in Designer
becomes the default. For a `dataset` param that means a full row of production
data, committed to git and shipped.

It compounds with transform code that guards the *empty* case but not the
*stale* case. A common shape:

```python
data = value['dataset']
dictData = transform.datasetToDict(data)   # returns {} when rowCount != 1
```

`datasetToDict` throws on `None` (so an `except → sensible defaults` fallback
fires), but a 1-row stale default succeeds outright and a 0-row dataset returns
`{}` without throwing — so the fallback never runs in either direction. Guard
explicitly with `if not dictData:` rather than relying on the exception.

**Also note:** an empty `{}` breaks **property** bindings into its sub-keys
(the path does not resolve, and the component renders an ERROR band), while
**expression** bindings wrapped in `isNull(...)` degrade to null quietly. A form
whose labels all use `if(isNull({...}), '', {...})` is usually telling you its
author already hit this.

**Check for it** across a project before shipping:

```bash
python3 - <<'PY'
import json,glob
for f in glob.glob('**/view.json', recursive=True):
    try: d=json.load(open(f))
    except: continue
    for p,v in (d.get('params') or {}).items():
        if isinstance(v,dict) and '$columns' in v:
            nn=sum(1 for c in v['$columns'] if any(x is not None for x in c.get('data',[])))
            if nn: print('%s param=%s non-null cols=%d' % (f,p,nn))
PY
```

Merely opening such a view in Designer re-persists it, which is why these show
up as enormous unexplained diffs (19,555 lines in one case) with plant codes
flipping to match whatever building the session was on. Clear the default (to
null where possible, so the fallback path fires) rather than leaving live data
in it. _Discovered: 2026-08-27_

---

## Named queries

### `system.db.runNamedQuery` signature differs by scope — Script Console omits the project arg
Gateway/Perspective scope: `runNamedQuery(project, path, params)`. Designer
Script Console (and Vision client) scope: `runNamedQuery(path, params)` — the
project is implicit from the open project. Passing the 3-arg form in the
console fails with the cryptic `TypeError: runNamedQuery(): argument tx:
expected String instance, got PyDictionary` (the path string slides into the
`tx` slot). When handing test snippets to a user, match the scope they'll run
in. _Discovered: 2026-08-05_

### A new named query defaults to NO database connection
The Database Connection dropdown on a freshly created named query starts
blank, and nothing in the Designer flags it. The failure surfaces only at
runtime, wrapped in layers of Java stack, as:

```
java.lang.IllegalArgumentException: Cannot find database connection - name cannot be empty.
```

which reads like a broken connection rather than an unset dropdown. Symptom
in a Perspective session: the action silently does nothing (a property-change
script or button appears dead) while the query itself is fine when tested in
the Designer's Testing tab, because that tab makes you pick a connection.
When several queries are added in one sitting, check them all at once:

```bash
for f in <project>/ignition/named-query/**/resource.json; do
  python3 -c "import json,sys;print(sys.argv[1], json.load(open(sys.argv[1]))['attributes'].get('database','<EMPTY>'))" "$f"
done
```
_Discovered: 2026-08-20_

### `scope` in a named query's resource.json is a resource-TYPE constant, not a per-query setting
Do not send someone hunting for a scope checkbox in Designer — there isn't one.
`scope` is written by the platform per resource type, and every named query in
a project carries the same value. Verify rather than assume:

```bash
find <project>/ignition/named-query -name resource.json \
  | while read f; do python3 -c "import json;print(json.load(open('$f')).get('scope'))"; done \
  | sort | uniq -c
```

Observed values (Ignition 8.3): `named-query` = `DG` (Designer + Gateway),
`script-python` = `A`, `startup` = `G`, `designer-properties` = `D`,
`message`/`global-props` = `A`.

Practical consequence: **named queries are gateway-runnable by default**, so a
Gateway Event (scheduled/timer/tag-change) script can call one without any
extra configuration. The things that actually need setting on a new named query
are its **type** and its **Database Connection** (see the previous gotcha —
that one is a real and silent trap). _Discovered: 2026-08-27_

### BLOB named-query params (sqlType 20) base64-decode STRING values — pass byte[], never str
If a named-query parameter of Ignition type BLOB (sqlType 20) receives a
string, Ignition treats it as base64 and silently DECODES it into the stored
bytes — invalid base64 chars are skipped, so 'hello blob' stores as the 6
garbage bytes 85 E9 65 A1 B9 68 with no error (verified empirically on 8.3.7;
serving it back renders as CJK mojibake like `呴e」h`). Jython 2 makes this
easy to trip: `'text'.encode('utf-8')` is still a str. Always pass a real
Java byte[]: `event.file.getBytes()` from a FileUpload, or in test snippets
`from java.lang import String; String('text').getBytes('UTF-8')`. Never route
file content through `event.file.getString()` into a BLOB param.
_Discovered: 2026-08-05_

### Ignition `sqlType` is NOT `java.sql.Types`
Named query parameters declare a `sqlType` that uses Ignition's internal enum,
not the standard JDBC `java.sql.Types`. Observed values:

| Ignition `sqlType` | Meaning           | Designer "Data Type" label |
|--------------------|-------------------|----------------------------|
| `2`                | Integer (IDs)     | Integer                    |
| `7`                | String / TEXT     | String                     |
| `20`               | BLOB / binary     | **ByteArray** (verified 8.3.7) |

Note the last one: there is no "BLOB" or "Binary" entry in the Designer's
Data Type dropdown, so a param that must carry `bytea`/`varbinary` bytes is
easy to think unsupported. Pick **ByteArray**. When in doubt about any
sqlType, open an existing named query that already uses it and copy the
label — the JSON stores the enum number, the dropdown shows a different
name.

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

**Addendum — the key lives in the gateway DATA volume, and volumes outlive
repo clones.** Re-cloning the repo does NOT rotate the key: if the Docker
gateway data volume (e.g. `gw-data_dev`) survives, the fresh clone's committed
ciphertexts decrypt fine, because the same keystore is still there. Verified
empirically: a from-scratch clone + `docker compose up` against a months-old
gw volume produced zero decryption faults and live JDBC sessions. So before
walking through the manual re-enter flow, check whether an old gw data volume
exists (`docker volume ls`) — reusing it is the zero-effort fix. Conversely,
deleting the volume (e.g. a teardown script) is what actually breaks the
committed passwords. There is no plaintext seeding in 8.3 config.json; the
only programmatic route is `POST /data/api/v1/encryption/encrypt` with a
write-scope API key, which itself requires Gateway UI setup first.
_Discovered: 2026-08-03_

### `GATEWAY_ADMIN_PASSWORD` is ignored on a reused data volume — reset via `gwcmd.sh -p`
The Docker image's `GATEWAY_ADMIN_USERNAME`/`GATEWAY_ADMIN_PASSWORD` env vars
only apply during first-launch commissioning of an empty data volume. If the
gateway data volume is reused (the normal case for a dev stack whose volumes
outlive repo clones), the admin login is whatever that gateway last had — the
env file is a red herring. Symptom: "Login failed" with the env-file password
on Designer/Perspective/Gateway UI.

**Fix:** `docker exec <gw> ./gwcmd.sh -p` (prints "Password has been reset"),
restart the gateway service, then open the gateway URL: it serves a one-step
commissioning page (`Resources needing commissioning: authSetup`) where the
user sets the new admin credentials. Set them to match the env file so the
repo stays truthful. The entrypoint does NOT auto-seed this re-commissioning
from env vars (that's first-launch only). The reset only re-provisions the
internal IdP admin user; the keystore and embedded JDBC secrets are untouched.
_Discovered: 2026-08-03_

**Follow-up — the reset leaves a split-brain IdP config that silently breaks
Perspective login.** `gwcmd -p` rewrites security-properties to point the
gateway's system auth at its new `temp` IdP/user-source, but Perspective
projects still resolve to the ORIGINAL IdP. Gateway UI + Designer then work
while Perspective sessions loop: "You must log in to continue" → IdP login
succeeds (or auto-passes via cookie) → bounced straight back to the same
prompt, no error anywhere (WARN-level logs stay quiet; the ws "errored out"
warnings are just the auth redirect killing the socket, not the cause).
Ignition keeps ONE web-auth session per browser tagged by IdP, so a session
bound to `temp` can never satisfy a project wanting the original IdP. The
durable fix: add your user to the user source behind the ORIGINAL IdP (for an
internal-type IdP just copy the user entry between `user-source/*/users.json`
files — the `[salt]hash` passwords are portable), then point
security-properties back at the original IdP (`systemIdentityProvider`,
`systemAuthProfile`, `designerAuthStrategy: IDENTITY_PROVIDER`) and restart.
One IdP for everything = no mismatch possible. Also: an IdP named after a
cloud provider (e.g. "AzureAD") in a dev config collection may be
`"type": "internal"` — check `config.json` before assuming users must be
added in the cloud tenant. _Discovered: 2026-08-05_

### "Unable to map the IdP attribute source to a user" — id mapped from a claim the user doesn't have
An internal-type IdP presents users as OIDC-ish claims (`sub`,
`preferred_username`, `given_name`, `family_name`, `email` from the email
contactInfo, `roles`). If the IdP's `userAttributeMapper` maps the required
`id` from `email` (common in configs cloned from a real cloud IdP), any user
WITHOUT an email contactInfo authenticates successfully but then fails
user-mapping: gateway log shows `gateway.IdentityProvider — Unable to map the
IdP attribute source to a user` (ERROR), and the symptom is a silent
Perspective login loop or a Designer-SSO callback "Internal Server Error" —
while other users (with emails) log in fine, which makes it look
account-specific. Fix: map `id` from `sub` (what Ignition's stock internal
IdP uses) in the IdP's `config.json`, or give the user an email contactInfo.
When hunting these, grep system_logs for logger `IdentityProvider` — filters
like `%idp%`/`%uth%` miss that logger name entirely. _Discovered: 2026-08-05_

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

## Perspective File Upload

### 8.3 caps uploads at ~19.9 MB in web.xml, `fileSizeLimit` is ignored, and the failure is SILENT
Ignition 8.3 added a hard servlet-level cap on the File Upload component:
files must be smaller than **20,848,820 bytes (19.88 MB)** regardless of the
component's `fileSizeLimit` prop. It lives in the `DataRoutes` servlet's
multipart config:

```
<Ignition>/webserver/webapps/main/WEB-INF/web.xml
  <servlet-name>DataRoutes</servlet-name>
  <multipart-config><max-file-size>20848820</max-file-size> ...
```

The failure mode is nasty, because three things hide it:

1. `POST /data/perspective/upload-file/...` returns **500** and the component
   still reports **"Upload successful"** to the user — a silent data-loss bug.
2. **Nothing is logged anywhere** — not `system_logs.idb`, not stdout, even
   with every Perspective logger at DEBUG. Jetty rejects the multipart body
   before Ignition's servlet code runs, so `onFileReceived` never fires and
   your own try/except never sees it.
3. Because the script never runs, gateway-side error handling cannot report
   it. Any "upload failed" feedback has to come from the component's own
   client-side `fileSizeLimit` check.

**Diagnosis shortcut:** if uploads work below ~15 MB and fail above ~20 MB
with a 500 and zero logs, it is this. Don't bisect file sizes or chase the
websocket `max-message-size` parameter — uploads are HTTP POST, not websocket.

**Mitigation:** set the component's `fileSizeLimit` just *below* 19.88 MB so
the component rejects oversized files client-side with a real message instead
of letting them 500 silently. Only raise `max-file-size` in web.xml if large
files are genuinely required — note it is inside the install/image (NOT under
`data/`), so in Docker it does not survive container recreation unless baked
into the image, and production gateways need the same edit.
_Discovered: 2026-08-13_

## Blob Server module (Automation Professionals)

### BlobServe does NOT support HTTP range requests — video/audio cannot seek
The `/system/blob/<project>/<query>` endpoint answers a `Range:` request with
`200 OK` and the entire body, never `206 Partial Content`, and sends no
`Accept-Ranges` header. Verified directly on Blob Serve 1.1.0 / Ignition 8.3.7:

```bash
curl -s -D- -o /dev/null -H "Range: bytes=0-1023" \
  "http://<gw>/system/blob/<project>/BLOB/get?id=<id>"   # -> HTTP/1.1 200 OK
```

Consequence: an `<video>`/Video Player fed from BlobServe **plays but cannot
scrub** — dragging the scrubber does nothing, because seeking requires range
support. There is no setting to change; the module is minimal by design
(its author describes it as ~352 lines of Java). Images and PDFs are
unaffected (they load whole anyway).

If a project needs seekable media, plan for a different serving path (a
WebDev endpoint that implements ranges, or static hosting) rather than
assuming BlobServe will do it. Decide this BEFORE building UI around video.
_Discovered: 2026-08-13_

## Playwright e2e testing (debug-tools)

### Driving `ia.input.barcodescannerinput` headless: focus the `<ul>`, type, press Enter
The barcode scanner input renders as `<ul class="ia_BarcodeScannerInputComponent">`
(each scanned value is an `<li>`) with **no `<input>` element**: it captures a
fast keystroke burst terminated by Enter, exactly like the real hardware. So
Playwright drives it the same way the scanner does:
```python
ul = page.locator('ul[data-component="ia.input.barcodescannerinput"]').nth(i)
ul.click()                       # focus it
page.keyboard.type("18", delay=10)
page.keyboard.press("Enter")     # the regex `(payload)Enter` needs the terminator
```
The component's `regex` matches `(<payload>)Enter` — the literal token `Enter`
is appended when the Enter key is pressed; without it the scan never commits.
Because there's no `<input>`, `driver.type()` (which targets input-like
elements) won't work; use the focus-the-`<ul>` + `keyboard` approach. The
numeric-entry-field DOES render a real `<input>`, reachable as
`[data-component="ia.input.numeric-entry-field"] input`. _Discovered: 2026-06-02_

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
