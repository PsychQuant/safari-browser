# save-image Specification

## Purpose

TBD - created by archiving change 'save-image-subcommand'. Update Purpose after archive.

## Requirements

### Requirement: save-image subcommand downloads element resource to output path

The `safari-browser` CLI SHALL provide a `save-image <output>` subcommand that downloads a DOM element's raw resource to the specified output path. The subcommand SHALL accept the full `TargetOptions` (`--url`, `--window`, `--tab`, `--document`, `--tab-in-window`, `--first-match`) plus `--element <selector>` (required), `--element-index <N>` (optional, 1-indexed), `--track <src|currentSrc|poster>` (optional, default `currentSrc`), and `--with-cookies` (optional opt-in flag).

The subcommand SHALL NOT require Accessibility permission — its pipeline is JavaScript-plus-HTTP, distinct from the Accessibility-plus-CoreGraphics pipeline used by `screenshot`.

The subcommand SHALL resolve the element via `document.querySelectorAll(selector)` against the resolved target document (light DOM only; Shadow DOM and iframe content are out of scope).

#### Scenario: save-image downloads an img element's source

- **WHEN** a page contains `<img id="hero" src="https://cdn.example.com/hero.jpg">`
- **AND** the user runs `safari-browser save-image out.jpg --url "example.com" --element "#hero"`
- **THEN** the system SHALL resolve `#hero` to that img element
- **AND** SHALL read `element.currentSrc || element.src` to obtain the resource URL
- **AND** SHALL download the resource over HTTPS via URLSession
- **AND** SHALL write the downloaded bytes to `out.jpg` verbatim

#### Scenario: save-image serializes an inline SVG element

- **WHEN** a page contains `<svg id="logo" viewBox="0 0 100 100">...</svg>`
- **AND** the user runs `safari-browser save-image logo.svg --element "#logo"`
- **THEN** the system SHALL detect the element's tagName as SVG
- **AND** SHALL serialize the element's `outerHTML`
- **AND** SHALL write the serialized string as UTF-8 text to `logo.svg`
- **AND** SHALL NOT involve URLSession or any HTTP request


<!-- @trace
source: save-image-subcommand
updated: 2026-04-24
code:
  - .remember/logs/autonomous/save-071446.log
  - .remember/logs/autonomous/save-073920.log
  - .remember/logs/autonomous/save-071013.log
  - .remember/tmp/save-session.pid
  - .remember/logs/autonomous/save-073132.log
-->

---
### Requirement: --element is required and multi-match is fail-closed with --element-index disambiguation

The `save-image` subcommand SHALL reject invocations without `--element` at argument-parsing time. The subcommand SHALL reject `--element-index` supplied without `--element`, and SHALL reject `--element-index N` where `N < 1`.

When `--element <selector>` matches exactly one DOM element, the subcommand SHALL use that element. When it matches zero elements, the subcommand SHALL throw `elementNotFound(selector:)`. When it matches more than one element AND `--element-index` is not supplied, the subcommand SHALL throw `elementAmbiguous(selector:, matches:)` where the `matches` array includes, for each match in document order, the element's bounding rectangle, a compact `tag.class#id` attribute string, and a text snippet (first 60 characters, whitespace-trimmed, or nil if no text). The ambiguous error's `errorDescription` SHALL list every match and suggest both refining the selector and using `--element-index N`.

When `--element-index N` is supplied and N exceeds the match count, the subcommand SHALL throw `elementIndexOutOfRange(selector:, index:, matchCount:)`. When the selector raises a JavaScript `SyntaxError`, the subcommand SHALL throw `elementSelectorInvalid(selector:, reason:)`.

The subcommand SHALL NOT offer a silent first-match fallback (no `--first-match` flag for `--element`).

#### Scenario: save-image without --element is rejected at validation

- **WHEN** the user runs `safari-browser save-image out.jpg --url "example.com"` without supplying `--element`
- **THEN** the argument parser SHALL reject the command with a validation error
- **AND** SHALL NOT attempt any download

#### Scenario: save-image with ambiguous match fails closed with rich error

