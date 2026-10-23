export type SemanticNodeData = {
  kind: string;
  role?: string;
  name?: string;
  label?: string;
  text?: string;
  href?: string;
  type?: string;
  autocomplete?: string;
  value?: string;
  checked?: boolean;
  selected?: boolean;
  disabled?: boolean;
  level?: number;
  visible: boolean;
};

/** Runs inside the page. Keep this function self-contained for Playwright serialization. */
export function collectSemanticPageData(): { url: string; title: string; nodes: SemanticNodeData[] } {
  const normalize = (value: string | null | undefined): string | undefined => {
    const text = value?.replace(/\s+/g, " ").trim();
    return text ? text : undefined;
  };
  const labelFor = (element: any): string | undefined => {
    const id = element.getAttribute("id");
    if (id) {
      const label = document.querySelector(`label[for="${CSS.escape(id)}"]`);
      if (label) return normalize(label.textContent);
    }
    const parentLabel = element.closest("label");
    return normalize(parentLabel?.textContent)
      ?? normalize(element.getAttribute("aria-label"))
      ?? normalize(element.getAttribute("placeholder"));
  };
  const implicitRole = (element: any): string | undefined => {
    const explicit = element.getAttribute("role");
    if (explicit) return explicit;
    const tag = element.tagName.toLowerCase();
    if (tag === "a" && element.hasAttribute("href")) return "link";
    if (tag === "button") return "button";
    if (tag === "select") return "combobox";
    if (tag === "textarea") return "textbox";
    if (tag === "input") {
      const type = (element.getAttribute("type") ?? "text").toLowerCase();
      return type === "checkbox" ? "checkbox"
        : type === "radio" ? "radio"
        : type === "submit" || type === "button" ? "button"
        : type === "search" ? "searchbox"
        : "textbox";
    }
    if (/^h[1-6]$/.test(tag)) return "heading";
    return undefined;
  };
  const accessibleName = (element: any): string | undefined => {
    const labelledBy = element.getAttribute("aria-labelledby");
    if (labelledBy) {
      const text = labelledBy.split(/\s+/).map((id: string) => document.getElementById(id)?.textContent ?? "").join(" ");
      return normalize(text);
    }
    return labelFor(element) ?? normalize(element.getAttribute("alt")) ?? normalize(element.textContent);
  };
  const isVisible = (element: any): boolean => {
    const style = getComputedStyle(element);
    const rect = element.getBoundingClientRect();
    return style.display !== "none" && style.visibility !== "hidden" && style.opacity !== "0"
      && rect.width > 0 && rect.height > 0;
  };
  const elements = Array.from(document.querySelectorAll(
    "a,button,input,textarea,select,[role],h1,h2,h3,h4,h5,h6,summary,li",
  ));
  const nodes: SemanticNodeData[] = [];
  for (const element of elements) {
    if (!isVisible(element)) continue;
    const role = implicitRole(element);
    const tag = element.tagName.toLowerCase();
    const type = element.getAttribute("type") ?? undefined;
    const node: SemanticNodeData = {
      kind: tag,
      role,
      name: accessibleName(element),
      label: labelFor(element),
      text: normalize(element.textContent),
      href: element instanceof HTMLAnchorElement ? element.href : undefined,
      type,
      autocomplete: element.getAttribute("autocomplete") ?? undefined,
      value: element instanceof HTMLInputElement || element instanceof HTMLTextAreaElement || element instanceof HTMLSelectElement ? element.value : undefined,
      checked: element instanceof HTMLInputElement && (type === "checkbox" || type === "radio")
        ? element.checked
        : element.getAttribute("aria-checked") === "true" ? true : element.getAttribute("aria-checked") === "false" ? false : undefined,
      selected: element instanceof HTMLSelectElement
        ? Boolean(element.selectedOptions.length)
        : element instanceof HTMLOptionElement ? element.selected
        : element.getAttribute("aria-selected") === "true" ? true : element.getAttribute("aria-selected") === "false" ? false : undefined,
      disabled: "disabled" in element ? Boolean(element.disabled) : undefined,
      level: /^h[1-6]$/.test(tag) ? Number(tag.slice(1)) : undefined,
      visible: true,
    };
    if (node.role || node.name || node.text || node.href) nodes.push(node);
  }
  return { url: location.href, title: document.title, nodes };
}
