import "./bridge";

const runtime = globalThis.__folio;
if (runtime && !runtime.setUAButtonColor) {
  let enabled = false;
  let style: HTMLStyleElement | undefined;
  // A first author layer loses to later Figma layers and unlayered author rules.
  // Zero specificity also loses within this layer. No Figma selectors are used.
  const install = () => {
    if (!enabled) return;
    const parent = document.head ?? document.documentElement;
    if (!parent) return;
    if (!style) {
      style = document.createElement("style");
      style.textContent =
        "@layer folio-ua-default { :where(button) { color: inherit; } }";
    }
    if (style.parentNode !== parent) parent.prepend(style);
    if (document.head) observer.disconnect();
  };
  const observer = new MutationObserver(install);
  runtime.setUAButtonColor = (value) => {
    enabled = value;
    observer.disconnect();
    if (enabled) {
      observer.observe(document, { childList: true, subtree: true });
      install();
    } else {
      style?.remove();
      style = undefined;
    }
  };
  runtime.disposeUAButtonColor = () => {
    runtime.setUAButtonColor?.(false);
    delete runtime.setUAButtonColor;
    delete runtime.disposeUAButtonColor;
  };
}
