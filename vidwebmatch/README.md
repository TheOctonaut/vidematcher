# vidwebmatch

Firefox WebExtension + Windows Native Messaging helper that annotates `.avi` filenames on matching web pages with local filesystem status.

Statuses are based on basename identity (extension ignored), aligned with `vidmatch` and `videncode` semantics:

- `missing`
- `avi_only`
- `mp4_only`
- `both`

## Components

- `extension/`: Firefox extension (content script, background script, popup, options UI)
- `native-host/`: .NET native messaging helper
- `install-helper.ps1`: installs native host manifest + helper options and registers host in Firefox
- `uninstall-helper.ps1`: removes native host registration and optional local artifacts
- `vidwebmatch.ps1`: local CLI status checker for quick diagnostics
- `options.json.example`: template helper configuration
- `options.json`: local runtime config (gitignored)

## Configuration Priority

Helper and PowerShell tooling resolve settings in this order:

1. CLI arguments
2. Options file (`options.json` by default, or `-OptionsFile` / `--options-file`)
3. Script/app defaults (non-required settings only)

Required:

- `SearchRoot`: local root folder to index

## Native Helper Config Schema

`options.json` fields:

```json
{
  "SearchRoot": "C:/path/to/video-library",
  "MatchExtensions": [".avi", ".mp4"],
  "CaseInsensitive": true,
  "MaxBatchSize": 200,
  "CacheTtlSeconds": 30,
  "LogPath": "C:/path/to/vidwebmatch/logs/native-host.log"
}
```

Notes:

- `MatchExtensions` should include `.avi` and `.mp4`.
- `MaxBatchSize` is enforced by helper request validation.
- `CacheTtlSeconds` controls index reuse before refresh.

## Native Messaging Protocol (v1.0)

Transport: Firefox Native Messaging framing (4-byte little-endian message length + UTF-8 JSON payload).

Request message:

```json
{
  "type": "query_status",
  "request_id": "req-123",
  "filenames": ["example.avi", "Another.AVI"],
  "force_refresh": false
}
```

Supported request types:

- `query_status`: batch status query for filename list
- `refresh_index`: force index rebuild
- `ping`: health probe

`query_status` response:

```json
{
  "type": "query_status_result",
  "protocol_version": "1.0",
  "request_id": "req-123",
  "ok": true,
  "helper_status": "ok",
  "search_root": "C:\\path\\to\\video-library",
  "results": [
    {
      "input": "example.avi",
      "basename": "example",
      "status": "mp4_only",
      "has_avi": false,
      "has_mp4": true
    }
  ],
  "counts": {
    "requested": 2,
    "returned": 2
  }
}
```

Error response shape:

```json
{
  "type": "error",
  "protocol_version": "1.0",
  "request_id": "req-123",
  "ok": false,
  "error_code": "batch_too_large",
  "message": "Requested batch exceeds MaxBatchSize."
}
```

## Build and Install

1. Build helper:

```powershell
cd .\vidwebmatch\native-host
dotnet build -c Release
```

2. Configure `vidwebmatch/options.json` (`SearchRoot` is required).

3. Register helper for Firefox:

```powershell
cd .\vidwebmatch
.\install-helper.ps1 -SearchRoot "C:/path/to/video-library"
```

4. Load extension in Firefox:
   - Open `about:debugging#/runtime/this-firefox`
   - Click **Load Temporary Add-on**
   - Select `vidwebmatch/extension/manifest.json`

### Package for Firefox Developer Hub

The extension is plain JavaScript; no compilation or bundling is required.
From the repository root, validate and package it with Mozilla's `web-ext`:

```powershell
npm exec --yes --package=web-ext@10.7.0 -- web-ext lint --source-dir .\vidwebmatch\extension
npm exec --yes --package=web-ext@10.7.0 -- web-ext build --source-dir .\vidwebmatch\extension --artifacts-dir .\vidwebmatch\web-ext-artifacts
```

