# Headless Perspective debugging with Playwright

This document explains the headless driver pattern that lets Claude
verify Ignition Perspective behavior end-to-end without ever asking the
user to drive the browser. ~5 seconds per cycle (open page → click → read
state → read gateway log), fully automated.

When in doubt — **read `SKILL.md` core rule 2b** for when to reach for
this; the short version is "when docs/forums don't yield a clear answer
on the first try, switch to headless verification rather than guessing."

## One-time setup (per Ignition project)

Pick a directory in the project for dev tooling. This document uses
`services/ignition/debug-tools/` (the convention in the repo where this
skill was developed), but anything works — adapt to the repo's
conventions. From the project root:

```bash
mkdir -p <dev-tools-dir>
cd <dev-tools-dir>
python3 -m venv venv
source venv/bin/activate
pip install --quiet --upgrade pip
pip install --quiet playwright
playwright install chromium
```

Then drop the driver template (next section) into `<dev-tools-dir>/driver.py`.

Make sure `venv/` is gitignored (most repos already have `**/venv` or
`venv` patterns). Verify before staging anything in that directory:

```bash
git check-ignore -v <dev-tools-dir>/venv
```

## Driver template

Adjust `GATEWAY` (host:port the gateway binds to — `localhost:9088` is the
default for dockerized setups; native installs may use 8088 or whatever
the gateway was configured for) and `PROJECT` (Perspective project name)
constants to the project at hand. Default URL is the configured primary
page (`/` mapping in `page-config/config.json`).

```python
"""Headless Perspective driver. Quick-iteration helper."""
import time
from playwright.sync_api import sync_playwright

GATEWAY = "http://localhost:9088"  # change to match your gateway host:port
PROJECT = "MyProject"              # change to match your Perspective project name


class Browser:
    def __init__(self, headless: bool = True, viewport=(1280, 800)):
        self._headless = headless
        self._viewport = viewport
        self._console: list[dict] = []

    def __enter__(self):
        self._pw = sync_playwright().start()
        self._browser = self._pw.chromium.launch(headless=self._headless)
        ctx = self._browser.new_context(viewport={"width": self._viewport[0],
                                                  "height": self._viewport[1]})
        self._page = ctx.new_page()
        self._page.on("console",
                      lambda m: self._console.append({"type": m.type, "text": m.text}))
        self._page.on("pageerror",
                      lambda e: self._console.append({"type": "pageerror", "text": str(e)}))
        return self

    def __exit__(self, *_):
        self._browser.close()
        self._pw.stop()

    def open(self, view_path: str = "", wait: float = 1.0):
        url = f"{GATEWAY}/data/perspective/client/{PROJECT}"
        if view_path:
            url = f"{url}/{view_path.lstrip('/')}"
        self._page.goto(url, wait_until="networkidle", timeout=20_000)
        time.sleep(wait)
        return self

    def reload(self, wait: float = 1.0):
        self._page.reload(wait_until="networkidle", timeout=20_000)
        time.sleep(wait)
        return self

    def click(self, selector: str, wait: float = 0.3):
        self._page.click(selector, timeout=10_000)
        time.sleep(wait)
        return self

    def type(self, selector: str, text: str, delay_ms: int = 15, blur: bool = True):
        """Keystroke-style input. Required for Perspective bidirectional bindings."""
        loc = self._page.locator(selector)
        loc.click()
        loc.press("Meta+A")
        loc.press("Delete")
        loc.type(text, delay=delay_ms)
        if blur:
            loc.press("Tab")
        return self

    def eval(self, js: str):
        return self._page.evaluate(js)

    def screenshot(self, path: str = "/tmp/perspective.png"):
        self._page.screenshot(path=path, full_page=False)
        return path

    def console(self, level: str = "all") -> list[dict]:
        if level == "all":
            return list(self._console)
        if level == "error":
            return [e for e in self._console if e["type"] in ("error", "pageerror")]
        if level == "warn":
            return [e for e in self._console if e["type"] in ("warning", "error", "pageerror")]
        raise ValueError(level)
```

## Typical debug cycle

```bash
cd <dev-tools-dir>
venv/bin/python - <<'PY'
from driver import Browser
with Browser() as b:
    b.open("", wait=2.5)
    # Replicate the user action precisely
    b.click("div.tr div.tc:has-text('SomeRowText')", wait=0.3)
    b.click("button:has-text('Some Button')", wait=0.8)
    b.type("textarea", "new value")
    b.click("button:has-text('Save')", wait=2.0)
    # Verify some piece of state
    print(b.eval("[...document.querySelectorAll('div.tc[data-column-id=\"someCol\"]')].map(c => c.innerText.trim())"))
PY
```

