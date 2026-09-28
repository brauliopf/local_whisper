# Computer-use executor

Standalone headed Playwright executor. It does not call OpenAI and has no Swift dependency. The backend is responsible for planning and guardrail evaluation; this process only executes an already-approved module.

## Setup

```sh
npm install
npx playwright install chromium
npm test
```

## Protocol

The executable reads JSON-RPC-style JSON Lines from stdin and writes responses to stdout.

Start a session:

```json
{"jsonrpc":"2.0","id":1,"method":"session.start","params":{"initialURL":"https://www.google.com/travel/flights","allowedOrigins":["https://www.google.com"],"artifactDirectory":"/tmp/local-whisper-artifacts"}}
```

Execute a module:

```json
{"jsonrpc":"2.0","id":2,"method":"script.execute","params":{"module":"module.exports = async ({ page, screenshot }) => ({ type: 'table', columns: ['Title'], rows: [[await page.title()]], notes: [] });"}}
```

Stop the session:

```json
{"jsonrpc":"2.0","id":3,"method":"session.stop","params":{}}
```

Each task has one visible Chromium browser, one fresh context, and one page. Sequential scripts reuse the same page. Same-origin path changes are allowed; new pages and navigation to another origin are rejected. Every execution returns a fresh temporary PNG screenshot. The Swift adapter consumes and deletes screenshot/artifact files after upload.

Generated modules receive only `{ page, screenshot }`. The executor does not expose a raw Playwright `Page`, `Browser`, or `BrowserContext`. Instead, `page` is an explicit allowlist wrapper exposing only bounded navigation, observation, locator lookup, locator interaction, and waiting methods. `screenshot` is a host-owned helper that returns opaque metadata; generated code cannot choose filesystem paths or screenshot options. Cookies, storage, request clients, event hooks, frames, workers, script evaluation, lifecycle controls, and host APIs are not exposed. The `vm` context remains defense-in-depth rather than an OS security sandbox; backend AST scanning and TypeSafe evaluation are mandatory before execution.
