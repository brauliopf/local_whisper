import assert from "node:assert/strict";
import test from "node:test";
import {
  canExecuteGroceryAction,
  isCheckoutAction,
  preservesExistingCart,
  startGroceryTask,
  transitionGroceryTask,
  type GrocerySnapshot,
} from "./grocery.js";

const signedIn: GrocerySnapshot = { signedIn: true, candidates: [], cartItems: [{ id: "old", title: "Existing item" }] };

test("starts a signed-in task and adds a clear candidate", () => {
  let task = startGroceryTask("session-1", "organic apples", signedIn);
  task = transitionGroceryTask(task, {
    type: "snapshot",
    snapshot: { ...signedIn, candidates: [{ id: "apple-1", title: "Organic apples", available: true }] },
  });
  assert.equal(task.phase, "adding");
  assert.equal(task.selectedCandidateID, "apple-1");
  task = transitionGroceryTask(task, { type: "add_started" });
  task = transitionGroceryTask(task, { type: "verification_succeeded", itemID: "apple-1" });
  assert.equal(task.phase, "completed");
});

test("pauses for sign-in and resumes the same task", () => {
  let task = startGroceryTask("session-1", "milk", { ...signedIn, signedIn: false });
  assert.equal(task.phase, "awaiting_sign_in");
  task = transitionGroceryTask(task, { type: "snapshot", snapshot: signedIn });
  assert.equal(task.phase, "searching");
});

test("requires a choice for ambiguous candidates", () => {
  let task = startGroceryTask("session-1", "coffee", signedIn);
  task = transitionGroceryTask(task, {
    type: "snapshot",
    snapshot: { ...signedIn, candidates: [
      { id: "coffee-1", title: "Ground coffee", available: true },
      { id: "coffee-2", title: "Whole bean coffee", available: true },
    ] },
  });
  assert.equal(task.phase, "awaiting_candidate");
  task = transitionGroceryTask(task, { type: "choose_candidate", candidateID: "coffee-2" });
  assert.equal(task.phase, "adding");
});

test("handles no match and preserves existing cart items", () => {
  let task = startGroceryTask("session-1", "rare item", signedIn);
  task = transitionGroceryTask(task, { type: "snapshot", snapshot: signedIn });
  assert.equal(task.phase, "no_match");
  assert.equal(preservesExistingCart(task, signedIn), true);
});

test("rejects invalid terminal transitions and checkout actions", () => {
  let task = startGroceryTask("session-1", "tea", signedIn);
  task = transitionGroceryTask(task, { type: "cancel" });
  assert.throws(() => transitionGroceryTask(task, { type: "snapshot", snapshot: signedIn }), /terminal/);
  assert.equal(canExecuteGroceryAction("add_to_cart"), true);
  assert.equal(canExecuteGroceryAction("checkout"), false);
  assert.equal(isCheckoutAction("place_order"), true);
  assert.equal(isCheckoutAction("verify_cart"), false);
});

test("rejects empty requests", () => {
  assert.throws(() => startGroceryTask("session-1", "  ", signedIn), /empty grocery request/);
});
