# Security Tips (securinglaravel.com)

Stephen Rees-Carter's "Securing Laravel" newsletter. Mostly Laravel, but the underlying principles often apply to any web stack.

## How to use this file

- **Primary use case:** the `security-review-plus` skill reads this file in full during its Phase 2 and applies every entry's **detection heuristic** to the code under review. When asked for a security audit outside that skill, do the same by hand: read every item below, check the code against each heuristic, and surface matches as findings.
- **Secondary use case:** if you happen to notice one of these patterns in code you're already reviewing, flag it even outside a formal audit.
- Nothing auto-loads this file outside the skill. Pull it in when explicitly asked, or when the task is clearly a security review.
- **Always evaluate the stored solution before applying it.** Solutions can go stale (framework changes, new defaults, deprecated APIs). Confirm the fix is still current and idiomatic for the project's stack and version before recommending it.
- **"Needs solution" items:** when you encounter the problem in real code, propose a fix, evaluate it, then update the entry below with the solution and remove the marker.

## Adding new tips

The user will paste one or more article URLs (always from securinglaravel.com). For each:
1. Fetch the article and extract the schema fields below. If the solution is paywalled or absent, set **Solution** to `Needs solution` and stop, do not invent a fix at ingestion time.
2. Append the new entry to the bottom of the file. Do not reorder or regroup existing entries unless the user asks. If the list ever grows past ~25 items and scanning gets unwieldy, propose a grouping scheme to the user before reorganizing.
3. If the new article clearly overlaps an existing entry (same vulnerability class, same detection heuristic), merge into the existing entry instead of creating a near-duplicate. Add the new URL as a second source line and fold any new pitfalls/heuristics in.
4. This file is published (via the public claude-code-tools repo), so entries must stay publishable: write them in your own words, distilled only from publicly accessible article content, and always cite the source URL. Never reproduce paywalled article details beyond what is publicly visible, and never include findings, code, or identifying details from private codebases.

## Schema

Each entry has:
- **Date added** (when this entry was first written into this file)
- **Source** (article URL)
- **Scope** (`General` = applies to any web framework; `Laravel` = Laravel-specific mechanism)
- **Summary** (1-2 sentences)
- **Common pitfalls** (what developers get wrong)
- **Detection heuristic** (concrete patterns/symbols to grep for, or code shapes to scan)
- **Solution** (the fix, or `Needs solution` if not yet known)

---

## Signed URLs without per-user binding

- **Date added:** 2026-04-28
- **Source:** https://securinglaravel.com/security-tip-the-signed-url-trap/
- **Scope:** General (applies to any signed-token flow: magic links, invites, file downloads, previews)
- **Summary:** A signed URL whose payload contains no user-identifying parameter produces the same signature for every user. An attacker can mint a valid signed URL on their own account and trigger the action against a victim's session, because signature verification only proves "the server signed this," not "the server signed this for you."
- **Common pitfalls:**
  - Conflating signature verification (tamper-proofing) with session/user binding.
  - Assuming the current session's user context alone is sufficient authorization on a signed-URL endpoint.
  - Magic-login or one-click-action endpoints that take no user identifier in the URL itself.
- **Detection heuristic:**
  - Laravel: `URL::signedRoute(`, `URL::temporarySignedRoute(`, `->signedRoute(`, routes guarded by `signed` middleware. Inspect the parameters being signed. If the route is user-specific but no user id/email/uuid/hash is in the parameters, flag it.
  - Generic: any HMAC/JWT-signed link handler that performs a user-context action and reads `Auth::user()` (or equivalent session user) without cross-checking against a parameter embedded in the link.
- **Solution:** Embed a user-identifying parameter (id, uuid, or hash of user+purpose) into the signed URL, and on the receiving end verify both (a) the signature, and (b) that the parameter matches the acting user / intended target. For magic-login flows, do not rely on session state at all, the URL must fully identify the target user.

---

## State-changing actions on GET requests

- **Date added:** 2026-04-28
- **Source:** https://securinglaravel.com/security-tip-stop-putting-actions-on-get-requests/
- **Scope:** General (HTTP semantics, not framework-specific)
- **Summary:** GET requests can be triggered without user intent from `<img>`, `<link>`, prefetch, redirects, email previewers, and crawlers, and they bypass most CSRF defenses. Any state mutation behind GET is a CSRF / drive-by-action waiting to happen.
- **Common pitfalls:**
  - "It's behind auth, so it's safe." Auth alone does not stop CSRF; the victim's browser carries the cookie automatically.
  - Convenience routes like `/posts/{id}/delete`, `/users/{id}/activate`, `/logout` exposed as GET.
  - Email-rendering services and link previewers fetching GET URLs and accidentally executing the action.
