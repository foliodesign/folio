import UIKit
import UniformTypeIdentifiers

/// Developer Tools sheet: sidebar of sections, detail pane of grouped rows.
@MainActor
final class DeveloperToolsController: UIViewController, UIAdaptivePresentationControllerDelegate {
  enum Section: Int, CaseIterable {
    case overview, input, display, modes, logs, labs, experimental, general, fonts, about

    var title: String {
      switch self {
      case .general: "General"
      case .fonts: "Fonts"
      case .about: "About"
      case .overview: "Overview"
      case .input: "Input"
      case .display: "Display"
      case .modes: "Modes"
      case .logs: "Logs"
      case .labs: "Test Pages"
      case .experimental: "Advanced"
      }
    }
    var symbol: String {
      switch self {
      case .general: "gearshape"
      case .fonts: "textformat"
      case .about: "info.circle"
      case .overview: "info.circle"
      case .input: "hand.point.up.left"
      case .display: "rectangle.on.rectangle"
      case .modes: "shield.lefthalf.filled"
      case .logs: "text.alignleft"
      case .labs: "flask"
      case .experimental: "slider.horizontal.3"
      }
    }
    var summary: String {
      switch self {
      case .general: "What opens when you launch Folio, and how tabs use memory."
      case .fonts: "Manage original font files imported into Folio."
      case .about: "An independent iPad client for Figma Design."
      case .overview:
        "This device, this build and the current page. Attach the report to bug notes."
      case .input:
        "How Folio adapts touch, trackpad and Pencil input. Defaults depend on the control and device."
      case .display: "Window-level settings, also in the ⋯ menu."
      case .modes: "How much Folio adds to the page. Changing the mode reloads the current tab."
      case .logs:
        "Input, keyboard and focus events, kept in memory only (latest 500 general + 2000 UI drag). Nothing is written to disk or the system log."
      case .labs:
        "Bundled test pages for checking input on this iPad. A test page replaces this tab's page until you return to Figma."
      case .experimental:
        "Alternative input methods for troubleshooting. All are off by default; turn one on only if Support asks you to, then turn it off again."
      }
    }
  }

  /// Figma's dark UI palette (see docs/delivery/reference/).
  enum Palette {
    static let panel = ChromePalette.hex(0x2C2C2C)
    static let raised = ChromePalette.hex(0x383838)
    static let well = ChromePalette.hex(0x1E1E1E)
    static let border = ChromePalette.hex(0x444444)
    static let separator = ChromePalette.hex(0x383838)
    static let text = UIColor.white
    static let secondary = ChromePalette.hex(0xB3B3B3)
    static let tertiary = ChromePalette.hex(0x8C8C8C)
    static let accent = ChromePalette.figmaBlue
    static let accentHover = ChromePalette.hex(0x0C8CE9)
    static let selected = ChromePalette.figmaBlue.withAlphaComponent(0.25)
    static let hover = raised
    static let warning = ChromePalette.hex(0xF3C11B)
    static let danger = ChromePalette.hex(0xF24822)
  }

  static func font(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> UIFont {
    .systemFont(ofSize: size, weight: weight)
  }
  static func titleFont(_ size: CGFloat, _ weight: UIFont.Weight = .regular)
    -> UIConfigurationTextAttributesTransformer
  {
    UIConfigurationTextAttributesTransformer {
      var attributes = $0
      attributes.font = UIFont.systemFont(ofSize: size, weight: weight)
      return attributes
    }
  }

  let settings: Bool
  var fontLibraryOpen = false
  var settingsDisplay: FolioSettingsDisplay?
  private var sections: [Section] {
    if settings { return [.general, .display, .input, .fonts, .about] }
    // iPhone: no Experimental (iPad Pencil, WebKit-internal and font-service trials). Testing
    // stays in Debug builds only, for the memory lab and later hardware work.
    if phone {
      #if DEBUG
        return [.overview, .input, .display, .modes, .logs, .labs]
      #else
        return [.overview, .input, .display, .modes, .logs]
      #endif
    }
    return [.overview, .input, .display, .modes, .logs, .labs, .experimental]
  }

  let store: DiagnosticsStore
  var display: DeveloperToolsDisplay?
  var labAvailable: (DeveloperLab) -> Bool = { _ in true }
  var onDismiss: (() -> Void)?
  var onMode: ((BrowserMode) -> Void)?
  var onLogging: ((Bool) -> Void)?
  var onUIDragOptions: (() -> Void)?
  var onLab: ((DeveloperLab?) -> Void)?
  #if DEBUG
    var onDOMProbe: (() -> Void)?
  #endif
  var onStrategy: (() -> Void)?
  var onRefresh: (() -> Void)?
  var onLoopbackProbe: (() -> Void)?

  private var section = Section.overview
  private var dismissalReported = false
  private let sidebar = UIStackView()
  private let detail = UIStackView()
  private let scroller = UIScrollView()
  private var sidebarButtons: [DeveloperToolsSidebarRow] = []
  /// iPhone (Alpha): one column. The section list and the detail page take turns.
  let phone = PhoneExperiencePolicy.isPhone
  private var backButton: UIButton?
  private weak var logView: UITextView?
  private var logTimer: Timer?

  init(store: DiagnosticsStore, settings: Bool = false) {
    self.settings = settings
    section = settings ? .general : .overview
    self.store = store
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
    super.dismiss(animated: flag) { [self] in
      completeDismissal()
      completion?()
    }
  }
  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    completeDismissal()
  }
  func completeDismissal() {
    guard !dismissalReported else { return }
    dismissalReported = true
    logTimer?.invalidate()
    FolioEscape.unregister(self)
    onDismiss?()
    onDismiss = nil
  }

