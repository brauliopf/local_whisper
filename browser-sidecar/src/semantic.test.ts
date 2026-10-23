import assert from "node:assert/strict";
import test from "node:test";
import { chromium } from "playwright";
import { collectSemanticPageData } from "./semantic.js";

test("captures useful visible semantics and excludes hidden controls", async () => {
  const browser = await chromium.launch({ headless: true });
  try {
    const page = await browser.newPage();
    await page.setContent(`
      <main>
        <h1>Costco storefront</h1>
        <label><input id="agree" type="checkbox"> Shop at Costco</label>
        <label><input id="delivery" type="radio" name="method" disabled> Delivery</label>
        <button>Next</button>
        <a href="https://example.test/store">Browse aisles</a>
        <label for="city">City</label><input id="city" type="text" placeholder="City">
        <select aria-label="Department"><option selected>Produce</option></select>
        <div role="tab" aria-selected="true">Products</div>
        <input id="hidden" type="text" style="display:none" value="should not appear">
      </main>
    `);

    const data = await page.evaluate(collectSemanticPageData);
    const roles = data.nodes.map((node) => node.role);
    assert.deepEqual(roles, ["heading", "checkbox", "radio", "button", "link", "textbox", "combobox", "tab"]);
    assert.equal(data.nodes.find((node) => node.role === "checkbox")?.name, "Shop at Costco");
    assert.equal(data.nodes.find((node) => node.role === "radio")?.disabled, true);
    assert.equal(data.nodes.find((node) => node.role === "link")?.name, "Browse aisles");
    assert.equal(data.nodes.find((node) => node.role === "tab")?.selected, true);
    assert.equal(data.nodes.some((node) => node.name === "should not appear"), false);
  } finally {
    await browser.close();
  }
});