- **Detection heuristic:**
  - Laravel: `Route::get(` whose handler calls `->delete(`, `->update(`, `->save(`, `->create(`, `DB::`, dispatches a job, sends mail, or otherwise mutates state. Also scan `web.php`/`api.php` for verbs in the URI like `/delete`, `/activate`, `/disable`, `/approve` bound to GET.
  - Generic: any GET route handler that writes to a database, calls an external API with side effects, or queues work.
- **Solution:** Use POST/PUT/PATCH/DELETE for state changes so CSRF tokens and SameSite cookie protections engage. If the entry point must be a link in an email (a true GET with no form), use a signed URL bound to the user (see the signed-URL entry above) and ideally require a confirmation POST after the user lands.

---

## JWTs without an expiration claim

- **Date added:** 2026-04-28
- **Source:** https://securinglaravel.com/security-tip-your-jwt-might-be-a-forever-key/
- **Scope:** General (any system using JWTs)
- **Summary:** A JWT minted without an `exp` claim is valid forever. If it leaks via logs, a breach, an email, or a copy-pasted curl command, there is no time-based revocation, so the leaked token grants access until the signing key is rotated (which invalidates every other token too).
- **Common pitfalls:**
  - Assuming JWTs are inherently time-limited. They are not, `exp` is optional.
  - Assuming the JWT library validates expiration by default. Some do not, and even those that do skip the check if `exp` is absent.
  - Treating JWTs as revocable like sessions. Without `exp` and without a server-side denylist, you cannot revoke a single token short of rotating the signing key.
- **Detection heuristic:**
  - Search token-issuing code for `payload`, `claims`, `->encode(`, `JWT::encode(`, `sign(` and check that an `exp` field is set. Look for missing `exp`, or `exp` set absurdly far out (years).
  - Search verification code for `decode(`/`verify(` calls that pass options disabling expiration validation, or libraries known to skip `exp` when absent.
  - Check token issuance for `iat` without a matching `exp`.
- **Solution:** Always set `exp` on issuance with a tight, purpose-appropriate window (minutes for API access tokens, hours for session-equivalent tokens, a refresh-token pattern for anything longer). Verify on the consuming side that `exp` is present and enforced; reject tokens missing the claim outright. If true revocation is required, pair with a short `exp` plus a server-side denylist or rotating signing keys.

---

## Validate critical config at boot, not at use

- **Date added:** 2026-04-28
- **Source:** https://securinglaravel.com/security-tip-validate-config-at-boot/
- **Scope:** General (principle), Laravel (example mechanism)
- **Summary:** Lazy validation of security-critical config (encryption keys, signing secrets, OAuth credentials, allowed-host lists) means a misconfigured app boots fine and only blows up when a specific code path is hit, possibly hours or days into a deploy. By then the window of insecure behavior may already have been exploited.
- **Common pitfalls:**
  - Checking config inside controller constructors, middleware, or just-in-time before use.
  - Silent fallbacks: `config('foo.key') ?? 'default'` masking that the real key is missing in production.
  - Relying on `.env.example` as documentation rather than enforcing presence at boot.
- **Detection heuristic:**
  - Grep for `config('...')` (and `env('...')` directly, which is its own smell) inside controllers, middleware, jobs, and listeners where the value is required for security to function. If the same key is not asserted in any service provider's `boot()`/`register()`, flag it.
  - Look for `?? '...'` or `?: '...'` defaulting on values that should never be defaulted (signing keys, secrets, tenant IDs).
- **Solution:** Assert presence and validity of security-critical config in a `ServiceProvider::boot()` (Laravel) or equivalent application-startup hook, throwing on missing/invalid values so the process fails to start. Example pattern from the article:
  ```php
  public function boot() {
      if (! config('app.magic.key')) {
          throw new RuntimeException('app.magic.key is required');
      }
  }
  ```
  Generalize the same pattern for any stack: a single startup function that throws if any required secret/setting is missing or malformed. Pair with health-check endpoints that fail closed if config is invalid.

---

## Authorize on ALL route files, including broadcast channels

- **Date added:** 2026-04-28
- **Source:** https://securinglaravel.com/security-tip-consider-all-routes-not-just-web/
- **Scope:** Laravel (specific to `routes/channels.php`), but the principle ("authorize at every entry point") is general
- **Summary:** Teams add `is_active`, role, or tenant checks to `web.php` and `api.php` routes but forget that `routes/channels.php` is a separate authorization surface. A deactivated user can still subscribe to broadcast channels and receive realtime data unless the same checks are repeated in the channel callbacks.
- **Common pitfalls:**
  - Assuming global middleware applies to broadcast authorization. It does not in the same way.
  - Channel callbacks that only check id matching: `return (int) $user->id === (int) $id;` without checking `is_active`, role, or tenant scope.
  - Forgetting other side-channel entry points: queued listeners that re-fetch a user, scheduled commands, webhook routes registered separately.
