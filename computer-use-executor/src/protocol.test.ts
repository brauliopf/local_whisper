import assert from "node:assert/strict";
import test from "node:test";
import { isAllowedOrigin, parseConfiguration } from "./protocol.js";

test("accepts exact HTTP(S) origins and rejects origin-like values", () => {
  const configuration = parseConfiguration({
    initialURL: "https://example.com/start",
    allowedOrigins: ["https://example.com"],
    artifactDirectory: "/tmp/local-whisper-artifacts",
  });
  assert.equal(configuration.initialURL, "https://example.com/start");
  assert.equal(isAllowedOrigin(configuration.initialURL, configuration.allowedOrigins), true);

  assert.throws(
    () => parseConfiguration({
      initialURL: "https://example.com/start",
      allowedOrigins: ["https://example.com/"],
      artifactDirectory: "/tmp/local-whisper-artifacts",
    }),
    /exact HTTP\(S\) origins/,
  );
  assert.throws(
    () => parseConfiguration({
      initialURL: "file:///tmp/page.html",
      allowedOrigins: ["file://"],
      artifactDirectory: "/tmp/local-whisper-artifacts",
    }),
    /Invalid initialURL/,
  );
  assert.throws(
    () => parseConfiguration({
      initialURL: "https://user:password@example.com/start",
      allowedOrigins: ["https://example.com"],
      artifactDirectory: "/tmp/local-whisper-artifacts",
    }),
    /Invalid initialURL/,
  );
});
