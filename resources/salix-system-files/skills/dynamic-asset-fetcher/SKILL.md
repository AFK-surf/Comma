---
name: dynamic-asset-fetcher
description: |
  Fetch and extract dynamically-loaded front-end assets (vector animations, SPA media,
  CDN-served JSON, images, fonts, and other resources) from web pages that hide real URLs behind
  JavaScript rendering, anti-scraping protections (Cloudflare, bot detection), lazy-loading, or
  Service Worker URL rewriting. Uses Playwright headless browser automation with stealth
  configuration to intercept network requests and capture real CDN addresses. Includes asset
  container validation (ZIP structure, JSON schema), archive unpacking, and structured
  delivery. Trigger on: "fetch animation from page", "extract asset URL from website",
  "download media container from site", "scrape CDN URL", "get web media asset", "intercept network
  requests", "bypass anti-scraping", "capture XHR/fetch URLs", "extract SPA media",
  "download dynamic resource", "resolve signed CDN URL", or any request to retrieve web assets
  from a page that requires browser rendering or blocks direct HTTP clients.
metadata:
  displayName: Dynamic Asset Fetcher
  icon: globe.network
  color: blue
  visibility: toggled
  placeholder: Paste a URL or describe the web asset to fetch
---

# Dynamic Asset Fetcher

Fetch and extract dynamically-loaded front-end assets from web pages that hide real CDN URLs
behind JavaScript rendering, anti-scraping protections, or lazy-loading. Supports vector
animations, SPA media, CDN-served JSON, images, fonts, and any resource discoverable through
browser network traffic interception.

## When to Use

Use this skill when:

- A web page embeds an asset (animation, media, JSON, image, font) but the real URL is not
  visible in static HTML -- it is constructed at runtime by JavaScript, loaded lazily, or served
  from a CDN that blocks direct HTTP clients.
- An asset is hosted behind Cloudflare, bot-detection, or similar anti-scraping protection that
  returns 403 / challenge pages to plain `curl` / `fetch` requests.
- You need the **real CDN URL** for an asset so it can be downloaded, validated, unpacked, and
  delivered as files.
- You need to validate the structure of an asset ZIP container or raw animation
  JSON against the schema.
- You need to capture XHR/fetch API endpoints that a SPA calls to load data dynamically.

Do **not** use this skill when:

- The asset URL is already known and accessible via plain HTTP download.
- You only need a screenshot or visual capture of the page (use a screenshot tool instead).
- The target is server-side rendered content available in static HTML.

## Prerequisites

- A connector-backed environment with shell execution and network access.
- Node.js (>= 18) with `npx` available for Playwright.
- Python 3 (>= 3.10) with `pip` for validation scripts, or Node.js with `adm-zip`.
- Disk space for a temporary browser profile and downloaded assets.

## Workflow Overview

```
1. Prepare Playwright browser environment (stealth configuration)
2. Navigate to target page and intercept network requests
3. Filter captured requests for target asset types
4. Resolve real CDN URLs from intercepted traffic
5. Download the asset from the resolved CDN URL (immediately -- signed URLs expire)
6. Validate asset format (ZIP container, JSON schema, or other format)
7. Unpack / extract asset contents if needed (e.g., container ZIP -> JSON + images)
8. Deliver files to the requester
```

## Step 1 -- Playwright Browser Environment Preparation

### Install Playwright

```bash
npx playwright install chromium
npx playwright --version
```

### Stealth Configuration

Many anti-scraping systems fingerprint the browser. Use these mitigations:

- Launch **Chromium** with `--headless=new` (not legacy `--headless=chrome`).
- Set a realistic desktop User-Agent string.
- Inject `navigator.webdriver = undefined` via `addInitScript`.
- Set realistic viewport, locale, timezone, and extra HTTP headers.
- Use a persistent context (or `storageState`) to carry cookies across navigations.
- Pair `--disable-blink-features=AutomationControlled` with script injection for best results.

### Generic Asset Fetcher Script (Node.js / Playwright)

This script intercepts all network traffic, filters for target asset types, and captures real
CDN URLs. It supports any asset type -- configure the `ASSET_PATTERNS` array for your target.

