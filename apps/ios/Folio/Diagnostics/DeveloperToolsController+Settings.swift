import SafariServices
import UIKit

/// Settings shares the Developer Tools sheet and controls, without diagnostic sections.
extension DeveloperToolsController {
  func settingsGeneral() {
    let preferences = FolioPreferences()
    group(
      "Launch",
      [
        choiceRow(
          "Start page", "The selected page when Folio opens. Applies on next launch.",
          ["Home", "Last viewed tab"], preferences.startAtHome ? 0 : 1
        ) { preferences.startAtHome = $0 == 0 },
        toggleRow(
          "Restore tabs",
          "Reopen this window's files and pins on launch. Turning off clears saved tab lists without closing your open files.",
          preferences.restoreTabs, ignoresSafe: true
        ) { preferences.restoreTabs = $0 },
      ])
    group(
      "Help",
      [
        actionRow(
          "Welcome tour", "Touch mode, Apple Pencil shortcuts and a quick tour of Folio.",
          chevron: true
        ) { [weak self] in
          let presenter = self?.presentingViewController
          self?.dismiss(animated: true) {
            if let presenter { OnboardingController.present(from: presenter) }
          }
        }
      ])
    if let display {
      let counts = PhoneExperiencePolicy.tabLimitChoices
      group(
        "Memory",
        [
          choiceRow(
            "Tab memory policy",
            PhoneExperiencePolicy.isPhone
              ? "Automatic keeps one file loaded on iPhone. Other files reload when selected; Home stays loaded."
              : "Automatic keeps tabs until memory pressure. A cap unloads background files; Home stays loaded.",
            counts.map { $0 == 0 ? "Automatic" : "\($0) tabs" },
            counts.firstIndex(of: display.keepTabsLoaded())
          ) { display.setKeepTabsLoaded(counts[$0]) }
        ])
    }
  }

  func settingsDisplaySection() {
    guard let display, let controls = settingsDisplay else { return }
    let presets = InterfaceZoomPreset.available
    let zoom = display.zoom()
    var rows = [
      choiceRow(
        "Default interface zoom",
        phone
          ? "Scales Figma and Folio's toolbar. Phone-size and unfolded iPhone Duo windows each keep their own value."
          : "Scales Figma and Folio's toolbar. Saved for all windows and future launches.",
        presets.map(\.title), presets.firstIndex { $0.rawValue == zoom?.scale }
      ) { display.setZoom(.preset(presets[$0])) }
    ]
    // Compact layouts (iPhone, narrow iPad windows) always show the bottom toolbar.
    if controls.canHideBottomToolbar() {
      rows.append(
        toggleRow(
          "Show bottom toolbar",
          "Modifier keys, arrow keys and edit commands under file tabs. ⌃⇧⌘B shows or hides it.",
          controls.bottomToolbarVisible(), ignoresSafe: true
        ) { controls.setBottomToolbarVisible($0) })
    }
    // iPhone Duo only (the one phone with multiple windows): chrome designs under test.
    if PhoneExperiencePolicy.isPhone, UIApplication.shared.supportsMultipleScenes {
      let styles = PhoneExperiencePolicy.DuoChrome.allCases
      rows.append(
        choiceRow(
          "iPhone Duo layout",
          "Side rails put Undo at the top and Cut, Copy and Paste at the bottom of the window's edge, in glass, wherever the system shows its side column. Folded and side by side, Home, the tab, the count and ⋯ sit in glass in a short top bar, a tools button holds the other edit commands, and the bottom bar always shows the modifier keys. Top bar keeps the usual bars everywhere.",
          styles.map(\.title), styles.firstIndex(of: PhoneExperiencePolicy.duoChrome)
        ) { PhoneExperiencePolicy.duoChrome = styles[$0] })
    }
    group("Interface", rows)
  }

