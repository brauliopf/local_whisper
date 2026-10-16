# Browser sidecar

The sidecar is a local Node process packaged with the macOS app. It communicates over newline-delimited JSON on stdin/stdout; diagnostics use stderr.

Build locally:

```sh
npm ci
PLAYWRIGHT_BROWSERS_PATH=0 npm exec -- playwright install chromium
npm run build
```

The Xcode target runs `scripts/build_browser_sidecar.sh` and copies the built runtime into the app resources. The sidecar owns one primary headed browser tab and allows one additional user-controlled window to remain open. Only the primary tab is included in snapshots or generated plan execution; a third page is closed. It supports launch, snapshot, pause, resume, validated execution, and stop commands. Generated plans are parsed and checked against the single-page policy immediately before execution; execution is bound to the current redacted state hash and exact code hash. HTTP(S) navigation is permitted for private and local hosts in this first iteration, while non-HTTP(S) URLs and URLs with embedded credentials remain blocked.
