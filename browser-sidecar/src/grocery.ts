export const GROCERY_POLICY_VERSION = "instacart-grocery-v1";

export type GroceryPhase =
  | "searching"
  | "awaiting_sign_in"
  | "awaiting_candidate"
  | "adding"
  | "verifying"
  | "completed"
  | "no_match"
  | "failed"
  | "cancelled";

export type GroceryCandidate = {
  id: string;
  title: string;
  brand?: string;
  size?: string;
  available: boolean;
};

export type GroceryCartItem = {
  id: string;
  title: string;
  quantity?: number;
};

export type GrocerySnapshot = {
  signedIn: boolean;
  candidates: GroceryCandidate[];
  cartItems: GroceryCartItem[];
};

export type GroceryTask = {
  sessionID: string;
  request: string;
  phase: GroceryPhase;
  selectedCandidateID?: string;
  initialCartItemIDs: string[];
  error?: string;
};

export type GroceryTransition =
  | { type: "snapshot"; snapshot: GrocerySnapshot }
  | { type: "choose_candidate"; candidateID: string }
  | { type: "add_started" }
  | { type: "verification_succeeded"; itemID: string }
  | { type: "no_match" }
  | { type: "fail"; error: string }
  | { type: "cancel" };

export function startGroceryTask(sessionID: string, request: string, snapshot: GrocerySnapshot): GroceryTask {
  const trimmed = request.trim();
  if (!trimmed) throw new Error("empty grocery request");
  return {
    sessionID,
    request: trimmed,
    phase: snapshot.signedIn ? "searching" : "awaiting_sign_in",
    initialCartItemIDs: snapshot.cartItems.map((item) => item.id),
  };
}

export function transitionGroceryTask(task: GroceryTask, transition: GroceryTransition): GroceryTask {
  if (["completed", "no_match", "failed", "cancelled"].includes(task.phase)) {
    throw new Error(`grocery task is terminal: ${task.phase}`);
  }

  switch (transition.type) {
    case "snapshot": {
      if (!transition.snapshot.signedIn) return { ...task, phase: "awaiting_sign_in" };
      if (task.phase === "awaiting_sign_in") return { ...task, phase: "searching" };
      if (task.phase === "searching") {
        const available = transition.snapshot.candidates.filter((candidate) => candidate.available);
        if (available.length === 0) return { ...task, phase: "no_match" };
        if (available.length > 1) return { ...task, phase: "awaiting_candidate" };
        return { ...task, phase: "adding", selectedCandidateID: available[0].id };
      }
      return task;
    }
    case "choose_candidate":
      if (task.phase !== "awaiting_candidate") throw new Error("candidate choice is not expected");
      return { ...task, phase: "adding", selectedCandidateID: transition.candidateID };
    case "add_started":
      if (task.phase !== "adding") throw new Error("cart addition is not expected");
      return { ...task, phase: "verifying" };
    case "verification_succeeded":
      if (task.phase !== "verifying" || task.selectedCandidateID !== transition.itemID) {
        throw new Error("cart verification does not match selected candidate");
      }
      return { ...task, phase: "completed" };
    case "no_match":
      return { ...task, phase: "no_match" };
    case "fail":
      return { ...task, phase: "failed", error: transition.error };
    case "cancel":
      return { ...task, phase: "cancelled" };
  }
}

export function preservesExistingCart(task: GroceryTask, snapshot: GrocerySnapshot): boolean {
  const current = new Set(snapshot.cartItems.map((item) => item.id));
  return task.initialCartItemIDs.every((itemID) => current.has(itemID));
}

export function canExecuteGroceryAction(action: string): boolean {
  return ["open_instacart", "search", "inspect_candidates", "choose_candidate", "add_to_cart", "verify_cart"].includes(action);
}

export function isCheckoutAction(action: string): boolean {
  return /checkout|payment|place[_ -]?order|submit[_ -]?order|purchase/i.test(action);
}
