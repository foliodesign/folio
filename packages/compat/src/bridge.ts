// These globals exist only in Folio's isolated WKContentWorld, never the page world.
export type MessageName =
  | "folioDiagnostics"
  | "folioInputLog"
  | "folioKeyboardRouting"
  | "folioUIDrag"
  | "folioFocusLog"
  | "folioFocusAssist"
  | "folioLabResults"
  | "folioPhoneState"
  | "folioPhoneField";
export interface FolioRuntime {
  version: string;
  setTouchShortcutModifiers?: (mask: number) => void;
  touchShortcutKey?: (key: string, down?: boolean) => void;
  minimizePhoneUI?: () => void;
  resetTouchShortcuts?: () => void;
  touchShortcutFlags?: () => Pick<
    PointerEventInit,
    "shiftKey" | "altKey" | "metaKey" | "ctrlKey"
  >;
  consumeTouchShortcutModifiers?: () => void;
  ownsCanvasTouch?: (event: PointerEvent) => boolean;
  disposeTouchShortcuts?: () => void;
  post: (name: MessageName, payload: unknown) => void;
  captureKeyboardFocus?: () => void;
  capture?: () => Promise<void>;
  setInputLogging?: (enabled: boolean) => void;
  disposeDiagnostics?: () => void;
  disposeInputLog?: () => void;
  setFocusLogging?: (enabled: boolean) => void;
  setFocusEnvironment?: (viewport: boolean, assistant: boolean) => void;
  disposeFocusEnvironment?: () => void;
  setFocusRevealGuard?: (enabled: boolean) => void;
  setFocusRevealLogging?: (enabled: boolean) => void;
  focusRevealGuardStats?: () => { restored: number; ignored: number };
  disposeFocusRevealGuard?: () => void;
  setPencilStrategy?: (strategy: string, unusable: boolean) => void;
  disposePencil?: () => void;
  disposeLab?: () => void;
  disposeMemoryLab?: () => void;
  setLabStrategy?: (label: string) => void;
  trackpadPinch?: (
    phase: "began" | "changed" | "ended",
    scale: number,
    x: number,
    y: number,
  ) => void;
  resetTrackpadPinch?: () => void;
  setTrackpadZoom?: (enabled: boolean) => void;
  setTrackpadPinchRoute?: (route: "wheel" | "gesture") => void;
  trackpadPinchGain?: () => number;
  trackpadPinchStats?: () => {
    route: "wheel" | "gesture";
    dispatched: number;
    prevented: number;
    gestureSupported: boolean;
  };
  setTouchGestures?: (enabled: boolean, home: boolean) => void;
  disposeTouchGestures?: () => void;
  resetTouchGestures?: () => void;
  touchUIHold?: (
    phase: "began" | "moved" | "ended",
    x: number,
    y: number,
  ) => string;
  secondaryClick?: (x: number, y: number) => string;
  setUIDragOptions?: (logging: boolean) => void;
  isCanvasPoint?: (x: number, y: number) => boolean;
  canvasGestureDidMove?: () => boolean;
  cancelCanvasContact?: () => void;
  setResizeEdges?: (enabled: boolean) => void;
  disposeResizeEdges?: () => void;
  setTouchMode?: (mode: "pencil-and-touch" | "touch-only") => void;
  setCanvasWheel?: (enabled: boolean) => void;
  disposeCanvasWheel?: () => void;
  setUAButtonColor?: (enabled: boolean) => void;
  disposeUAButtonColor?: () => void;
  setHideGoogle?: (enabled: boolean) => void;
  disposeHideGoogle?: () => void;
  setPhoneLayout?: (
    enabled: boolean,
    minimized?: boolean,
    wide?: boolean,
    numberKeyboard?: boolean,
    sides?: boolean,
  ) => void;
  phonePanel?: (
    side?: string,
    fraction?: number,
  ) => { state: string; missing: boolean; tool: string; mode: string };
  phoneSheetDrag?: (phase: unknown, fraction: unknown) => boolean;
  phoneFieldKey?: (key: unknown) => boolean;
  phoneKeyboard?: (overlap: unknown, floor: unknown) => void;
  disposePhoneLayout?: () => void;
  dispose: () => void;
}
declare global {
  var __folioMemorySmoke: (() => Promise<void>) | undefined;
  var __folio: FolioRuntime | undefined;
  var webkit:
    | {
        messageHandlers?: {
          folioDOMEditorFocused?: { postMessage: (value: boolean) => void };
          folioVisibleTextEditing?: { postMessage: (value: boolean) => void };
          folioResize?: { postMessage: (value: string) => void };
          touchShortcutState?: { postMessage: (value: number) => void };
          folio?: { postMessage: (value: unknown) => void };
          memoryProgress?: {
            postMessage: (value: unknown) => Promise<boolean>;
          };
        };
      }
    | undefined;
}
if (!globalThis.__folio) {
  globalThis.__folio = {
    version: "0.1.0",
    post(name, payload) {
      if (
        name !== "folioDiagnostics" &&
        name !== "folioInputLog" &&
        name !== "folioKeyboardRouting" &&
        name !== "folioUIDrag" &&
        name !== "folioFocusLog" &&
        name !== "folioFocusAssist" &&
        name !== "folioLabResults" &&
        name !== "folioPhoneState" &&
        name !== "folioPhoneField"
      )
        return;
      try {
        globalThis.webkit?.messageHandlers?.folio?.postMessage({
          name,
          payload,
        });
      } catch {
        /* Detached frame. */
      }
    },
    dispose() {
      globalThis.__folio?.disposeDiagnostics?.();
      globalThis.__folio?.disposeInputLog?.();
      globalThis.__folio?.disposeFocusEnvironment?.();
      globalThis.__folio?.disposeFocusRevealGuard?.();
      globalThis.__folio?.disposeTouchShortcuts?.();
      globalThis.__folio?.disposeResizeEdges?.();
      globalThis.__folio?.disposeTouchGestures?.();
      globalThis.__folio?.disposePencil?.();
      globalThis.__folio?.disposeCanvasWheel?.();
      globalThis.__folio?.disposeUAButtonColor?.();
      globalThis.__folio?.disposeHideGoogle?.();
      globalThis.__folio?.disposePhoneLayout?.();
      globalThis.__folio?.disposeLab?.();
      globalThis.__folio?.disposeMemoryLab?.();
      delete globalThis.__folioMemorySmoke;
      delete globalThis.__folio;
    },
  };
}