```javascript
// asset-fetcher.mjs -- Generic network-interception-based asset fetcher
import { chromium } from 'playwright';
import { writeFileSync, mkdirSync } from 'fs';
import { join } from 'path';

const TARGET_URL = process.argv[2];
const OUTPUT_DIR = process.argv[3] || './asset-output';
// Asset URL patterns to capture (customize per task)
const ASSET_PATTERNS = [
  '.json', 'animation', 'media', 'bundle',
  '.webp', '.png', '.jpg', '.jpeg', '.svg', '.gif',
  '.mp4', '.webm', '.woff', '.woff2', '.ttf',
  'cdn', 'assets', 'static',
];
// Content-Types to capture from responses
const CONTENT_TYPE_PATTERNS = [
  'json', 'zip', 'javascript',
  'image/', 'video/', 'font/', 'application/octet-stream',
];

mkdirSync(OUTPUT_DIR, { recursive: true });

const browser = await chromium.launch({
  headless: true,
  args: ['--no-sandbox', '--disable-blink-features=AutomationControlled', '--disable-dev-shm-usage'],
});

const context = await browser.newContext({
  userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
  viewport: { width: 1920, height: 1080 },
  locale: 'en-US',
  timezoneId: 'America/Los_Angeles',
  extraHTTPHeaders: { 'Accept-Language': 'en-US,en;q=0.9' },
});

// Anti-detection: remove webdriver flag
await context.addInitScript(() => {
  Object.defineProperty(navigator, 'webdriver', { get: () => undefined });
});

const page = await context.newPage();
const capturedUrls = [];

// -- Capture requests by URL pattern --
page.on('request', (request) => {
  const url = request.url();
  if (ASSET_PATTERNS.some(p => url.includes(p))) {
    capturedUrls.push({
      url, method: request.method(),
      resourceType: request.resourceType(),
      headers: request.headers(),
    });
  }
});

// -- Capture responses by content-type --
page.on('response', (response) => {
  const url = response.url();
  const contentType = response.headers()['content-type'] || '';
  if (CONTENT_TYPE_PATTERNS.some(p => contentType.includes(p))) {
    capturedUrls.push({
      url, status: response.status(),
      contentType,
      fromServiceWorker: response.fromServiceWorker(),
    });
  }
});

// -- Navigate and wait for dynamic content --
await page.goto(TARGET_URL, { waitUntil: 'networkidle' });
await page.waitForTimeout(3000);

// Scroll to trigger lazy-loaded content
await page.evaluate(async () => {
  await new Promise((resolve) => {
    let total = 0;
    const timer = setInterval(() => {
      window.scrollBy(0, 300);
      total += 300;
      if (total >= document.body.scrollHeight) { clearInterval(timer); resolve(); }
    }, 100);
  });
});
await page.waitForTimeout(2000);

// -- Scan DOM for known media and animation elements (video, audio, img, canvas, object) --
const domSrcs = await page.evaluate(() => {
  const srcs = [];
  const selectors = [
    'video source', 'video', 'audio source', 'audio',
    'img[src]', 'img[data-src]', 'source[src]',
    'picture source', 'link[rel="preload"]', 'link[rel="stylesheet"]',
    '[data-animation-url]', '[data-asset-url]',
  ];
  document.querySelectorAll(selectors.join(', ')).forEach((el) => {
    const src = el.getAttribute('src') || el.getAttribute('data-src') ||
      el.getAttribute('data-animation-url') || el.getAttribute('data-asset-url') ||
      el.getAttribute('href') || el.getAttribute('poster');
    if (src) srcs.push(src);
  });
  return srcs;
});

const uniqueUrls = [...new Set([...capturedUrls.map(c => c.url), ...domSrcs])];
writeFileSync(join(OUTPUT_DIR, 'captured-urls.json'),
  JSON.stringify({ captured: capturedUrls, domSrcs, unique: uniqueUrls }, null, 2));
console.log(JSON.stringify(uniqueUrls, null, 2));
await browser.close();
```

### Run the Fetcher

```bash
node asset-fetcher.mjs "https://example.com/page-with-assets" ./asset-output
```

## Step 2 -- Network Request Interception: Extracting CDN Real Addresses

### Key Patterns

1. **Request/Response listeners**: Attach `page.on('request')` and `page.on('response')` to
   capture all traffic. Filter by URL patterns and by `Content-Type` headers.

2. **CDN redirect chains**: Some CDNs issue 302 redirects. The `response` event captures the
   **final URL** after redirects via `response.url()`. Always capture both the initial request
   URL and the final response URL to trace the full redirect chain.

3. **Signed/expiring URLs**: CDN assets often use time-limited signed URLs (e.g.,
   `?Expires=...&Signature=...`). Download **immediately** after capturing -- do not store the
   URL for later use.