Increment `extension/manifest.json`'s version before each new submission. Keep the
existing Gecko add-on ID to preserve the installed add-on's identity and settings.
Upload the generated ZIP as a new version of the existing add-on in Firefox
Developer Hub. The ZIP contains only extension files, with `manifest.json` at its
root. The native helper is built and installed separately; it is not included.
After signing, install the signed extension returned by Mozilla.

## Quick Start

After the helper is built and installed:

1. Load the temporary Firefox add-on from `vidwebmatch/extension/manifest.json`.
2. Open the extension **Options** page.
3. Add one or more URL patterns for the sites you want scanned.
4. If needed, adjust the title selector (`.torrentNameInfo` by default) for title-based matching on index pages.
5. Visit a matching page and wait for badges to appear next to detected titles and `.avi` names.

The native helper only checks within the configured `SearchRoot`. It does not search outside that root.

## Using the Extension

### Options page

Use the options page to control what is scanned and how matches are presented:

- `Drive control base URL` / `Drive control key`: optional local settings for the popup's mount/unmount buttons.
- `URL patterns`: page allow-list for scanning
- `Scan links`: inspect link text and `href` filenames
- `Scan visible text`: inspect page text nodes for `.avi` names
- `Scan scoped titles`: inspect a specific DOM region for extensionless title matches
- `Title scope selector`: CSS selector used for scoped title matching
- `Studios` / `Actors`: partial-match label lists
- `Dim strings`: substring matches to fade within titles
- `Dim rows`: title patterns that dim or hide full table rows
- `Remove dim rows`: hide matched rows instead of dimming them
- `Dim date pattern`: fade `NN NN NN` date-like tokens in titles
- `Dismissed titles`: exact-title dismiss list managed from the page and reviewable in options

### Popup

The popup is for quick runtime checks:

- shows helper availability
- shows the active host name
- lets you manually rescan the current page

#### Mounting and unmounting a drive

Configure a base URL such as `https://example.com/jellymw/` and its key in
Options, then click **Save**. The popup's **Mount drive** and **Unmount drive**
buttons send background HTTP GET requests to `start?key=...` and `stop?key=...`.
No tab opens. Unmounting requires confirmation because it may interrupt other
applications using the drive. Requests are only allowed from the extension popup,
never from scanned web pages.

The popup displays the JSON response (up to 1,200 characters), HTTP errors,
invalid JSON, connectivity failures or a 30-second timeout. Explicit `ok: false`,
`success: false` or nonempty `error` fields are shown as failures. Other JSON is
displayed as the service response, not a guarantee that mounting has finished.
Helper status is checked again afterward; if mounting is still underway, reopen
the popup once ready and use **Rescan this page**. No automatic mounting, retries,
keepalive requests or unmounting occurs; idle disconnect remains the service's responsibility.

Use HTTPS. The key is stored in `browser.storage.local` separately from scan
settings, is not synced or returned to content scripts, and is not encrypted at rest.
It is sent only to the configured endpoint; redirects and cookies are disabled.
Neither the endpoint nor key is included in packaged defaults. Leave both fields
blank and save to disable this feature.

### Page actions

On supported pages, the extension can:

- render status badges: `missing`, `avi_only`, `mp4_only`, `both`
- add studio/actor labels on scoped title matches
- dim or hide full `<tr>` rows based on configured row-match patterns
- add inline dismiss buttons beside index-page titles
- show a floating dismiss button on single-title pages with `h2.tdm-section-header__title`

Dismissed titles are stored exactly (normalized whitespace, case-insensitive exact match) and then reused for future dim/hide decisions.

## Using the Native Helper

Useful commands:

```powershell
# Reinstall registration and refresh copied helper/config artifacts
.\install-helper.ps1 -SearchRoot "C:/path/to/video-library"

# Remove Firefox native-host registration
.\uninstall-helper.ps1

# Quick diagnostics
.\vidwebmatch.ps1
```

Operational notes:

- `install-helper.ps1` builds the Firefox native-host manifest and copies the runtime helper config beside the helper executable.
- `options.json` is the local runtime config; `options.json.example` stays generic and committed.
- The helper keeps an in-memory index for fast repeated lookups and refreshes it according to `CacheTtlSeconds` or a forced refresh request.
- Logs are written to the configured `LogPath`.
- Firefox launches the registered native helper on demand. There is no separate
  manual start command or Windows startup service.
