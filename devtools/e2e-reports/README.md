# Comma E2E Reports

SvelteKit dashboard for R2-backed Playwright E2E reports.

```sh
npm install
npm run check
npm run build
```

The app reuses the Salix admin bearer token flow. Set the backend URL and admin
key on `/`, then open `/e2e-reports`.

The vendored Playwright Trace Viewer is served from:

```text
/e2e-reports/trace-viewer/
```

The trace viewer files are served from the installed `playwright-core` package
in development and emitted into the production build by the Vite config.
