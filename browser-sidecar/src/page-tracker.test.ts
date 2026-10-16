import assert from "node:assert/strict";
import test from "node:test";
import { BrowserPageTracker } from "./page-tracker.js";

class FakePage {
  private closeHandler: (() => void) | undefined;
  closeCount = 0;

  once(event: "close", listener: () => void): void {
    assert.equal(event, "close");
    this.closeHandler = listener;
  }

  async close(): Promise<void> {
    this.closeCount += 1;
  }

  emitClose(): void {
    this.closeHandler?.();
  }
}

test("accepts exactly one auxiliary page and closes a third page", () => {
  const primary = new FakePage();
  const auxiliary = new FakePage();
  const third = new FakePage();
  const tracker = new BrowserPageTracker<FakePage>(() => undefined);

  tracker.observe(primary);
  tracker.claimPrimary(primary);
  assert.equal(tracker.observe(auxiliary), "auxiliary");
  assert.equal(tracker.observe(third), "rejected");
  assert.equal(tracker.auxiliary, auxiliary);
  assert.equal(third.closeCount, 1);
});

test("auxiliary closure clears only auxiliary ownership", () => {
  const primary = new FakePage();
  const auxiliary = new FakePage();
  let primaryClosed = 0;
  const tracker = new BrowserPageTracker<FakePage>(() => { primaryClosed += 1; });

  tracker.observe(primary);
  tracker.claimPrimary(primary);
  tracker.observe(auxiliary);
  auxiliary.emitClose();

  assert.equal(tracker.primary, primary);
  assert.equal(tracker.auxiliary, undefined);
  assert.equal(primaryClosed, 0);
});

test("primary closure clears page ownership and invokes teardown once", () => {
  const primary = new FakePage();
  const auxiliary = new FakePage();
  let teardownCount = 0;
  const tracker = new BrowserPageTracker<FakePage>(() => { teardownCount += 1; });

  tracker.observe(primary);
  tracker.claimPrimary(primary);
  tracker.observe(auxiliary);
  primary.emitClose();
  primary.emitClose();

  assert.equal(tracker.primary, undefined);
  assert.equal(tracker.auxiliary, undefined);
  assert.equal(teardownCount, 1);
});