Then pull and query gateway-side logs. The `system_logs.idb` location
depends on the deployment:

```bash
# --- Docker-based gateway ---
docker compose cp <service>:/usr/local/bin/ignition/logs/system_logs.idb /tmp/
# Replace <service> with the gateway service name in docker-compose.yml

# --- Native install ---
# Linux:   /usr/local/ignition/logs/system_logs.idb
# Windows: C:\Program Files\Inductive Automation\Ignition\logs\system_logs.idb
# macOS:   /usr/local/ignition/logs/system_logs.idb
# Copy or query it in place.

sqlite3 /tmp/system_logs.idb \
  "SELECT datetime(timestmp/1000,'unixepoch'), substr(formatted_message,1,300)
   FROM logging_event
   WHERE logger_name='<your-named-logger>'
     AND timestmp > (strftime('%s','now')*1000 - 60000)
   ORDER BY timestmp DESC LIMIT 15;"
```

Use a project-specific logger name in your scripts
(`system.util.getLogger('myProject')`) so the `WHERE logger_name=` filter
narrows to just your output and not the gateway's own noise.

## Common pitfalls in the driver itself

### Use `b.type()`, not `b.fill()`, for Perspective bindings

Playwright's `page.fill()` sets the DOM value and dispatches an `input`
event but doesn't simulate keystrokes or a blur. **Perspective's
bidirectional bindings often only commit on a real change/blur event**,
so `fill()` updates the visible text but not the bound prop. The
debugger then sees stale data in the Save handler.

`type()` (the wrapper in the driver above) handles select-all, delete,
type with realistic delays, and Tab-to-blur — covering Perspective's
commit path.

### Selector hints for Perspective components

| Target | Selector |
|---|---|
| Table rows (excluding header) | `div.tr:not(.header)` |
| Specific row by cell text | `div.tr div.tc:has-text('<text>')` |
| Specific cell of a column | `div.tc[data-column-id="<field>"]` |
| Button by visible label | `button:has-text('<label>')` |
| Popup container (generic) | `[class*="popup"]` |
| Form text-area | `textarea` (usually a single one per popup) |

Playwright's `:has-text` pseudo-selector is Playwright-only; works in
locator selectors but not in plain `document.querySelector`. Inside
`eval()` use a different idiom (e.g.
`[...document.querySelectorAll('button')].find(b => b.textContent.includes('...'))`).

### Read the gateway log between steps, not just at the end

When a step doesn't behave as expected, copy `system_logs.idb` and query
*right then*, not after the next click. The logs are append-only and
ordered, so multiple events in the same cycle interleave; reading
mid-cycle isolates which step's logs you're inspecting.

### Don't trust visible-text checks for "did this update?"

If you're testing whether a binding refreshed, prefer reading the
component's actual bound DOM value (e.g.
`document.querySelector('...').textContent`) rather than relying on
screenshots. Screenshots are useful for layout sanity but slow and
imprecise.

## Building incrementally with the driver

The same driver is the basis for "build one little piece at a time,
verify each step." When implementing a new feature where you're not sure
how a mechanism works:

1. **Place a minimum probe.** Add a button + a log statement that proves
   the simplest piece works (e.g. "the button click fires").
2. **Verify headless.** One `venv/bin/python` cycle. Read log. Confirm.
3. **Add the next piece.** A new log. A binding. A param.
4. **Verify headless again.** Each addition gets its own cycle.

Compare to "compose three Perspective mechanisms at once and pray it
works." The composed version is unfixable when broken — too many
variables. The incremental version always isolates the failing step.

This is the same pattern as TDD's red-green-refactor, except the
verification step is manual through Playwright instead of an assertion
library. The cycle time (~5s) is short enough that the discipline is
cheap.

## When to NOT use this

- **Pure backend changes** (DB schema, named queries that aren't
  consumed by a view yet). Test those directly via `docker compose exec
  postgres psql` — faster than booting a browser.
- **Gateway config changes** (DB connections, security levels, API
  keys). Test via direct API calls or the Gateway web UI.
- **Trivial CSS-only tweaks.** A screenshot via `b.screenshot()` is
  fine, but the full driver setup is overkill.
- **When the user is actively driving the browser themselves** for
  manual exploration. Coordinate first; don't fight for the session.
