import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

const scripts = await Promise.all(
  ["bridge", "hide-google"].map((name) =>
    readFile(
      new URL(
        `../../../apps/ios/Folio/Resources/Compat/${name}.js`,
        import.meta.url,
      ),
      "utf8",
    ),
  ),
);
class El {
  constructor(tag, text = "", ...children) {
    this.tag = tag;
    this.ownText = text;
    this.rect = { width: 100, height: 30 };
    this.children = children;
    this.parentElement = null;
    this.attrs = {};
    this.style = {
      setProperty: (k, v) => {
        this.attrs.style = `${k}:${v}`;
      },
    };
    children.forEach((c) => (c.parentElement = this));
  }
  get textContent() {
    return this.ownText + this.children.map((c) => c.textContent).join("");
  }
  get childNodes() {
    return [{ nodeType: 3, textContent: this.ownText }, ...this.children];
  }
  matches(selector) {
    return selector.split(",").some((part) => {
      const attr = part.match(/^\[([^=\]]+)(?:=([^\]]+))?\]$/);
      return attr
        ? this.hasAttribute(attr[1]) &&
            (!attr[2] || this.attrs[attr[1]] === attr[2])
        : part === this.tag;
    });
  }
  hasAttribute(k) {
    return k in this.attrs;
  }
  getClientRects() {
    return [this.rect];
  }
  get siblings() {
    return this.parentElement?.children ?? [];
  }
  get nextElementSibling() {
    return this.siblings[this.siblings.indexOf(this) + 1] ?? null;
  }
  get previousElementSibling() {
    return this.siblings[this.siblings.indexOf(this) - 1] ?? null;
  }
  getAttribute(k) {
    return this.attrs[k] ?? null;
  }
  setAttribute(k, v) {
    this.attrs[k] = v;
  }
  removeAttribute(k) {
    delete this.attrs[k];
  }
  querySelector(selector) {
    for (const child of this.children) {
      if (child.matches(selector)) return child;
      const nested = child.querySelector(selector);
      if (nested) return nested;
    }
    return null;
  }
  get hiddenNow() {
    return this.attrs["data-folio-hidden"] === "google";
  }
}
function harness(pathname, build) {
  let callback;
  const tree = build();
  const buttons = tree.all;
  const document = {
    querySelectorAll: () => buttons,
  };
  const timers = [];
  const context = vm.createContext({
    document,
    HTMLElement: El,
    Element: El,
    getComputedStyle: (el) => ({
      display: el.attrs.style?.includes("display:none") ? "none" : "block",
      visibility: el.attrs.style?.includes("visibility:hidden")
        ? "hidden"
        : "visible",
    }),
    location: {
      protocol: "https:",
      port: "",
      hostname: "www.figma.com",
      pathname,
    },
    setTimeout: (fn) => timers.push(fn),
    MutationObserver: class {
      constructor(fn) {
        callback = fn;
      }
      observe() {}
      disconnect() {}
    },
  });
  scripts.forEach((s) => vm.runInContext(s, context));
  return {
    context,
    tree,
    run: () => {
      timers.splice(0).forEach((f) => f());
    },
    mutate: () => callback(),
  };
}
const login = () => {
  const google = new El("button", " Continue with Google ");
  const or = new El("div", "or");
  const email = new El("button", "Continue with email");
  const wrap = new El("div", "", google, or, email);
  return { google, or, email, wrap, all: [google, email] };
};

test("hides only the Google control and its orphaned divider, then restores", () => {
  const h = harness("/login", login);
  h.context.__folio.setHideGoogle(true);
  h.run();
  assert.equal(h.tree.google.hiddenNow, true);
  assert.equal(h.tree.or.hiddenNow, true);
  assert.equal(h.tree.email.hiddenNow, false);
  h.context.__folio.setHideGoogle(false);
  assert.equal(h.tree.google.hiddenNow, false);
  assert.equal(h.tree.or.hiddenNow, false);
});

test("hides the divider when only a heading remains above it", () => {
  const h = harness("/login", () => {
    const heading = new El("h2", "Log in to your account");
    const google = new El("button", "Continue with Google");
    const or = new El("p", "or");
    const email = new El("form", "", new El("input"));
    const wrap = new El("div", "", heading, google, or, email);
    return { heading, google, or, email, wrap, all: [google] };
  });
  h.context.__folio.setHideGoogle(true);
  h.run();
  assert.equal(h.tree.google.hiddenNow, true);
  assert.equal(h.tree.or.hiddenNow, true);
  assert.equal(h.tree.heading.hiddenNow, false);
  assert.equal(h.tree.email.hiddenNow, false);
});

test("keeps the divider when another option remains on both sides", () => {
  const h = harness("/signup", () => {
    const apple = new El("button", "Continue with Apple");
    const google = new El("button", "Continue with Google");
    const or = new El("div", "or");
    const email = new El("button", "Continue with email");
    const wrap = new El("div", "", apple, google, or, email);
    return { google, or, apple, wrap, all: [apple, google, email] };
  });
  h.context.__folio.setHideGoogle(true);
  h.run();
  assert.equal(h.tree.google.hiddenNow, true);
  assert.equal(h.tree.or.hiddenNow, false);
});