- **Detection heuristic:**
  - Open `routes/channels.php`. For every `Broadcast::channel(...)` callback, check that whatever conditions guard the matching `web.php`/`api.php` routes (active, role, tenant, subscription) are also enforced here. Specifically grep callbacks for `is_active`, role checks, tenant checks; flag callbacks that only compare ids.
  - More broadly: list every route file the framework loads (`web.php`, `api.php`, `channels.php`, `console.php`, custom route files registered in providers) and verify the same authorization rules apply. Don't forget Livewire components, Filament resources, and any custom HTTP entry points.
- **Solution:** Mirror access-control checks across every routing surface. For broadcast channels, repeat the user-state checks inside the callback:
  ```php
  Broadcast::channel('App.Models.User.{id}', function ($user, $id) {
      return $user->is_active && (int) $user->id === (int) $id;
  });
  ```
  Better: extract a single `Gate`/policy method that encodes "may this user act at all right now?" and call it from middleware, channel callbacks, job handlers, and console commands alike, so there is one source of truth.

---

## SameSite left implicit, or downgraded to `none`

- **Date added:** 2026-08-03
- **Source:** https://securinglaravel.com/security-tip-do-you-know-your-samesite-cookies/
- **Scope:** General (cookie attribute, any stack), Laravel (config mechanism)
- **Summary:** `SameSite` is the browser-side half of CSRF defense, deciding whether a cookie rides along on cross-site requests. Leaving it unset delegates the decision to inconsistent browser defaults, and setting it to `none` switches the protection off entirely for every request the cookie touches.
- **Common pitfalls:**
  - "Browsers default to Lax anyway." Only Chromium does. Firefox's `network.cookie.sameSite.laxByDefault` is Nightly-only and false on release (Mozilla tried, hit breakage, reverted), and Safari relies on third-party cookie blocking, which does not cover the same cases.
  - Even on Chrome, unset is weaker than explicit. Chrome's "Lax-allowing-unsafe" exception sends attribute-less cookies on top-level cross-site POST for their first 2 minutes. An explicit `SameSite=Lax` cookie gets no such window.
  - `SESSION_SAME_SITE=null` or an empty value in `.env`. Laravel maps literal `null` to PHP null and the attribute is omitted from the header. It reads as configured and is not.
  - Setting `none` on the primary session cookie to unblock one embedded widget or a cross-origin SPA, instead of issuing a separate cookie for that one job.
  - `none` without `Secure`. Browsers reject the cookie outright, so logins silently break and the reflex fix is often to relax something else.
  - Treating SameSite as a CSRF replacement. `Lax` still permits top-level cross-site GET, so anything mutating state on GET is unprotected (see the GET-requests entry above). And same-site is not same-origin: a sibling app or XSS on `*.example.com` is same-site and gets the cookies.
- **Detection heuristic:**
  - Laravel: read `config/session.php` -> `same_site`. Flag `null`, `''`, or `'none'`. Check `.env`, `.env.example`, and deploy config for `SESSION_SAME_SITE`. If `none`, require `SESSION_SECURE_COOKIE=true`, check `SESSION_PARTITIONED_COOKIE`, and confirm CSRF tokens are still enforced on the affected routes.
  - Grep for cookies built with explicit arguments, which silently bypass the app-wide default: `Cookie::make(`, `cookie()->make(`, `->forever(`, `->withCookie(`, `new Cookie(`, `setSameSite(`. In `CookieJar::make()` the 9th positional argument is `$sameSite`; any explicit `'none'` or `null` there overrides `config/session.php` for that cookie only.
  - Cross-check that CSRF was not also relaxed on the same routes: `validateCsrfTokens(except: [...])` in `bootstrap/app.php` (Laravel 11+) or `VerifyCsrfToken::$except` (older).
  - Check `config/sanctum.php` stateful domains. A SPA on a true separate site pushes teams toward `none`; a SPA on a subdomain does not need it, `lax` plus a shared `SESSION_DOMAIN` covers it.
  - Generic: any hand-rolled `Set-Cookie` for a session or auth cookie with no SameSite attribute, or `SameSite=None` without `Secure`.
