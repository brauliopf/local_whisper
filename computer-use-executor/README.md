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
{"jsonrpc":"2.0","id":1,"method":"session.start","params":{"initialURL":"https://www.google.com/travel/flights","allowedOrigins":["*"],"artifactDirectory":"/tmp/local-whisper-artifacts","profileDirectory":"~/Library/Application Support/local_whisper/computer-use-profile"}}
```

Execute a module:

```json
{"jsonrpc":"2.0","id":2,"method":"script.execute","params":{"module":"module.exports = async ({ page, context, screenshot }) => ({ type: 'table', columns: ['Title'], rows: [[await page.title()]], notes: [] });"}}
```

Stop the session:

```json
{"jsonrpc":"2.0","id":3,"method":"session.stop","params":{}}
```

Each task has one visible Chromium browser and one persistent browser context. Sequential scripts reuse the same page, and the profile preserves user-authenticated cookies across executor restarts. The default `allowedOrigins: ["*"]` policy permits valid HTTP(S) navigation to any origin; an explicit origin list can restrict navigation. New pages are rejected. Every successful script captures an automatic PNG screenshot under the configured artifact directory. Task artifacts are removed when the session stops, while the profile remains until `profile.clear` is explicitly requested.

Generated modules are validated by the backend before execution, but the executor's `vm` context is not an OS security sandbox. Generated code must not receive credentials, cookies, storage, or profile paths. The executor itself should only be launched as a local, trusted application process.
