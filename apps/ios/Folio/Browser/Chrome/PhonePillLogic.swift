/// The iPhone tool pill's tap rules, free of UIKit so they can be unit tested.
enum PhonePillLogic {
  /// A tool group's button: an inactive group selects the tool it shows; tapping the active one
  /// steps to the next tool of its cycle and wraps around, like a rotation.
  static func tap(face: PhoneTool, current: PhoneTool?, cycle: [PhoneTool]) -> PhoneTool {
    guard current == face, cycle.count > 1, let index = cycle.firstIndex(of: face) else {
      return face
    }
    return cycle[(index + 1) % cycle.count]
  }

  /// The Design | Dev segment: Shift+D only when the tap changes the mode. With an unknown mode
  /// every tap toggles, since Folio cannot tell which way it goes.
  static func sendsToggle(tapped: PhoneMode, current: PhoneMode) -> Bool {
    current == .unknown || tapped != current
  }

  /// Figma's top-level tool rows, verified on the iPhone 16 Pro on 2026-10-12.
  static let designTools: [PhoneVisibleTool] = [
    .move, .frame, .rectangle, .pen, .text, .comment, .actions,
  ]
  static let devTools: [PhoneVisibleTool] = [.move, .measurement, .annotation, .comment]

  /// The pill group a visible tool id belongs to: choosing Hand, Section or Line replaces the
  /// group's top-level button in Figma's row, it does not add one.
  static func group(of tool: PhoneVisibleTool) -> PhoneVisibleTool {
    switch tool {
    case .hand, .scale: .move
    case .section, .slice: .frame
    case .line, .arrow, .ellipse: .rectangle
    case .pencil: .pen
    default: tool
    }
  }

  /// The groups to show and whether they are Dev Mode's row. Figma's reported row wins when it
  /// agrees with the mode; otherwise (a mode tap not yet confirmed, an empty or stale row) the
  /// mode's verified row is shown, and the Design row when the mode is unknown.
  static func layout(reported: [PhoneVisibleTool], mode: PhoneMode) -> (
    tools: Set<PhoneVisibleTool>, dev: Bool
  ) {
    let ids = Set(reported.map(group(of:)))
    let devOnly: Set<PhoneVisibleTool> = [.measurement, .annotation]
    let listDev = !ids.isDisjoint(with: devOnly)
    let listDesign = !ids.isDisjoint(with: Set(designTools).subtracting(devTools))
    let dev = mode == .dev || (mode == .unknown && listDev && !listDesign)
    let row = Set(dev ? devTools : designTools)
    let shown = ids.intersection(row)
    let agrees = !shown.isEmpty && (dev ? !listDesign : !listDev)
    return (agrees ? shown : row, dev)
  }
}
