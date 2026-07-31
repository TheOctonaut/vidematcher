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

- `URL patterns`: page allow-list for scanning
- `Scan links`: inspect link text and `href` filenames
- `Scan visible text`: inspect page text nodes for `.avi` names
- `Scan scoped titles`: inspect a specific DOM region for extensionless title matches
- `Title scope selector`: CSS selector used for scoped title matching
- `Producers` / `Performers`: partial-match label lists
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

### Page actions

On supported pages, the extension can:

- render status badges: `missing`, `avi_only`, `mp4_only`, `both`
- add producer/performer labels on scoped title matches
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

## Firefox Extension Behavior

- Runs on all pages, but only scans URLs matching configured patterns in extension options.
- Extracts candidate `.avi` names from:
  - links (`href` and link text)
  - visible page text
- Optional scoped title matching for extensionless names in specific DOM regions (for example `.torrentNameInfo`)
- Optional producer/performer emoji labels for scoped title matches:
  - Producer list match -> `🎬⭐`
  - Performer list match -> `💃❤️`
- Sends deduplicated names to helper in batches.
- Renders inline status badges.
- Supports manual rescan from popup.
- Uses debounced mutation scanning for dynamic pages.

Scoped title matching normalizes separators (`.`, `-`, `_`, and whitespace) for matching, so a title like:

- `PrivateSociety 26 07 28 Misty XXX XviD-iPT Team`

can match a local basename like:

- `PrivateSociety.26.07.28.Misty-XXX.XviD-iPT Team`

Producer/performer list matching is case-insensitive and ignores `.`, `-`, `_`, and whitespace.

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
   - Check helper log file from `options.json` (`LogPath`).

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

- Unit-level (helper behavior via runtime checks):
  - Config precedence: CLI > options file > defaults
  - Basename normalization and extension filtering
  - Batch size validation and structured error responses
- Integration-level:
  - Firefox -> native helper roundtrip for `query_status`
  - Debounced dynamic rescans via MutationObserver
  - Helper unavailable fallback UX