4. **Service Worker interception**: Some sites serve assets through a Service Worker, which
   may rewrite URLs. Check `response.fromServiceWorker()` and, if needed, intercept at the
   `context.route()` level to log the original request.

5. **Lazy-loading**: Assets may not load until scrolled into view. Programmatically scroll
   the page or trigger intersection observers before capturing.

6. **XHR/Fetch API discovery**: SPAs often load data via XHR/fetch. Intercept these calls to
   discover hidden API endpoints and their request shapes (headers, auth tokens, payloads).
   Once the API shape is known, you can replay it directly with `curl` or `requests`.

### Context-Level Route Interception (for Service Worker cases)

```javascript
await context.route('**/*.{json,webp,png,jpg,svg,mp4,woff2,zip}', async (route) => {
  console.log('Route intercepted:', route.request().url());
  await route.continue();
});
```

## Step 3 -- Download the Asset

Once the real CDN URL is captured, download it immediately (signed URLs expire):

```bash
# Download with browser-like headers to avoid 403
curl -L -o output.zip \
  -H 'User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)' \
  -H 'Referer: https://example.com/' \
  'https://cdn.example.com/assets/media-bundle.zip'
```

Or from within the Playwright script using the browser context's cookies:

```javascript
// Reuse the authenticated browser context for the download
const response = await context.request.get(cdnUrl, {
  headers: { Referer: TARGET_URL },
});
const buffer = await response.body();
writeFileSync(join(OUTPUT_DIR, 'asset-file'), buffer);
```

## Step 4 -- Asset Format Validation

### Asset Container Validation (ZIP Archive)

A media or animation container file is structured as a **ZIP archive** with this structure:

```
bundle.zip (ZIP)
|-- manifest.json          # Required: metadata and configuration
|-- assets/                # Required: asset data files (JSON / binary)
|   |-- anim_01.json
|   `-- anim_02.json
|-- images/                # Optional: image assets (webp, png, jpg, svg)
|   `-- img_01.webp
|-- themes/                # Optional: theme / styling files
|   `-- theme_01.json
`-- fonts/                 # Optional: font assets
    `-- BrandFont-Regular.ttf
```

**MIME type**: `application/zip`

### manifest.json Required Fields

- `version` (string)
- `assets` (array, minItems 1, each with required `id` string)

Optional: `generator`, `themes`, `stateMachines`, `initial`

### Vector Animation JSON Required Fields

| Field | Type | Description |
|-------|------|-------------|
| `v`   | string | Format version (e.g., `"5.7.0"`) |
| `fr`  | number | Framerate (frames per second) |
| `ip`  | number | In-point frame (usually 0) |
| `op`  | number | Out-point frame (duration in frames when `ip` is 0) |
| `w`   | integer | Width in pixels |
| `h`   | integer | Height in pixels |
| `layers` | array | Array of layer objects |

Optional: `nm` (name), `assets` (array), `markers` (array), `slots` (object), `meta` (object)

### Validation Script (Python)

```python
#!/usr/bin/env python3
"""Validate an asset archive against the container specification."""
import sys, json, zipfile
from pathlib import Path

def validate_asset_container(filepath):
    errors, warnings, info = [], [], {}
    path = Path(filepath)
    if not zipfile.is_zipfile(path):
        return {"valid": False, "errors": ["Not a valid ZIP archive"], "warnings": [], "info": {}}
    with zipfile.ZipFile(path, 'r') as zf:
        names = zf.namelist()
        info["entries"] = names
        if "manifest.json" not in names:
            errors.append("Missing required manifest.json at archive root")
        else:
            try:
                manifest = json.loads(zf.read("manifest.json"))
                info["manifest"] = manifest
                if "version" not in manifest:
                    errors.append("manifest.json missing required 'version' field")
                anims = manifest.get("assets", manifest.get("animations", []))
                if not isinstance(anims, list) or len(anims) == 0:
                    errors.append("manifest.json 'assets' must be a non-empty array")
                else:
                    for anim in anims:
                        if "id" not in anim:
                            errors.append(f"Asset entry missing required 'id': {anim}")
            except json.JSONDecodeError as e:
                errors.append(f"manifest.json is not valid JSON: {e}")
    return {"valid": len(errors) == 0, "errors": errors, "warnings": warnings, "info": info}

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python validate_asset.py <file.zip>"); sys.exit(1)
    result = validate_asset_container(sys.argv[1])
    print(json.dumps(result, indent=2))
    sys.exit(0 if result["valid"] else 1)
