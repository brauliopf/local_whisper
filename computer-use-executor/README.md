# Computer-use executor

Standalone headed Playwright executor. It does not call OpenAI and has no Swift dependency.

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

Each task has one visible Chromium browser, one fresh context, and one page. Sequential scripts reuse the same page. The default `allowedOrigins: ["*"]` policy permits valid HTTP(S) navigation to any origin; an explicit origin list can be supplied to restrict navigation. New pages are rejected. Every successful script captures an automatic PNG screenshot under the configured artifact directory. The directory is retained while the session is alive and removed when the session stops.

Generated modules are validated by the backend before execution, but the executor's `vm` context is not an OS security sandbox. The executor itself should only be launched as a local, trusted application process.