  override var keyCommands: [UIKeyCommand]? {
    let commands = [
      UIKeyCommand(
        input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(closeOverlay)),
      UIKeyCommand(
        input: settings ? "," : "i", modifierFlags: settings ? [.command] : [.command, .alternate],
        action: #selector(close)),
    ]
    for command in commands { command.wantsPriorityOverSystemBehavior = true }
    return commands
  }
  @objc private func closeOverlay() {
    if let window = view.window { FolioEscape.action(in: window)?() }
  }
  @objc private func close() { dismiss(animated: true) }

  override func viewDidLoad() {
    super.viewDidLoad()
    overrideUserInterfaceStyle = .dark
    view.accessibilityIdentifier = settings ? "folioSettings" : "developerTools"
    FolioEscape.register(self) { [weak self] in self?.close() }
    view.backgroundColor = Palette.panel
    view.tintColor = Palette.accent
    view.layer.cornerRadius = 12
    view.layer.borderWidth = 1
    view.layer.borderColor = Palette.border.cgColor
    sheetPresentationController?.preferredCornerRadius = 12

    let title = label(
      settings ? "Settings" : "Developer tools", Self.font(13, .semibold), Palette.text)
    let subtitle = label("Folio \(Self.version)", Self.font(11), Palette.tertiary)
    let heading = UIStackView(arrangedSubviews: [title, subtitle])
    heading.axis = .vertical
    heading.spacing = 2
    heading.isLayoutMarginsRelativeArrangement = true
    heading.directionalLayoutMargins = .init(
      top: 0, leading: DeveloperToolsSidebarRow.inset, bottom: 0, trailing: 0)
    sidebar.axis = .vertical
    sidebar.spacing = 2
    sidebar.addArrangedSubview(heading)
    sidebar.setCustomSpacing(14, after: heading)
    for item in sections {
      let button = DeveloperToolsSidebarRow(title: item.title, symbol: item.symbol)
      button.accessibilityIdentifier =
        "\(settings ? "folioSettings" : "developerTools")-\(item.title)"
      button.addAction(
        UIAction { [weak self] _ in
          self?.select(item)
          self?.showPhoneDetail(true)
        }, for: .touchUpInside)
      sidebarButtons.append(button)
      sidebar.addArrangedSubview(button)
    }
    let sidebarSpacer = UIView()
    sidebar.addArrangedSubview(sidebarSpacer)

    let sidebarDivider = UIView()
    sidebarDivider.backgroundColor = Palette.border
    let closeButton = Self.iconButton(
      "xmark", label: settings ? "Close settings" : "Close developer tools"
    ) { [weak self] in
      self?.close()
    }

    detail.axis = .vertical
    detail.spacing = 8
    scroller.alwaysBounceVertical = true
    scroller.keyboardDismissMode = .interactive
    scroller.addSubview(detail)
    for item in [sidebar, sidebarDivider, scroller, detail, closeButton] as [UIView] {
      item.translatesAutoresizingMaskIntoConstraints = false
    }
    view.addSubview(sidebar)
    view.addSubview(sidebarDivider)
    view.addSubview(scroller)
    view.addSubview(closeButton)
    let safe = view.safeAreaLayoutGuide
    NSLayoutConstraint.activate([
      sidebar.topAnchor.constraint(equalTo: safe.topAnchor, constant: 16),
      sidebar.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 8),
      sidebar.bottomAnchor.constraint(lessThanOrEqualTo: safe.bottomAnchor, constant: -12),
      sidebarDivider.topAnchor.constraint(equalTo: view.topAnchor),
      sidebarDivider.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      sidebarDivider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 8),
      sidebarDivider.widthAnchor.constraint(equalToConstant: 1),
      scroller.topAnchor.constraint(equalTo: view.topAnchor),
      scroller.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      scroller.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      closeButton.topAnchor.constraint(equalTo: safe.topAnchor, constant: 10),
      closeButton.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -10),
      detail.topAnchor.constraint(
        equalTo: scroller.contentLayoutGuide.topAnchor, constant: phone ? 60 : 18),
      detail.bottomAnchor.constraint(
        equalTo: scroller.contentLayoutGuide.bottomAnchor, constant: -24),
      detail.leadingAnchor.constraint(
        equalTo: scroller.contentLayoutGuide.leadingAnchor, constant: 24),
      detail.widthAnchor.constraint(
        equalTo: scroller.frameLayoutGuide.widthAnchor, constant: phone ? -48 : -64),
    ])
    if phone {
      // Full-width section list; the detail page covers it and offers Back.
      sidebarDivider.isHidden = true
      NSLayoutConstraint.activate([
        sidebar.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -56),
        scroller.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      ])
      let back = Self.iconButton("chevron.left", label: "Back to sections") { [weak self] in
        self?.showPhoneDetail(false)
      }
      back.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(back)
      NSLayoutConstraint.activate([
        back.topAnchor.constraint(equalTo: safe.topAnchor, constant: 10),
        back.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 10),
      ])
      backButton = back
      showPhoneDetail(false)
    } else {
      NSLayoutConstraint.activate([
        sidebar.widthAnchor.constraint(equalToConstant: 184),
        scroller.leadingAnchor.constraint(equalTo: sidebarDivider.trailingAnchor),
      ])
    }
    NotificationCenter.default.addObserver(
      self, selector: #selector(localFontsChanged), name: LocalFontService.changed, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(touchModeChanged), name: InputStrategies.touchModeChanged,
      object: nil)
    select(section)
  }

  private func showPhoneDetail(_ shown: Bool) {
    guard phone else { return }
    sidebar.isHidden = shown
    scroller.isHidden = !shown
    backButton?.isHidden = !shown
  }

  @objc private func touchModeChanged() {
    if section == .input { refresh() }
  }

  private func select(_ next: Section) {
    section = next
    for (index, button) in sidebarButtons.enumerated() {
      button.isCurrent = sections[index] == next
    }
    render()
    scroller.setContentOffset(.zero, animated: false)
    logTimer?.invalidate()
    logTimer = nil
    if next == .logs {
      logTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.updateLog() }
      }
    }
  }

  /// Called after lab results or strategy changes arrive from the tab.
  func refresh() {
    guard isViewLoaded else { return }
    if section == .logs {
      updateLog()
    } else {
      let offset = scroller.contentOffset
      render()
      scroller.layoutIfNeeded()
      scroller.contentOffset = offset
    }
  }

  // MARK: - Sections

  private func render() {
    for view in detail.arrangedSubviews { view.removeFromSuperview() }
    let title = label(section.title, Self.font(15, .semibold), Palette.text)
    detail.addArrangedSubview(title)
    detail.setCustomSpacing(4, after: title)
    let summaryText =
      settings && section == .input
      ? "Adapt touch, trackpad and Pencil input for Figma." : section.summary
    let summary = label(summaryText, Self.font(11), Palette.secondary)
    detail.addArrangedSubview(summary)
    detail.setCustomSpacing(20, after: summary)
    switch section {
    case .general: settingsGeneral()
    case .fonts: settingsFonts()
    case .about: settingsAbout()
    case .overview: overview()
    case .input: settings ? settingsInput() : input()
    case .display: settings ? settingsDisplaySection() : displaySection()
    case .modes: modes()
    case .logs: logs()
    case .labs: labs()
    case .experimental: experimental()
    }
  }

  var safe: Bool { store.session.mode == .safe }

  private func overview() {
    let info = store.overview
    group(
      "Device",
      info.map { valueRow($0.0, $0.1) })
    group(
      nil,
      [
        actionRow("Copy diagnostics report", "Full report to the clipboard, URLs redacted.") {
          [weak self] in
          guard let self else { return }
          self.onRefresh?()
          UIPasteboard.general.string = self.store.report
        },
        actionRow("Share report…", "Save to Files, AirDrop or a note.") { [weak self] in
          self?.shareReport()
        },
        actionRow("Refresh page capture", "Re-reads WebGL, viewport and user agent from the page.")
        {
          [weak self] in
          self?.onRefresh?()
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.refresh() }
        },
      ])
  }

  private func input() {
    let strategies = store.strategies
    let preferences = FolioPreferences()
    if safe { notice("Safe mode is on, so none of these run. Switch to Normal in Modes.") }
    // iPhone has no trackpad or Apple Pencil today: those groups stay iPad-only.
    if !phone {
      group(
        "Trackpad and mouse",
        [
          toggleRow(
            "Trackpad pinch zoom",
            "Pinching or Ctrl-scrolling on the canvas zooms Figma instead of the whole page. Turn off if zoom jumps or fights Figma.",
            strategies.trackpadPinchZoom
          ) { strategies.trackpadPinchZoom = $0 }
        ])
    }
    let touchMode = choiceRow(
      "Touch mode",
      "Saved for all tabs and windows. Pencil & Touch pans with one finger; Touch Only points and drags with one finger.",
      TouchMode.allCases.map(\.title), TouchMode.allCases.firstIndex(of: strategies.touchMode)
    ) { strategies.touchMode = TouchMode.allCases[$0] }
    group(
      "Touch",
      (PhoneExperiencePolicy.supportsPencil() ? [touchMode] : []) + [
        toggleRow(
          "Two-finger pan on canvas",
          "Two-finger drags on the canvas scroll it like a trackpad. Turn off if panning moves the page instead.",
          strategies.fingerCanvasWheel
        ) { strategies.fingerCanvasWheel = $0 },
        toggleRow(
          "Touch gestures",
          "Canvas hold menus and tap-to-open Home files. Sidebars stay native; stationary finger/Pencil holds add a menu.",
          strategies.touchGestures
        ) { strategies.touchGestures = $0 },
        toggleRow(
          "Multi-finger tap undo/redo",
          "Two fingers undo; three redo on the canvas. Ignored while editing text.",
          strategies.multiFingerTap
        ) { strategies.multiFingerTap = $0 },
        toggleRow(
          "Resize helper", "Makes panel edges easier to grab with a finger.",
          strategies.resizeHelper
        ) { strategies.resizeHelper = $0 },
        toggleRow(
          "Readable button colours",
          "Keeps native form buttons from turning system blue. Turn off to see WebKit's raw styling.",
          strategies.uaButtonColor
        ) { strategies.uaButtonColor = $0 },
        toggleRow(
          "Hide Google sign-in on Figma's login page",
          "Google blocks sign-in from embedded browsers, so Folio hides that button on Figma's login and sign-up pages. Reload the page after changing.",
          strategies.hideGoogle
        ) { strategies.hideGoogle = $0 },
      ]
        // Also on iPad: narrow windows use the compact layout.
        + [
          toggleRow(
            "Phone panel layout",
            "Hides Figma's sidebars and tool bar while Folio's bottom toolbar is shown; Layers and Properties open one at a time as a bottom sheet. Turn off if Figma's layout breaks.",
            strategies.phoneLayout
          ) { strategies.phoneLayout = $0 },
          toggleRow(
            "Canvas beside panels (experimental)",
            "While Layers or Properties is open, Folio widens the page by the space Figma reserves for its sidebars and shifts it left, so the canvas stays visible above the sheet. Turn off to compare with an empty area above the sheet.",
            strategies.phoneWideViewport
          ) { strategies.phoneWideViewport = $0 },
          toggleRow(
            "Number keyboard for numeric fields",
            "Number fields in the Properties sheet open the number keypad, with a row for − + × ÷ % . and ± above it. Turn off to get the full keyboard in every field.",
            strategies.phoneNumberKeyboard
          ) { strategies.phoneNumberKeyboard = $0 },
        ])
    if PhoneExperiencePolicy.supportsPencil() {
      group(
        "Apple Pencil",
        [
          choiceRow(
            "Double-tap", "What the Pencil's double-tap does in Folio.",
            PencilAction.allCases.map(\.title),
            PencilAction.allCases.firstIndex(of: preferences.pencilBinding(squeeze: false))
          ) { preferences.setPencilBinding(PencilAction.allCases[$0], squeeze: false) },
          choiceRow(
            "Squeeze", "What squeezing Apple Pencil Pro does in Folio.",
            PencilAction.allCases.map(\.title),
            PencilAction.allCases.firstIndex(of: preferences.pencilBinding(squeeze: true))
          ) { preferences.setPencilBinding(PencilAction.allCases[$0], squeeze: true) },
        ],
        footer:
          "Pencil drawing itself follows WebKit's default.")
    }
    group(
      nil,
      [
        actionRow(
          "Reset input settings to defaults",
          "Restores Input and experimental input settings. Applies to this tab now, new tabs after.",
          destructive: true
        ) { [weak self] in
          strategies.resetInputDefaults()
          self?.onStrategy?()
          self?.refresh()
        }
      ])
  }

  private func displaySection() {
    guard let display else {
      notice("Open Developer Tools from the ⋯ menu to change window settings here.")
      return
    }
    let zoom = display.zoom()
    let zoomButtons: [(String, InterfaceZoomAction, Bool)] = [
      ("−", .decrease, zoom?.canDecrease ?? false),
      (zoom?.percent ?? "100%", .reset, true),
      ("+", .increase, zoom?.canIncrease ?? false),
    ]
    let stepper = UIStackView(
      arrangedSubviews: zoomButtons.map { title, action, enabled in
        let button = Self.smallButton(title) { [weak self] in
          display.setZoom(action)
          self?.refresh()
        }
        button.isEnabled = enabled
        return button
      })
    stepper.spacing = 4
    let counts = PhoneExperiencePolicy.tabLimitChoices
    group(
      "Window",
      [
        row(
          "Interface zoom",
          "Scales Figma's interface like browser zoom. Tap the value to reset. ⌥⌘= / ⌥⌘- / ⌥⌘0",
          accessory: zoom == nil ? nil : stepper),
        choiceRow(
          "Keep tabs loaded",
          PhoneExperiencePolicy.isPhone
            ? "Automatic keeps one document loaded on iPhone. Home stays loaded."
            : "Automatic keeps all tabs until memory pressure. A cap unloads background documents; Home stays loaded.",
          counts.map { $0 == 0 ? "Automatic" : "\($0) tabs" },
          counts.firstIndex(of: display.keepTabsLoaded())
        ) { [weak self] in
          display.setKeepTabsLoaded(counts[$0])
          self?.refresh()
        },
      ])
  }

  private func modes() {
    let explained: [(BrowserMode, String)] = [
      (.normal, "Everything on: input adaptations, Folio's page scripts and native integration."),
      (
        .compatibility,
        "Same adaptations with a desktop-like page setup. Use when Figma misdetects the iPad."
      ),
      (
        .safe,
        "Nothing injected: plain WKWebView with no Folio scripts. Use to tell Folio bugs from Figma or WebKit bugs. ⌘⌥⇧S asks for it from anywhere."
      ),
    ]
    group(
      "Mode",
      explained.map { mode, detail in
        let current = store.session.mode == mode
        return actionRow(mode.rawValue, detail, checked: current) { [weak self] in
          guard !current else { return }
          self?.onMode?(mode)
          self?.refresh()
        }
      },
      footer: "Switching reloads this tab. Unsynced edits may be lost.")
  }

  private func logs() {
    group(
      "Capture",
      [
        toggleRow(
          "Input logging",
          "Records pointer, wheel, keyboard and focus events from the page and native views. Slows input slightly; leave off when not debugging.",
          store.inputLogging, ignoresSafe: true
        ) { [weak self] in
          self?.onLogging?($0)
        },
        toggleRow(
          "Record UI drag events",
          "Native capture events, uncaught errors and HTML drag/drop. Memory only; labels redacted. Calls and caught errors cannot be observed.",
          store.uiDragLogging
        ) { [weak self] enabled in
          self?.store.uiDragLogging = enabled
          self?.onUIDragOptions?()
        },
      ])
    let text = UITextView()
    text.isEditable = false
    text.backgroundColor = Palette.well
    text.textColor = Palette.text
    text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    text.layer.cornerRadius = 6
    text.layer.borderWidth = 1
    text.layer.borderColor = Palette.border.cgColor
    text.textContainerInset = .init(top: 10, left: 8, bottom: 10, right: 8)
    text.accessibilityIdentifier = "developerToolsLog"
    text.heightAnchor.constraint(equalToConstant: 380).isActive = true
    logView = text
    detail.addArrangedSubview(header("Events"))
    detail.addArrangedSubview(text)
    updateLog()
    let copy = Self.smallButton("Copy log", primary: true) { [weak self] in
      UIPasteboard.general.string = self?.store.events.joined(separator: "\n")
    }
    let clear = Self.smallButton("Clear") { [weak self] in
      self?.store.clearEvents()
      self?.updateLog()
    }
    let buttons = UIStackView(arrangedSubviews: [copy, clear, UIView()])
    buttons.spacing = 8
    detail.addArrangedSubview(buttons)
  }

  private func updateLog() {
    guard let logView else { return }
    let events = store.events
    let next =
      events.isEmpty
      ? ((store.inputLogging || store.uiDragLogging)
        ? "Waiting for events…" : "No events. Turn on input logging above.")
      : events.joined(separator: "\n")
    guard logView.text != next else { return }
    let atBottom =
      logView.contentOffset.y >= logView.contentSize.height - logView.bounds.height - 20
    logView.text = next
    if atBottom {
      logView.scrollRangeToVisible(NSRange(location: (next as NSString).length, length: 0))
    }
  }

  private func labs() {
    if safe { notice("Test pages are unavailable in Safe mode.") }
    var rows: [UIView] = []
    #if DEBUG
      let probe = actionRow(
        "Capture DOM structure",
        "Active Figma file only. Saves redacted structure in Documents/dom-probe."
      ) { [weak self] in self?.onDOMProbe?() }
      probe.isUserInteractionEnabled = !safe
      probe.alpha = safe ? 0.5 : 1
      rows.append(probe)
    #endif
    if let active = store.activeLab {
      rows.append(
        actionRow("Return to Figma", "Leaves the \(active.title.lowercased()).") { [weak self] in
          self?.onLab?(nil)
        })
    }
    rows += DeveloperLab.allCases.filter(labAvailable).map { lab in
      let row = actionRow(
        store.activeLab == lab ? "Reload \(lab.title.lowercased())" : lab.title, lab.detail,
        chevron: true
      ) { [weak self] in self?.onLab?(lab) }
      row.isUserInteractionEnabled = !safe
      row.alpha = safe ? 0.5 : 1
      return row
    }
    fonts()
    group("Bundled pages", rows)
    if !safe {
      let memoryNote = UITextField()
      memoryNote.placeholder = "e.g. 42% or 1800 MiB"
      memoryNote.text = store.memory.note
      memoryNote.textColor = Palette.text
      memoryNote.font = Self.font(12)
      memoryNote.attributedPlaceholder = NSAttributedString(
        string: "e.g. 42% or 1800 MiB",
        attributes: [.foregroundColor: Palette.tertiary, .font: Self.font(12)])
      memoryNote.backgroundColor = Palette.raised
      memoryNote.layer.cornerRadius = 5
      memoryNote.layer.borderWidth = 1
      memoryNote.layer.borderColor = Palette.border.cgColor
      memoryNote.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 8, height: 1))
      memoryNote.rightView = UIView(frame: CGRect(x: 0, y: 0, width: 8, height: 1))
      memoryNote.leftViewMode = .always
      memoryNote.rightViewMode = .always
      memoryNote.widthAnchor.constraint(equalToConstant: 160).isActive = true
      memoryNote.heightAnchor.constraint(equalToConstant: 28).isActive = true
      memoryNote.autocorrectionType = .no
      memoryNote.autocapitalizationType = .none
      memoryNote.textAlignment = .right
      memoryNote.accessibilityLabel = "Figma memory meter"
      memoryNote.addAction(
        UIAction { [weak self, weak memoryNote] _ in
          try? self?.store.memory.setNote(memoryNote?.text ?? "")
        }, for: .editingChanged)
      group(
        "Figma memory meter",
        [row("Value from View > Memory usage", nil, accessory: memoryNote)],
        footer: "Values only: 42%, 1800 MiB, or 90% / 1800 MiB. Saved with the memory report.")
    }
    #if DEBUG
      group(
        "Launch-argument tools",
        [
          valueRow("Tab fixture", "--tabs-lab"),
          valueRow("Pinch recorder", "--pinch-harness"),
        ],
        footer:
          "Debug builds only, started from Xcode with these arguments. See tests/device-checklist.md."
      )
    #endif
  }

  private func experimental() {
    #if DEBUG
      group(
        "Fonts",
        [
          toggleRow(
            "Local fonts (experimental)",
            "Blocked on iPad: Figma can't currently reach this loopback font service (WebKit blocks HTTP loopback; Figma's HTTPS route needs its own certificate). Kept for diagnostics only. Use Figma's font upload. See docs/research/local-fonts.md.",
            LocalFontService.shared.enabled, ignoresSafe: true
          ) { LocalFontService.shared.enabled = $0 },
          toggleRow(
            "Diagnostic only: Chrome user agent probe",
            "New tabs present desktop Chrome 141 instead of Safari, to test whether Figma then tries the HTTP helper port. Diagnostic only, never a shipping route; resets to OFF on relaunch. Figma may behave differently, and Google sign-in must not be used while on. Requires Local fonts; open a new tab.",
            LocalFontService.shared.chromeUserAgentProbe, ignoresSafe: true
          ) { LocalFontService.shared.chromeUserAgentProbe = $0 },
        ],
        footer:
          "Debug builds only. No HTTPS certificate or security bypass is installed. Manage originals under Test Pages > Fonts."
      )
    #endif
    let strategies = store.strategies
    if safe { notice("Safe mode disables the input experiments below.") }
    group(
      "Pencil",
      [
        choiceRow(
          "Pencil strategy",
          "none: WebKit default. pencil-as-mouse-js: Pencil drags as a mouse. pencil-gesture-reroute: moves WebKit's own Pencil recognisers (WebKit internals).",
          PencilStrategy.allCases.map(\.rawValue),
          PencilStrategy.allCases.firstIndex(of: strategies.pencil)
        ) { strategies.pencil = PencilStrategy.allCases[$0] },
        toggleRow(
          "Pencil drags don't move objects",
          "Turn on if dragging with Apple Pencil doesn't move objects on this iPad, so the Pencil strategy above can compensate. Resets when Folio restarts.",
          strategies.penDragUnusable
        ) { strategies.penDragUnusable = $0 },
      ])
    group(
      "Touch",
      [
        choiceRow(
          "Finger pan",
          "baseline: WebKit default. The other two reroute one-finger drags to the page or canvas through WebKit internals.",
          FingerPanStrategy.allCases.map(\.rawValue),
          FingerPanStrategy.allCases.firstIndex(of: strategies.finger)
        ) { strategies.finger = FingerPanStrategy.allCases[$0] }
      ])
    group(
      "Keyboard",
      [
        toggleRow(
          "Browser focus restoration",
          "Puts keyboard focus back in the page after chrome taps, so shortcuts keep working. Uses WebKit internals; can raise the on-screen keyboard.",
          strategies.browserFocusRestoration
        ) { strategies.browserFocusRestoration = $0 }
      ])
  }

  // MARK: - Building blocks

  private func shareReport() {
    onRefresh?()
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "folio-diagnostics.txt")
    try? store.report.write(to: url, atomically: true, encoding: .utf8)
    let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
    share.popoverPresentationController?.sourceView = view
    share.popoverPresentationController?.sourceRect = CGRect(
      x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
    present(share, animated: true)
  }

  private func label(_ text: String, _ font: UIFont, _ color: UIColor) -> UILabel {
    let label = UILabel()
    label.text = text
    label.font = font
    label.textColor = color
    label.numberOfLines = 0
    return label
  }

  /// Figma-style group title: 11 pt semibold, primary text.
  private func header(_ text: String) -> UILabel {
    label(text, Self.font(11, .semibold), Palette.text)
  }

  func notice(_ text: String) {
    detail.addArrangedSubview(label(text, Self.font(11), Palette.warning))
  }

  func group(_ title: String?, _ rows: [UIView], footer: String? = nil) {
    if let title {
      let header = header(title)
      detail.addArrangedSubview(header)
      detail.setCustomSpacing(6, after: header)
    }
    let box = UIStackView()
    box.axis = .vertical
    box.layer.cornerRadius = 8
    box.layer.borderWidth = 1
    box.layer.borderColor = Palette.border.cgColor
    box.clipsToBounds = true
    for (index, row) in rows.enumerated() {
      if index > 0 {
        let line = UIView()
        line.backgroundColor = Palette.separator
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        box.addArrangedSubview(line)
      }
      box.addArrangedSubview(row)
    }
    detail.addArrangedSubview(box)
    if let footer {
      let note = label(footer, Self.font(11), Palette.tertiary)
      detail.setCustomSpacing(6, after: box)
      detail.addArrangedSubview(note)
      detail.setCustomSpacing(20, after: note)
    } else {
      detail.setCustomSpacing(20, after: box)
    }
  }

  /// Every detail row starts its text at the same inset; accessories sit on the trailing edge.
  func row(_ title: String, _ subtitle: String?, accessory: UIView?) -> UIView {
    let titleLabel = label(title, Self.font(12, .medium), Palette.text)
    let texts = UIStackView(arrangedSubviews: [titleLabel])
    texts.axis = .vertical
    texts.spacing = 2
    if let subtitle {
      texts.addArrangedSubview(label(subtitle, Self.font(11), Palette.secondary))
    }
    let row = UIStackView(arrangedSubviews: [texts])
    if let accessory {
      accessory.setContentHuggingPriority(.required, for: .horizontal)
      accessory.setContentCompressionResistancePriority(.required, for: .horizontal)
      row.addArrangedSubview(accessory)
    }
    row.alignment = .center
    row.spacing = 16
    row.isLayoutMarginsRelativeArrangement = true
    row.directionalLayoutMargins = .init(top: 8, leading: 12, bottom: 8, trailing: 12)
    row.heightAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true
    row.accessibilityIdentifier = title
    return row
  }

  func valueRow(_ title: String, _ value: String) -> UIView {
    let valueLabel = label(
      value, .monospacedDigitSystemFont(ofSize: 12, weight: .regular), Palette.secondary)
    valueLabel.textAlignment = .right
    valueLabel.numberOfLines = 2
    let view = row(title, nil, accessory: valueLabel)
    valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return view
  }

  func toggleRow(
    _ title: String, _ detail: String, _ isOn: Bool, ignoresSafe: Bool = false,
    set: @escaping (Bool) -> Void
  ) -> UIView {
    let toggle = UISwitch()
    let enabled = ignoresSafe || !safe
    toggle.isOn = isOn && enabled
    toggle.isEnabled = enabled
    toggle.onTintColor = Palette.accent
    toggle.accessibilityLabel = title
    toggle.addAction(
      UIAction { [weak self, weak toggle] _ in
        set(toggle?.isOn == true)
        self?.onStrategy?()
        self?.refresh()
      }, for: .valueChanged)
    return row(title, detail, accessory: compact(toggle))
  }

  /// Scales the system switch down to Figma's small toggle size, keeping a matching layout box.
  private func compact(_ toggle: UISwitch) -> UIView {
    let scale: CGFloat = 0.62
    let size = toggle.sizeThatFits(.zero)
    let box = UIView()
    toggle.transform = CGAffineTransform(scaleX: scale, y: scale)
    toggle.translatesAutoresizingMaskIntoConstraints = false
    box.addSubview(toggle)
    NSLayoutConstraint.activate([
      box.widthAnchor.constraint(equalToConstant: ceil(size.width * scale)),
      box.heightAnchor.constraint(equalToConstant: ceil(size.height * scale)),
      toggle.centerXAnchor.constraint(equalTo: box.centerXAnchor),
      toggle.centerYAnchor.constraint(equalTo: box.centerYAnchor),
    ])
    return box
  }

  /// Figma-style dropdown: bordered field with the value and a small chevron.
  func choiceRow(
    _ title: String, _ detail: String, _ values: [String], _ selected: Int?,
    set: @escaping (Int) -> Void
  ) -> UIView {
    var config = UIButton.Configuration.plain()
    config.title = selected.map { values[$0] } ?? "—"
    config.titleTextAttributesTransformer = Self.titleFont(11)
    config.image = UIImage(systemName: "chevron.down")
    config.imagePlacement = .trailing
    config.imagePadding = 8
    config.preferredSymbolConfigurationForImage = .init(pointSize: 8, weight: .semibold)
    config.baseForegroundColor = Palette.text
    config.contentInsets = .init(top: 5, leading: 8, bottom: 5, trailing: 8)
    config.background.strokeColor = Palette.border
    config.background.strokeWidth = 1
    config.background.cornerRadius = 5
    let button = UIButton(configuration: config)
    button.showsMenuAsPrimaryAction = true
    button.isEnabled = !safe || section == .display || section == .general
    button.accessibilityLabel = title
    button.menu = UIMenu(
      children: values.enumerated().map { index, value in
        UIAction(title: value, state: index == selected ? .on : .off) { [weak self] _ in
          set(index)
          self?.onStrategy?()
          self?.refresh()
        }
      })
    return row(title, detail, accessory: button)
  }

  func actionRow(
    _ title: String, _ detail: String?, checked: Bool = false, chevron: Bool = false,
    destructive: Bool = false, action: @escaping () -> Void
  ) -> UIView {
    let symbol = checked ? "checkmark" : chevron ? "chevron.right" : nil
    let accessory = symbol.map {
      UIImageView(
        image: UIImage(
          systemName: $0,
          withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)))
    }
    accessory?.tintColor = checked ? Palette.accent : Palette.tertiary
    let content = row(title, detail, accessory: accessory)
    if let titleLabel = (content.subviews.first as? UIStackView)?.arrangedSubviews.first
      as? UILabel
    {
      titleLabel.textColor =
        destructive ? Palette.danger : checked ? Palette.text : Palette.accent
    }
    let button = DeveloperToolsPressable()
    button.accessibilityTraits = checked ? [.button, .selected] : .button
    button.accessibilityLabel = title
    button.isAccessibilityElement = true
    content.isUserInteractionEnabled = false
    content.translatesAutoresizingMaskIntoConstraints = false
    button.addSubview(content)
    NSLayoutConstraint.activate([
      content.topAnchor.constraint(equalTo: button.topAnchor),
      content.bottomAnchor.constraint(equalTo: button.bottomAnchor),
      content.leadingAnchor.constraint(equalTo: button.leadingAnchor),
      content.trailingAnchor.constraint(equalTo: button.trailingAnchor),
    ])
    button.addAction(UIAction { _ in action() }, for: .touchUpInside)
    return button
  }

  static var version: String {
    let info = Bundle.main.infoDictionary
    let short = info?["CFBundleShortVersionString"] as? String ?? "?"
    let build = info?["CFBundleVersion"] as? String ?? "?"
    return "\(short) (\(build))"
  }
}