- **Solution:** Set the attribute explicitly rather than inheriting a default. `lax` is the correct baseline and is what Laravel ships:
  ```
  SESSION_SAME_SITE=lax
  SESSION_SECURE_COOKIE=true
  ```
  Use `strict` for high-value surfaces (admin panels, financial actions) where arriving from an external link with a live session is undesirable. Test inbound flows first, since `strict` lands email links and OAuth returns logged-out.
  Use `none` only when a cookie genuinely must travel cross-site (embedded widget, third-party iframe, cross-site API), and then:
  1. Keep the primary auth/session cookie at `lax` and issue a separate, minimally-scoped cookie for the cross-site case:
     ```php
     cookie()->make('widget_token', $value, 60, secure: true, httpOnly: true, sameSite: 'none');
     ```
  2. `Secure` is mandatory; browsers drop `None` cookies without it.
  3. Consider `Partitioned` (CHIPS), since browsers partition third-party cookies regardless. Laravel exposes this for the session cookie as `SESSION_PARTITIONED_COOKIE=true`, which requires `same_site=none` plus the secure flag.
  4. Keep server-side CSRF tokens. `none` means the browser has stopped helping.
  SameSite is defense-in-depth layered on CSRF tokens and correct HTTP verbs, never a substitute for either.

---

## Unserializing untrusted data (PHP object injection)

- **Date added:** 2026-08-21
- **Source:** https://securinglaravel.com/security-tip-encodingserialising/
- **Source:** https://securinglaravel.com/security-tip-can-you-safely-unserialise-classes/
- **Source (paywalled, exploitation mechanics only):** https://securinglaravel.com/in-depth-from-serialised-string-to-rce/
- **Scope:** General (insecure deserialization exists in every stack; the mechanics here are PHP/Laravel)
- **Summary:** `unserialize()` reconstructs whatever objects the input string describes, and unserialization plus later destruction runs magic methods (`__wakeup()`, `__unserialize()`, `__destruct()`) on classes the attacker picks from the entire vendor tree. Feeding it anything a user can influence is the classic path to RCE via gadget chains, and PHPGGC ships ready-made chains for Laravel and other major frameworks. Serialized strings are also trivially hand-editable, so the format carries no integrity of its own.
- **Common pitfalls:**
  - "The blob looks opaque, nobody will tamper with it." The format is documented and easy to edit by hand; obscurity is not integrity.
  - "We only serialize arrays/settings, there are no dangerous objects." The attacker decides what the string contains, not the code that wrote it, and any Composer project contains enough vendor classes for a gadget chain.
  - Treating a value as internal when it round-trips through the client (cookie, hidden input, query param, localStorage) or sits in a store another party can write to (shared Redis/cache, a user-writable DB column, uploaded files).
  - `allowed_classes` misconceptions: omitting the option or passing `true` allows every class; an allowlist only blocks instantiation of *other* classes, while the allowed classes' own magic methods still run, and oversized or deeply nested payloads remain a DoS vector. The PHP manual itself says not to pass untrusted input to `unserialize()` regardless of `allowed_classes`.
  - Signing or encrypting a serialized payload only helps while the key is secret. A leaked `APP_KEY` turns app code that calls Laravel's `decrypt()` on user-supplied ciphertext into the entry point, because `decrypt()` unserializes by default.
- **Detection heuristic:**
  - Grep for `unserialize(`. For each hit, trace the input: request data, cookies, headers, file contents, or anything that ever left the server and came back means HIGH. No second argument, or `['allowed_classes' => true]`, aggravates; `['allowed_classes' => false]` mitigates but does not make untrusted input acceptable.
  - Grep for `serialize(` and flag output that lands in a cookie, hidden form field, URL parameter, API response, or localStorage. Whatever goes out that way comes back through `unserialize()` later.
  - Laravel: `Crypt::decrypt(` or the `decrypt(` helper (the serializing variants; `decryptString` is not) called on ciphertext a user supplies. Also custom cache/queue/session drivers calling `unserialize`, and PHP-serialized DB columns users can write.
  - Watch for half-migrations: `json_decode(` with an `unserialize(` fallback for "legacy" values is still fully exploitable through the fallback.
- **Solution:** Never `unserialize()` data that crossed a trust boundary. For anything that round-trips through the browser or between services, use `json_encode()`/`json_decode()`; JSON cannot instantiate objects. If tamper-proofing is needed on top, HMAC-sign or encrypt the JSON (Laravel: `Crypt::encryptString()`/`decryptString()`) and verify before decoding. Where PHP serialization is genuinely required (framework internals, server-side-only payloads), keep the data out of attacker-writable channels and add `allowed_classes` as defense-in-depth:
  ```php
  unserialize($blob, ['allowed_classes' => false]);            // no objects at all (safest)
  unserialize($blob, ['allowed_classes' => [SafeDto::class]]); // only when objects are unavoidable
  ```
  Classes not on the list hydrate as `__PHP_Incomplete_Class`, so their magic methods never run. Treat the option as a seatbelt, not as permission to accept user-controlled serialized data.