- **WHEN** a page contains three `<img class="product">` elements
- **AND** the user runs `safari-browser save-image out.jpg --element "img.product"`
- **AND** does NOT supply `--element-index`
- **THEN** the subcommand SHALL throw `elementAmbiguous(selector: "img.product", matches: [...])`
- **AND** the `matches` array SHALL contain three entries in document order
- **AND** the `errorDescription` SHALL list each match's rect, attribute string, and text snippet
- **AND** SHALL suggest both selector refinement and `--element-index N`

#### Scenario: save-image with --element-index picks the Nth match

- **WHEN** a page contains three `<img class="product">` elements with srcs at URLs `A`, `B`, `C` in document order
- **AND** the user runs `safari-browser save-image out.jpg --element "img.product" --element-index 2`
- **THEN** the subcommand SHALL select the second matching element
- **AND** SHALL download URL `B` to `out.jpg`


<!-- @trace
source: save-image-subcommand
updated: 2026-04-24
code:
  - .remember/logs/autonomous/save-071446.log
  - .remember/logs/autonomous/save-073920.log
  - .remember/logs/autonomous/save-071013.log
  - .remember/tmp/save-session.pid
  - .remember/logs/autonomous/save-073132.log
-->

---
### Requirement: URL requests include Referer and Safari User-Agent, drop Referer on cross-origin redirect

When the subcommand downloads via URLSession (the default, non-`--with-cookies` path), it SHALL set the `Referer` request header to the resolved document's URL (obtained via `document.URL` JavaScript evaluation). It SHALL set the `User-Agent` request header to the Safari User-Agent string (obtained once per invocation via `navigator.userAgent` JavaScript evaluation).

The subcommand SHALL follow HTTP redirects by default. When a redirect is cross-origin (differing scheme, host, or port), the subcommand SHALL drop the `Referer` header from the redirected request. When a redirect is same-origin, the subcommand SHALL preserve the `Referer` header.

#### Scenario: URL download sends Referer matching document URL

- **WHEN** Safari has `https://shop.example.com/product/42` loaded
- **AND** the user runs `safari-browser save-image out.jpg --url shop.example.com --element "img.hero"`
- **AND** the img's src is `https://cdn.shop.example.com/assets/hero.jpg`
- **THEN** the outgoing HTTPS request to the CDN SHALL include the header `Referer: https://shop.example.com/product/42`
- **AND** SHALL include a `User-Agent` header matching the Safari browser's UA string

#### Scenario: Cross-origin redirect drops Referer

- **WHEN** the CDN at `https://cdn.shop.example.com/assets/hero.jpg` returns a `302` redirect to `https://third-party.example/resized/hero.jpg`
- **THEN** the request to `third-party.example` SHALL NOT include the `Referer` header
- **AND** SHALL still include the `User-Agent` header


<!-- @trace
source: save-image-subcommand
updated: 2026-04-24
code:
  - .remember/logs/autonomous/save-071446.log
  - .remember/logs/autonomous/save-073920.log
  - .remember/logs/autonomous/save-071013.log
  - .remember/tmp/save-session.pid
  - .remember/logs/autonomous/save-073132.log
-->

---
### Requirement: --with-cookies uses JS fetch with 10 MB hard cap

When the user supplies `--with-cookies`, the subcommand SHALL fetch the resource through Safari's own `fetch()` API via `doJavaScript`, so that the request inherits the document's cookies, credentials, and session. The subcommand SHALL NOT use URLSession on this path.

The subcommand SHALL cap the resource size at 10 MB. It SHALL emit a stderr warning when the resource exceeds 5 MB but is still under the cap. When the resource exceeds 10 MB, the subcommand SHALL throw `downloadSizeCapExceeded(url:, capBytes:, actualBytes:)` and the `errorDescription` SHALL suggest dropping `--with-cookies` to use the default URLSession path if the resource does not require authentication.

