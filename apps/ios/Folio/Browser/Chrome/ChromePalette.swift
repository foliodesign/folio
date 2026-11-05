import UIKit

/// Colours sampled from reference screenshots (docs/delivery/reference/, 2026-10-08)
/// so the bar reads as part of the editor UI below it. Dark mode is the primary target: the
/// bar and inactive tabs use the editor's panel grey; the selected tab sits one step lighter.
enum ChromePalette {
  static func hex(_ value: UInt32) -> UIColor {
    UIColor(
      red: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255,
      blue: CGFloat(value & 0xFF) / 255, alpha: 1)
  }
  private static func dynamic(dark: UInt32, light: UInt32) -> UIColor {
    UIColor { $0.userInterfaceStyle == .dark ? hex(dark) : hex(light) }
  }
  /// Panel grey of the editor's sidebars (bug-white-bottom-bar.png).
  static let bar = dynamic(dark: 0x2C2C2C, light: 0xFFFFFF)
  static let selectedTab = dynamic(dark: 0x383838, light: 0xF5F5F5)
  /// Inactive tab segments and Home when another tab is selected.
  static let inactiveTab = bar
  static let hover = dynamic(dark: 0x424242, light: 0xEBEBEB)
  /// Icon-rail edge and sidebar header rule in bar-alignment-2026-10-08.png.
  /// Both are #444444; the outer sidebar edge is slightly darker, #414141.
  static let divider = dynamic(dark: 0x444444, light: 0xE6E6E6)
  /// Close-button square on hover.
  static let closeFill = dynamic(dark: 0x424242, light: 0xE6E6E6)
  /// Translucent fill for the touch shortcut palette's toggled buttons.
  static let groupFill = UIColor { traits in
    traits.userInterfaceStyle == .dark
      ? UIColor(white: 1, alpha: 0.07) : UIColor(white: 0, alpha: 0.05)
  }
  static let primaryText = dynamic(dark: 0xFFFFFF, light: 0x000000)
  static let secondaryText = dynamic(dark: 0xCECECF, light: 0x5C5C5C)
  /// Inactive file icons and the Home, '+' and ⋯ glyphs.
  static let icon = dynamic(dark: 0xC1C1C2, light: 0x5C5C5C)
  /// The selected tab's file icon.
  static let activeIcon = figmaBlue
  /// iPhone tool pill's Design | Dev segment: the track, and the selected Dev segment's fill
  /// (the editor's Dev Mode green).
  static let segmentTrack = dynamic(dark: 0x383838, light: 0xF0F0F0)
  static let devGreen = hex(0x14AE5C)
  /// iPhone floating tool pill: hairline edge that lifts it off the canvas in either appearance.
  static let floatingEdge = UIColor { traits in
    traits.userInterfaceStyle == .dark
      ? UIColor(white: 1, alpha: 0.1) : UIColor(white: 0, alpha: 0.08)
  }
}

/// Chrome-owned visual mapping from a file URL to an icon key. Routing stays in the router.
/// Icons are original drawings in the editor's thin-stroke style; no copied artwork.
enum ChromeFileIcon {
  static let design = "folio.design"
  static let board = "folio.board"
  static let slides = "folio.slides"
  static let prototype = "folio.prototype"
  /// A design file in Dev Mode (Figma adds `m=dev` to the file URL).
  static let dev = "folio.dev"

  static func symbol(for url: URL?) -> String {
    guard let url else { return "doc" }
    switch TabNavigationRouter.classify(url) {
    case .file, .creation: break
    default: return "doc"
    }
    switch url.path.split(separator: "/").first {
    case "design", "file": return isDevMode(url) ? dev : design
    case "board": return board
    case "slides": return slides
    case "proto": return prototype
    case "site": return "globe"
    case "make": return "sparkles"
    default: return "doc"
    }
  }

  private static func isDevMode(_ url: URL) -> Bool {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
      .contains { $0.name == "m" && $0.value == "dev" } == true
  }

  static func image(_ key: String) -> UIImage? {
    drawn[key] ?? UIImage(systemName: key) ?? UIImage(systemName: "doc")
  }

