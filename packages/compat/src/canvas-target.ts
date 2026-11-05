// Use the top hit only: a menu or panel covering the canvas is UI.
export function canvasAtPoint(
  x: number,
  y: number,
  target?: EventTarget | null,
): HTMLCanvasElement | undefined {
  const hit = document.elementFromPoint(x, y);
  if (target && target !== hit) return undefined;
  if (hit instanceof HTMLCanvasElement) return hit;
  if (!(hit instanceof Element)) return undefined;
  // A canvas container may receive the hit when the canvas itself ignores pointer events.
  // Do not treat arbitrary ancestors containing sidebars or overlays as canvas.
  for (const child of Array.from(hit.children ?? [])) {
    if (!(child instanceof HTMLCanvasElement)) continue;
    const rect = child.getBoundingClientRect();
    if (x >= rect.left && x < rect.right && y >= rect.top && y < rect.bottom)
      return child;
  }
  return undefined;
}