The base64 payload transfer from Safari to Swift SHALL reuse the existing `SafariBridge.doJavaScriptLarge` chunked-read helper to avoid V8 O(n²) string-concatenation pathology (the same safety pattern established by #24 for `upload --js`).

#### Scenario: --with-cookies fetches through Safari and inherits session

- **WHEN** Safari is logged into `members.example.com` with an active session cookie
- **AND** the user runs `safari-browser save-image paid.jpg --url members.example.com --element "img.paid" --with-cookies`
- **THEN** the subcommand SHALL execute `fetch(src, {credentials: 'include'})` via doJavaScript
- **AND** SHALL NOT use URLSession for this download
- **AND** the response bytes SHALL be transferred as base64 via chunked read
- **AND** SHALL be written to `paid.jpg`

#### Scenario: --with-cookies beyond 10 MB fails closed

- **WHEN** the user runs `safari-browser save-image big.mp4 --element "video.demo" --track src --with-cookies`
- **AND** the video resource's FileReader data URL exceeds 10 MB
- **THEN** the subcommand SHALL throw `downloadSizeCapExceeded(url:, capBytes: 10485760, actualBytes:)`
- **AND** the `errorDescription` SHALL suggest dropping `--with-cookies` if the resource does not require authentication
- **AND** SHALL NOT write any file

#### Scenario: --with-cookies over 5 MB emits stderr warning

- **WHEN** a resource fetched via `--with-cookies` measures 7 MB
- **THEN** the subcommand SHALL emit a stderr warning indicating JS bridge overhead may be significant at this size
- **AND** SHALL proceed with the download
- **AND** SHALL write the file normally


<!-- @trace
source: save-image-subcommand
updated: 2026-04-24
code:
  - .remember/logs/autonomous/save-071446.log
  - .remember/logs/autonomous/save-073920.log
  - .remember/logs/autonomous/save-071013.log
  - .remember/tmp/save-session.pid
  - .remember/logs/autonomous/save-073132.log
-->

---
### Requirement: Output path is trusted verbatim with no MIME inference

The subcommand SHALL write downloaded bytes (or serialized SVG UTF-8 text) to the exact output path specified by the user, without inferring, modifying, or appending a file extension.

The subcommand SHALL NOT read the `Content-Type` response header to choose an extension. The subcommand SHALL NOT consult any MIME-to-extension mapping table. The subcommand SHALL NOT fall back to a default extension such as `.bin` when the content type is unknown. The subcommand SHALL NOT warn about mismatches between the user's chosen extension and the server's declared content type.

If the output path already exists, the subcommand SHALL overwrite it silently, matching the behavior of `screenshot`.

#### Scenario: Output extension is trusted regardless of server Content-Type

- **WHEN** the user runs `safari-browser save-image out.png --element "img.x"`
- **AND** the server responds with `Content-Type: image/jpeg`
- **THEN** the subcommand SHALL write the response bytes to `out.png` verbatim
- **AND** SHALL NOT rename the file to `.jpg`
- **AND** SHALL NOT emit any Content-Type mismatch warning

#### Scenario: Output path without extension is written literally

- **WHEN** the user runs `safari-browser save-image out --element "img.x"`
- **THEN** the subcommand SHALL write the response bytes to the literal path `out` with no extension appended
- **AND** SHALL NOT consult the URL path's extension or the response Content-Type

#### Scenario: Existing output file is overwritten silently

- **WHEN** `/tmp/out.jpg` already exists with old content
- **AND** the user runs `safari-browser save-image /tmp/out.jpg --element "img.x"`
- **THEN** the subcommand SHALL overwrite `/tmp/out.jpg` with the new download
- **AND** SHALL NOT prompt the user
- **AND** SHALL NOT print a warning about overwriting


<!-- @trace
source: save-image-subcommand
updated: 2026-04-24
code:
  - .remember/logs/autonomous/save-071446.log
  - .remember/logs/autonomous/save-073920.log
  - .remember/logs/autonomous/save-071013.log
  - .remember/tmp/save-session.pid
  - .remember/logs/autonomous/save-073132.log
-->

---
### Requirement: URL scheme policy supports http(s) and data:, fails closed on others

The subcommand SHALL allow both `https://` and `http://` URL schemes. For `http://` URLs, the subcommand SHALL emit a stderr warning indicating cleartext traversal. The subcommand SHALL NOT hard-block `http://`.

The subcommand SHALL handle `data:` URLs (`data:<mime>;base64,<payload>`) by decoding the base64 payload via Foundation, bypassing URLSession. The output path rule (bytes written to user's path verbatim) applies.

For any other URL scheme (`blob:`, `ftp:`, `javascript:`, `file:`, or unknown schemes), the subcommand SHALL throw `unsupportedURLScheme(url:, scheme:)` and SHALL NOT attempt any download.

#### Scenario: http:// URL succeeds with stderr warning

- **WHEN** an image's src is `http://intranet.example/logo.png`
- **AND** the user runs `safari-browser save-image logo.png --element "img.x"`
- **THEN** the subcommand SHALL emit a stderr warning about cleartext HTTP
- **AND** SHALL still download the resource via URLSession
- **AND** SHALL write `logo.png`

#### Scenario: data: URL is decoded via Foundation

- **WHEN** an element's src is `data:image/png;base64,iVBORw0KGgoAAAA...`
- **AND** the user runs `safari-browser save-image icon.png --element "img.x"`
- **THEN** the subcommand SHALL split on the first comma after `data:...;base64,`
- **AND** SHALL base64-decode the payload via Foundation
- **AND** SHALL write the decoded bytes to `icon.png`
- **AND** SHALL NOT make any network request

#### Scenario: blob: URL fails closed

- **WHEN** an element's src is `blob:https://example.com/abc-123`
- **AND** the user runs `safari-browser save-image out.jpg --element "img.x"`
- **THEN** the subcommand SHALL throw `unsupportedURLScheme(url: "blob:...", scheme: "blob")`
- **AND** SHALL NOT write any file

#### Scenario: ftp:// URL fails closed

- **WHEN** an element's src is `ftp://files.example.com/image.jpg`
- **AND** the user runs `safari-browser save-image out.jpg --element "img.x"`
- **THEN** the subcommand SHALL throw `unsupportedURLScheme(url: "ftp://...", scheme: "ftp")`
- **AND** SHALL NOT write any file


<!-- @trace
source: save-image-subcommand
updated: 2026-04-24
code:
  - .remember/logs/autonomous/save-071446.log
  - .remember/logs/autonomous/save-073920.log
  - .remember/logs/autonomous/save-071013.log
  - .remember/tmp/save-session.pid
  - .remember/logs/autonomous/save-073132.log
-->

---
### Requirement: Error cases cover missing src, unsupported tag, download failure

The subcommand SHALL define three additional fail-closed error paths specific to the resource-download pipeline (supplementing the #30 element errors it reuses):

- When the resolved element's tagName is supported (`img`, `source`, `picture`, `video`, `audio`, `svg`) but the chosen resource attribute (`currentSrc`, `src`, or `poster`) is empty, the subcommand SHALL throw `elementHasNoSrc(selector:, tagName:)`.
- When the resolved element's tagName is NOT in the supported list (e.g., `div`, `canvas`, `iframe`, `object`, `embed`), the subcommand SHALL throw `unsupportedElement(selector:, tagName:)`.
- When an HTTP request fails (non-2xx status code, network error, or timeout), the subcommand SHALL throw `downloadFailed(url:, statusCode:, reason:)` where `statusCode` is nil for network errors and `reason` captures the specific failure.

Each of these errors SHALL NOT leave a partial file at the output path.

#### Scenario: img element with empty src fails closed

- **WHEN** a page contains `<img id="empty" src="">`
- **AND** the user runs `safari-browser save-image out.jpg --element "#empty"`
- **THEN** the subcommand SHALL throw `elementHasNoSrc(selector: "#empty", tagName: "img")`
- **AND** SHALL NOT write any file

#### Scenario: div element is unsupported

- **WHEN** a page contains `<div id="card">Not an image</div>`
- **AND** the user runs `safari-browser save-image out.jpg --element "#card"`
- **THEN** the subcommand SHALL throw `unsupportedElement(selector: "#card", tagName: "div")`
- **AND** the errorDescription SHALL list the supported tags
- **AND** SHALL NOT write any file

#### Scenario: HTTP 404 fails closed

- **WHEN** an img's src resolves to a URL returning HTTP 404
- **AND** the user runs `safari-browser save-image out.jpg --element "img.broken"`
- **THEN** the subcommand SHALL throw `downloadFailed(url:, statusCode: 404, reason:)`
- **AND** SHALL NOT write any file

<!-- @trace
source: save-image-subcommand
updated: 2026-04-24
code:
  - .remember/logs/autonomous/save-071446.log
  - .remember/logs/autonomous/save-073920.log
  - .remember/logs/autonomous/save-071013.log
  - .remember/tmp/save-session.pid
  - .remember/logs/autonomous/save-073132.log
-->