  private static let drawn: [String: UIImage] = [
    design: draw { _ in
      // Pen nib pointing down-left: flat cap top-right, ink hole and slit to the tip.
      let nib = UIBezierPath()
      nib.move(to: CGPoint(x: 2.5, y: 13.5))
      nib.addLine(to: CGPoint(x: 4.2, y: 6.6))
      nib.addLine(to: CGPoint(x: 9.2, y: 4.6))
      nib.addLine(to: CGPoint(x: 11.4, y: 6.8))
      nib.addLine(to: CGPoint(x: 9.4, y: 11.8))
      nib.close()
      nib.move(to: CGPoint(x: 9.2, y: 4.6))
      nib.addLine(to: CGPoint(x: 10.9, y: 2.9))
      nib.addLine(to: CGPoint(x: 13.1, y: 5.1))
      nib.addLine(to: CGPoint(x: 11.4, y: 6.8))
      nib.move(to: CGPoint(x: 2.5, y: 13.5))
      nib.addLine(to: CGPoint(x: 6.1, y: 9.9))
      stroke(nib)
      stroke(UIBezierPath(ovalIn: CGRect(x: 6.1, y: 7.9, width: 2, height: 2)))
    },
    dev: draw { _ in
      // Code brackets with a slash: </>.
      let code = UIBezierPath()
      code.move(to: CGPoint(x: 5, y: 4.5))
      code.addLine(to: CGPoint(x: 1.8, y: 8))
      code.addLine(to: CGPoint(x: 5, y: 11.5))
      code.move(to: CGPoint(x: 11, y: 4.5))
      code.addLine(to: CGPoint(x: 14.2, y: 8))
      code.addLine(to: CGPoint(x: 11, y: 11.5))
      code.move(to: CGPoint(x: 9.2, y: 3.5))
      code.addLine(to: CGPoint(x: 6.8, y: 12.5))
      stroke(code)
    },
    board: draw { _ in
      // Sticky note with a folded corner.
      let note = UIBezierPath()
      note.move(to: CGPoint(x: 13.5, y: 9.5))
      note.addLine(to: CGPoint(x: 13.5, y: 4))
      note.addQuadCurve(to: CGPoint(x: 12, y: 2.5), controlPoint: CGPoint(x: 13.5, y: 2.5))
      note.addLine(to: CGPoint(x: 4, y: 2.5))
      note.addQuadCurve(to: CGPoint(x: 2.5, y: 4), controlPoint: CGPoint(x: 2.5, y: 2.5))
      note.addLine(to: CGPoint(x: 2.5, y: 12))
      note.addQuadCurve(to: CGPoint(x: 4, y: 13.5), controlPoint: CGPoint(x: 2.5, y: 13.5))
      note.addLine(to: CGPoint(x: 9.5, y: 13.5))
      note.close()
      note.move(to: CGPoint(x: 9.5, y: 13.5))
      note.addLine(to: CGPoint(x: 9.5, y: 9.5))
      note.addLine(to: CGPoint(x: 13.5, y: 9.5))
      stroke(note)
    },
    slides: draw { _ in
      // Presentation screen on a stand.
      stroke(
        UIBezierPath(roundedRect: CGRect(x: 2.5, y: 3, width: 11, height: 8), cornerRadius: 1.5))
      let stand = UIBezierPath()
      stand.move(to: CGPoint(x: 8, y: 11))
      stand.addLine(to: CGPoint(x: 8, y: 13.5))
      stand.move(to: CGPoint(x: 5.5, y: 13.5))
      stand.addLine(to: CGPoint(x: 10.5, y: 13.5))
      stroke(stand)
    },
    prototype: draw { _ in
      // Rounded play triangle.
      let play = UIBezierPath()
      play.move(to: CGPoint(x: 4.5, y: 3))
      play.addLine(to: CGPoint(x: 12.5, y: 8))
      play.addLine(to: CGPoint(x: 4.5, y: 13))
      play.close()
      stroke(play)
    },
  ]

  private static func stroke(_ path: UIBezierPath) {
    path.lineWidth = 1.2
    path.lineJoinStyle = .round
    path.lineCapStyle = .round
    path.stroke()
  }

  private static func draw(_ body: (CGContext) -> Void) -> UIImage {
    UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { context in
      UIColor.black.set()
      body(context.cgContext)
    }.withRenderingMode(.alwaysTemplate)
  }
}
