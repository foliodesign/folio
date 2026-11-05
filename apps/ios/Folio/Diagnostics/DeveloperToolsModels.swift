import UIKit

/// Bundled pages that replace the current tab's page until "Return to Figma".
enum DeveloperLab: CaseIterable {
  case input, memory, auth, native, focus

  var title: String {
    switch self {
    case .input: "Input lab"
    case .memory: "Memory lab"
    case .auth: "Auth lab"
    case .native: "Native integration lab"
    case .focus: "Focus lab"
    }
  }
  var detail: String {
    switch self {
    case .input:
      "Local test page for touch, mouse, trackpad, Pencil and keyboard events. Results appear in the diagnostics report."
    case .memory:
      "Allocates canvas memory step by step and saves a checkpoint before each step, to find where WebKit ends the page."
    case .auth: "Local popup and opener test for sign-in flows. No Figma credentials involved."
    case .native:
      "Local page for drag and drop, file pickers, downloads and other native hand-offs."
    case .focus: "Local page for text field focus, scrolling and the on-screen keyboard."
    }
  }
}

/// Window-level display settings, owned by the browser window. Optional: absent when the
/// tools are opened without a window (Pencil action before the ⋯ menu was used).
struct DeveloperToolsDisplay {
  var zoom: () -> InterfaceZoomState?
  var setZoom: (InterfaceZoomAction) -> Void
  var keepTabsLoaded: () -> Int
  var setKeepTabsLoaded: (Int) -> Void
}

/// Window controls used by Settings; all mutations go through the chrome owners.
struct FolioSettingsDisplay {
  /// False in the compact layout, where the bottom toolbar is always shown.
  var canHideBottomToolbar: () -> Bool
  var bottomToolbarVisible: () -> Bool
  var setBottomToolbarVisible: (Bool) -> Void
}