```

### Animation JSON Validation Snippet

```python
import json

def validate_animation_json(json_str):
    errors, warnings = [], []
    try:
        data = json.loads(json_str)
    except json.JSONDecodeError as e:
        return {"valid": False, "errors": [f"Invalid JSON: {e}"], "warnings": []}
    for field in ["v", "fr", "ip", "op", "w", "h", "layers"]:
        if field not in data:
            errors.append(f"Missing required field: '{field}'")
    if "layers" in data and not isinstance(data["layers"], list):
        errors.append("'layers' must be an array")
    elif "layers" in data and len(data["layers"]) == 0:
        warnings.append("'layers' array is empty")
    return {"valid": len(errors) == 0, "errors": errors, "warnings": warnings}
```

## Step 5 -- Unpacking and Delivery

### Unpack Container to a Directory

```bash
mkdir -p unpacked-asset
unzip bundle.zip -d unpacked-asset/
find unpacked-asset/ -type f | sort
```

### Python Unpack with Asset Extraction

```python
#!/usr/bin/env python3
"""Unpack an asset archive and list all extracted assets."""
import json, zipfile
from pathlib import Path

def unpack_asset_container(filepath, output_dir):
    out = Path(output_dir)
    out.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(filepath, 'r') as zf:
        zf.extractall(out)
        manifest = None
        if (out / "manifest.json").exists():
            manifest = json.loads((out / "manifest.json").read_text())
        assets = sorted((out / "assets").glob("*.json")) if (out / "assets").exists() else []
        images = []
        if (out / "images").exists():
            images = sorted(f for f in (out / "images").iterdir()
                if f.is_file() and f.suffix in ('.webp', '.png', '.jpg', '.jpeg', '.svg', '.gif'))
        return {
            "output_dir": str(out), "manifest": manifest,
            "assets": [str(f.relative_to(out)) for f in assets],
            "images": [str(f.relative_to(out)) for f in images],
            "total_files": len(list(out.rglob('*'))),
        }
```

### Delivery Checklist

1. **Original asset file** -- the intact downloaded file (e.g., `.zip`, `.json`, `.webp`).
2. **Unpacked directory** (for ZIP-based formats) containing extracted assets.
3. **Validation report** -- output of the validation script (pass/fail, warnings).
4. **Captured URL log** -- `captured-urls.json` from the Playwright interception step.

## Anti-Scraping Mitigation Reference

| Protection | Mitigation |
|-----------|-----------|
| Cloudflare JS challenge | Use Playwright with stealth flags; wait for challenge to auto-solve |
| User-Agent detection | Set a realistic desktop UA string |
| `navigator.webdriver` flag | Override via `addInitScript` |
| Rate limiting / IP blocking | Add delays between page actions; use a residential proxy if needed |
| Lazy-loading / IntersectionObserver | Programmatically scroll page to trigger loads |
| Service Worker URL rewriting | Use `context.route()` to intercept and log |
| Signed/expiring CDN URLs | Download immediately after capture |
| CORS restrictions on direct fetch | Use the Playwright browser context's `request.get()` which carries cookies |
| Bot detection via TLS fingerprint | Playwright uses real Chromium TLS stack, avoiding this |
| WAF / bot management (DataDome, PerimeterX) | Use realistic browser fingerprint; add human-like delays and mouse movements |

## Cleanup

```bash
rm -rf /tmp/playwright_*
# Keep downloaded and unpacked assets unless explicitly asked to remove them
```

## Error Handling

- **No asset URLs captured**: The page may not contain the target asset, or it may load from
  an unexpected pattern. Inspect all network traffic (broaden `ASSET_PATTERNS`), check the DOM
  for relevant elements, and try increasing wait time.
- **403 on CDN download**: The CDN may require specific `Referer` or `Origin` headers. Use
  the Playwright `context.request.get()` method which automatically includes the correct
  cookies and headers from the browser session.
- **Invalid ZIP archive**: The file may be raw JSON with a ZIP extension or vice versa.
  Try parsing it as JSON first; if it parses, treat it as a `.json` asset.
- **Empty assets array**: The `manifest.json` may reference asset files that don't
  exist in the archive. Report this as a validation error.
- **Service Worker blocks all traffic**: If `fromServiceWorker` is true for all responses,
  use `context.route()` with a broader glob pattern to intercept before the Service Worker.

## References

- Playwright Network API: https://playwright.dev/docs/network
- Playwright Route Interception: https://playwright.dev/docs/api/class-route
