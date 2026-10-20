# Comma E2E Reports

SvelteKit dashboard for R2-backed Playwright E2E reports.

```sh
npm install
npm run check
npm run build
```

The app reuses the Salix admin bearer token flow. Set the backend URL and admin
key on `/`, then open `/e2e-reports`.

The Playwright Trace Viewer is served from `/e2e-reports/trace-viewer/`. It
comes from the installed `playwright-core` package.