test("does nothing on editor pages, when disabled, or when nothing matches", () => {
  const editor = harness("/design/abc/file", login);
  editor.context.__folio.setHideGoogle(true);
  editor.mutate();
  editor.run();
  assert.equal(editor.tree.google.hiddenNow, false);
  const off = harness("/login", login);
  off.context.__folio.setHideGoogle(false);
  off.mutate();
  off.run();
  assert.equal(off.tree.google.hiddenNow, false);
  const none = harness("/login", () => {
    const b = new El("button", "Continue with email");
    return { all: [b], b };
  });
  none.context.__folio.setHideGoogle(true);
  none.run();
  assert.equal(none.tree.b.hiddenNow, false);
});

for (const depth of [1, 2, 3, 4]) {
  test(`hides divider beside a Google ancestor at depth ${depth}`, () => {
    const h = harness("/login", () => {
      const google = new El("button", "Continue with Google");
      let wrapper = google;
      for (let i = 0; i < depth; i++) wrapper = new El("div", "", wrapper);
      const or = new El("div", " OR ");
      const email = new El("form", "", new El("input"));
      const root = new El("div", "", wrapper, or, email);
      return { google, wrapper, or, email, root, all: [google] };
    });
    h.context.__folio.setHideGoogle(true);
    h.run();
    assert.equal(h.tree.or.hiddenNow, true);
    assert.equal(h.tree.email.hiddenNow, false);
    h.mutate();
    h.run();
    assert.equal(h.tree.or.hiddenNow, true);
    h.context.__folio.setHideGoogle(false);
    assert.equal(h.tree.or.hiddenNow, false);
    assert.equal(h.tree.google.hiddenNow, false);
    assert.equal(h.tree.wrapper.hiddenNow, false);
  });
}

for (const decorated of [false, true]) {
  test(`hides nested-span divider with decorative lines: ${decorated}`, () => {
    const h = harness("/login", () => {
      const google = new El("button", "Continue with Google");
      const label = new El("span", " oR ");
      const or = decorated
        ? new El("div", "", new El("span"), label, new El("span"))
        : new El("div", "", label);
      or.setAttribute("style", "color:red");
      const empty = new El("div", "  ");
      const hidden = new El("div", "Other option");
      hidden.setAttribute("style", "display:none");
      const zero = new El("div", "Other option");
      zero.rect = { width: 0, height: 0 };
      const email = new El("form", "", new El("input"));
      const root = new El("div", "", google, empty, hidden, zero, or, email);
      return { google, or, label, email, root, all: [google] };
    });
    h.context.__folio.setHideGoogle(true);
    h.run();
    assert.equal(h.tree.or.hiddenNow, true);
    assert.equal(h.tree.label.hiddenNow, false);
    assert.equal(h.tree.email.hiddenNow, false);
    h.context.__folio.setHideGoogle(false);
    assert.equal(h.tree.or.getAttribute("style"), "color:red");
  });
}

test("keeps ancestor divider between remaining SSO and email options", () => {
  const h = harness("/login", () => {
    const google = new El("button", "Continue with Google");
    const sso = new El("a", "Use single sign-on");
    const wrapper = new El("div", "", new El("div", "", google), sso);
    const or = new El("div", "", new El("span", "or"));
    const email = new El("form", "", new El("input"));
    const root = new El("div", "", wrapper, or, email);
    return { google, sso, wrapper, or, email, root, all: [google, sso] };
  });
  h.context.__folio.setHideGoogle(true);
  h.run();
  h.mutate();
  h.run();
  assert.equal(h.tree.or.hiddenNow, false);
  assert.equal(h.tree.sso.hiddenNow, false);
  assert.equal(h.tree.wrapper.hiddenNow, false);
});

for (const content of [
  new El("a", "or"),
  new El("input"),
  new El("span", "other text"),
]) {
  test(`never hides divider containing ${content.tag} / ${content.textContent}`, () => {
    const h = harness("/login", () => {
      const google = new El("button", "Continue with Google");
      const or = new El("div", content.tag === "a" ? "" : "or", content);
      const email = new El("input");
      const root = new El("div", "", google, or, email);
      return { google, or, root, all: [google] };
    });
    h.context.__folio.setHideGoogle(true);
    h.run();
    assert.equal(h.tree.or.hiddenNow, false);
  });
}

test("does not search beyond an ancestor containing a form or input", () => {
  const h = harness("/login", () => {
    const google = new El("button", "Continue with Google");
    const wrapper = new El("div", "", google, new El("input"));
    const or = new El("div", "or");
    const root = new El("div", "", wrapper, or);
    return { google, or, root, all: [google] };
  });
  h.context.__folio.setHideGoogle(true);
  h.run();
  assert.equal(h.tree.google.hiddenNow, true);
  assert.equal(h.tree.or.hiddenNow, false);
});

test("rechecks a newly inserted divider after Google is already hidden", () => {
  const h = harness("/login", login);
  h.context.__folio.setHideGoogle(true);
  h.run();
  const replacement = new El("div", "or");
  replacement.parentElement = h.tree.wrap;
  h.tree.wrap.children[1] = replacement;
  h.mutate();
  h.run();
  assert.equal(replacement.hiddenNow, true);
});

for (const role of ["checkbox", "link", "button"]) {
  test(`never hides an interactive or label with role ${role}`, () => {
    const h = harness("/login", () => {
      const google = new El("button", "Continue with Google");
      const or = new El("div", "or");
      or.setAttribute("role", role);
      const root = new El("div", "", google, or, new El("input"));
      return { google, or, root, all: [google] };
    });
    h.context.__folio.setHideGoogle(true);
    h.run();
    assert.equal(h.tree.or.hiddenNow, false);
  });
}