extension DeveloperToolsController: UIDocumentPickerDelegate {
  @objc private func localFontsChanged() {
    if section == .labs || section == .experimental || section == .fonts { refresh() }
  }

  static var fontLibraryFooter: String {
    #if DEBUG
      "Import only licensed original static TTF, OTF or TTC files. Imports stay in Folio and are excluded from backup. The experimental font connection is managed in Developer Tools."
    #else
      "Import only licensed original static TTF, OTF or TTC files. Imports stay in Folio and are excluded from backup. Figma can't use imported fonts in this version; upload fonts in Figma instead."
    #endif
  }

  func fonts(diagnostics requested: Bool = true) {
    let library = LocalFontLibrary.shared
    // The font service is compiled only into Debug builds; Release shows the library alone.
    #if DEBUG
      let diagnostics = requested
    #else
      let diagnostics = false
    #endif
    #if DEBUG
      let service = LocalFontService.shared
      var rows: [UIView] =
        diagnostics
        ? [
          valueRow("Font service", service.status),
          valueRow(
            "Loopback ports",
            "127.0.0.1:\(LocalFontService.port) (HTTP), :\(LocalFontService.tlsProbePort) (probe)"),
          valueRow("Imported fonts", "\(library.faces.count) faces / \(library.files.count) files"),
          valueRow(
            "User agent",
            service.chromeUserAgentProbe ? "Chrome probe (new tabs)" : "WebKit default"),
          row(
            "Requests received: \(service.requestCount)",
            service.recent.isEmpty
              ? "None yet. Connect Folio in Figma's Preferences > Permissions and helpers, then reload the file."
              : service.recent.joined(separator: "\n"), accessory: nil),
        ]
        : [
          valueRow("Imported fonts", "\(library.faces.count) faces / \(library.files.count) files")
        ]
      if diagnostics, service.enabled, let probe = onLoopbackProbe {
        rows.append(
          actionRow(
            "Test HTTP loopback from this page",
            "Folio's own isolated script fetches /figma/version on port \(LocalFontService.port) via 127.0.0.1, localhost and [::1] from the current page. Shows whether WebKit allows the HTTP helper route here."
          ) { probe() })
      }
    #else
      var rows: [UIView] = [
        valueRow("Imported fonts", "\(library.faces.count) faces / \(library.files.count) files")
      ]
    #endif
    rows += [
      actionRow(
        "Import licensed fonts…", "Choose original TTF, OTF or static TTC files from Files.",
        chevron: true
      ) {
        [weak self] in
        let types = ["ttf", "otf", "ttc"].compactMap { UTType(filenameExtension: $0) }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        self?.present(picker, animated: true)
      }
    ]
    for file in library.files {
      let description = file.faces.map {
        "\($0.family) · \($0.style) · \($0.postscript) · weight \(Int($0.weight))\($0.italic ? " · italic" : "")"
      }.joined(separator: "\n")
      let delete = Self.iconButton("trash", label: "Delete imported font") { [weak self] in
        do {
          try library.delete(file)
          self?.refresh()
        } catch { self?.fontError("The imported file could not be deleted.") }
      }
      delete.tintColor = Palette.danger
      rows.append(
        row(file.faces.first?.family ?? "Font collection", description, accessory: delete))
    }
    group(
      "Fonts", rows,
      footer: (diagnostics
        ? "Import only fonts licensed for use by Figma. Enabling the service exposes their metadata and bytes to Figma's page. Imports stay in Folio, are excluded from backup and are not installed systemwide. Static fonts only; 32 MiB per file, 128 MiB total. No requests can also mean mixed-content, CSP, discovery or TLS blocked access."
        : Self.fontLibraryFooter)
    )
    if let issue = library.issue { notice(issue) }
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL])
  {
    Task { [weak self] in
      var failures: [String] = []
      for url in urls {
        do { try await LocalFontLibrary.shared.importFile(url) } catch let error
          as LocalFontLibrary.Failure
        { failures.append(error.message) } catch {
          failures.append("A selected font could not be imported from Files.")
        }
      }
      self?.refresh()
      if !failures.isEmpty {
        self?.fontError(Array(Set(failures)).sorted().joined(separator: "\n"))
      }
    }
  }

  private func fontError(_ message: String) {
    let alert = UIAlertController(title: "Font library", message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    present(alert, animated: true)
  }
}
