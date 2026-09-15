# Computer-use executor (Milestone 0A)

Standalone headless Playwright executor. It does not call OpenAI and has no Swift dependency.

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
{"jsonrpc":"2.0","id":2,"method":"script.execute","params":{"module":"module.exports = async ({ page, context, screenshot }) => ({ type: 'table', columns: ['Title'], rows: [[await page.title()]], notes: [] });"}}
```

Stop the session:

```json
{"jsonrpc":"2.0","id":3,"method":"session.stop","params":{}}
```

Each task has one headless Chromium browser, one fresh context, and one page. Sequential scripts reuse the same page. Same-origin path changes are allowed; new pages and navigation to another origin are rejected.

Generated modules are treated as trusted local code in this milestone. The `vm` context is not an OS security sandbox.
