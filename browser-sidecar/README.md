# Browser sidecar

The sidecar is a local Node process packaged with the macOS app. It communicates over newline-delimited JSON on stdin/stdout; diagnostics use stderr.

Build locally:

```sh
npm ci
PLAYWRIGHT_BROWSERS_PATH=0 npm exec -- playwright install chromium
npm run build
```

The Xcode target runs `scripts/build_browser_sidecar.sh` and copies the built runtime into the app resources. The current phase-0 protocol supports `ping` and `stop`; browser session commands are added in later phases.