  func settingsInput() {
    let strategies = store.strategies
    let preferences = FolioPreferences()
    if safe {
      notice(
        "Safe mode disables input adaptations. Change the mode in Developer Tools to use them.")
    }
    // iPhone: no trackpad or Apple Pencil rows; touch settings only.
    let pinch = toggleRow(
      "Trackpad pinch zoom", "Pinch or Ctrl-scroll to zoom the canvas.",
      strategies.trackpadPinchZoom
    ) { strategies.trackpadPinchZoom = $0 }
    let touchMode = choiceRow(
      "Touch mode",
      "Saved for all tabs and windows. Pencil & Touch pans with one finger; Touch Only points and drags with one finger.",
      TouchMode.allCases.map(\.title), TouchMode.allCases.firstIndex(of: strategies.touchMode)
    ) { strategies.touchMode = TouchMode.allCases[$0] }
    group(
      phone ? "Touch" : "Trackpad and touch",
      (phone ? [] : [pinch]) + (PhoneExperiencePolicy.supportsPencil() ? [touchMode] : []) + [
        toggleRow(
          "Two-finger canvas pan", "Drag with two fingers to pan the canvas.",
          strategies.fingerCanvasWheel
        ) { strategies.fingerCanvasWheel = $0 },
        toggleRow(
          "Touch gestures",
          "Canvas hold menus and Home taps. Sidebars stay native; hold still with finger/Pencil for a menu.",
          strategies.touchGestures
        ) { strategies.touchGestures = $0 },
        toggleRow(
          "Resize helper", "Makes panel edges easier to grab with a finger.",
          strategies.resizeHelper
        ) { strategies.resizeHelper = $0 },
      ],
      footer: phone
        ? "Input changes apply to this tab now and to newly opened tabs. Existing sibling tabs keep their settings."
        : nil)
    guard PhoneExperiencePolicy.supportsPencil() else { return }
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
        "Input changes apply to this tab now and to newly opened tabs. Existing sibling tabs keep their settings."
    )
  }

  func settingsFonts() {
    if fontLibraryOpen {
      group(
        nil,
        [
          actionRow("Back to Fonts", nil) { [weak self] in
            self?.fontLibraryOpen = false
            self?.refresh()
          }
        ])
      fonts(diagnostics: false)
    } else {
      group(
        "Library",
        [
          actionRow(
            "Font library…", "Import and remove original static TTF, OTF or TTC files.",
            chevron: true
          ) { [weak self] in
            self?.fontLibraryOpen = true
            self?.refresh()
          }
        ],
        footer: Self.fontLibraryFooter
      )
    }
  }

  func settingsAbout() {
    let info = Bundle.main.infoDictionary
    group(
      "Folio",
      [
        valueRow("Version", info?["CFBundleShortVersionString"] as? String ?? "?"),
        valueRow("Build", info?["CFBundleVersion"] as? String ?? "?"),
        actionRow(
          "Help & Support",
          "Guides, troubleshooting and how to contact support.", chevron: true
        ) { [weak self] in
          self?.openDocumentation(PublicSite.supportURL)
        },
        actionRow("Privacy", "How Folio handles login, saved tabs and diagnostics.", chevron: true)
        { [weak self] in
          self?.showPrivacy()
        },
        actionRow("Terms of Use", "The terms for using Folio.", chevron: true) { [weak self] in
          self?.openDocumentation(PublicSite.termsURL)
        },
        actionRow("Legal Notice", "Who provides Folio, trademarks and licences.", chevron: true) {
          [weak self] in
          self?.openDocumentation(PublicSite.legalURL)
        },
      ])
  }

  private func openDocumentation(_ url: URL) {
    let browser = SFSafariViewController(url: url)
    present(browser, animated: true)
  }

  private func showPrivacy() {
    let alert = UIAlertController(
      title: "Privacy",
      message:
        "Folio connects directly to Figma. Sign-in stays in WebKit's website storage; Folio has no credential form or proxy. Saved tab lists contain sanitized file routes, names and pins. You can clear them by turning off Restore tabs. Optional input diagnostics stay in memory until you copy or share a report. Imported fonts stay in Folio and are excluded from backup.",
      preferredStyle: .alert)
    alert.addAction(
      UIAlertAction(title: "Privacy documentation", style: .default) { [weak self] _ in
        self?.openDocumentation(PublicSite.privacyURL)
      })
    alert.addAction(UIAlertAction(title: "Done", style: .cancel))
    present(alert, animated: true)
  }
}