- An inaccessible search root is reported as `drive_unavailable` without preventing
  the helper from starting. Reconnect the drive and rescan to retry.

## Firefox Extension Behavior

- Runs on all pages, but only scans URLs matching configured patterns in extension options.
- Extracts candidate `.avi` names from:
  - links (`href` and link text)
  - visible page text
- Optional scoped title matching for extensionless names in specific DOM regions (for example `.torrentNameInfo`)
- Optional studio/actor emoji labels for scoped title matches:
  - Studio list match -> `🎬⭐`
  - Actor list match -> `💃❤️`
- Sends deduplicated names to helper in batches.
- Renders inline status badges.
- Supports manual rescan from popup.
- Uses debounced mutation scanning for dynamic pages.

Scoped title matching normalizes separators (`.`, `-`, `_`, and whitespace) for matching, so a title like:

- `Example Studio 26 07 28 Example Actor Release`

can match a local basename like:

- `Example.Studio.26.07.28.Example.Actor-Release`

Studio/actor list matching is case-insensitive and ignores `.`, `-`, `_`, and whitespace.

If helper is unavailable, page remains usable and shows a clear helper-unavailable banner.

## Permissions

Extension permissions:

- `nativeMessaging`: connect to local helper
- `storage`: persist URL patterns and scan settings
- `tabs` + `activeTab`: manual rescan of active tab
- host permission `<all_urls>`: content script injection (URL filtering is done by configured patterns)

## Troubleshooting

1. **No badges shown**
   - Confirm URL matches configured patterns in extension options.
   - For `/t` plus `/t/<id>` pages, use: `https://www.something.com/t*`
   - Open popup and run **Rescan this page**.

2. **Helper unavailable**
   - Verify helper registration with `install-helper.ps1`.
   - Confirm helper executable path exists.
   - Ensure the registration's allowed extension ID matches `extension/manifest.json`.
   - Firefox starts the helper automatically; `install-helper.ps1` repairs registration, not a running service.
   - Check helper log file from `options.json` (`LogPath`).
   - If the popup reports **Helper connected, but search root is not accessible**,
     mount/reconnect the drive or check folder permissions, then rescan. This is
     distinct from Firefox being unable to start/connect to the helper.

3. **Wrong status**
   - Confirm `SearchRoot` points to the correct library folder.
   - Confirm `MatchExtensions` includes `.avi` and `.mp4`.
   - Run `refresh_index` by using popup rescan (forces refresh on next query).

4. **Large page lag**
   - Reduce visible-text scanning scope in extension options.
   - Lower mutation scan frequency by increasing debounce ms.
   - Keep `MaxBatchSize` reasonable (for example 100-300).

## Manual Verification Checklist

1. Build helper and run `install-helper.ps1` with a valid `SearchRoot`.
2. Load extension temporarily in Firefox and configure URL patterns for a test page.
3. Open a page containing known `.avi` names and verify badges appear within about 1-2 seconds.
4. Validate each status:
   - `missing`: basename absent from local root
   - `avi_only`: only `.avi` exists
   - `mp4_only`: only `.mp4` exists
   - `both`: both `.avi` and `.mp4` exist
5. Test manual rescan after editing page content dynamically.
6. Test with 500+ filenames on one page and verify browser remains responsive.
7. Stop/uninstall helper and confirm page remains usable with helper-unavailable notice.
8. Run `uninstall-helper.ps1` and confirm registry/manifest are removed.

## Minimal Test Plan

Drive-control regression checks (no requests to the configured live service):

```powershell
node --test .\vidwebmatch\tests\drive-control.test.cjs
```

- Unit-level (helper behavior via runtime checks):
  - Config precedence: CLI > options file > defaults
  - Basename normalization and extension filtering
  - Batch size validation and structured error responses
- Integration-level:
  - Firefox -> native helper roundtrip for `query_status`
  - Debounced dynamic rescans via MutationObserver
  - Helper unavailable fallback UX
