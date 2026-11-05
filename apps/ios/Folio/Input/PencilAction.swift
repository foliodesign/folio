import UIKit

/// Stored raw values are independent of display names. Commands use the bottom toolbar transport.
enum PencilAction: String, Codable, CaseIterable {
  case none, systemSetting, undo, redo, cut, copy, paste, duplicate, selectAll, group, ungroup
  case frameSelection, delete, toggleDevMode, toggleUI
  case move, frame, rectangle, ellipse, line, pen, text, hand, comment
  case showBottomToolbar, nextTab, previousTab

  var title: String {
    switch self {
    case .none: "None"
    case .systemSetting: "System setting"
    case .undo: "Undo"
    case .redo: "Redo"
    case .cut: "Cut"
    case .copy: "Copy"
    case .paste: "Paste"
    case .duplicate: "Duplicate"
    case .selectAll: "Select all"
    case .group: "Group"
    case .ungroup: "Ungroup"
    case .frameSelection: "Frame selection"
    case .delete: "Delete"
    case .toggleDevMode: "Toggle Dev Mode"
    case .toggleUI: "Toggle Figma UI"
    case .move: "Move tool"
    case .frame: "Frame tool"
    case .rectangle: "Rectangle tool"
    case .ellipse: "Ellipse tool"
    case .line: "Line tool"
    case .pen: "Pen tool"
    case .text: "Text tool"
    case .hand: "Hand tool"
    case .comment: "Comment tool"
    case .showBottomToolbar: "Toggle bottom toolbar"
    case .nextTab: "Next tab"
    case .previousTab: "Previous tab"
    }
  }

  var symbol: String {
    switch self {
    case .none: "nosign"
    case .systemSetting: "gearshape"
    case .undo: "arrow.uturn.backward"
    case .redo: "arrow.uturn.forward"
    case .cut: "scissors"
    case .copy, .duplicate: "document.on.document"
    case .paste: "document.on.clipboard"
    case .selectAll: "checkmark.rectangle"
    case .group, .ungroup: "rectangle.3.group"
    case .frameSelection, .frame: "number"
    case .delete: "delete.left"
    case .toggleDevMode: "chevron.left.forwardslash.chevron.right"
    case .toggleUI: "sidebar.left"
    case .move: "cursorarrow"
    case .rectangle: "rectangle"
    case .ellipse: "circle"
    case .line: "line.diagonal"
    case .pen: "pencil.tip"
    case .text: "textformat"
    case .hand: "hand.draw"
    case .comment: "bubble"
    case .showBottomToolbar: "keyboard"
    case .nextTab: "arrow.right"
    case .previousTab: "arrow.left"
    }
  }

  var nativeEdit: ShortcutEditAction? {
    switch self {
    case .cut: .cut
    case .copy: .copy
    case .paste: .paste
    case .selectAll: .selectAll
    default: nil
    }
  }
}
