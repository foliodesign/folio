import QuickLook
import UIKit

/// Public containment keeps Close outside QuickLook's tap-to-hide chrome. The header bar uses
/// the Developer Tools palette: file name on the leading edge, Close on the trailing edge.
@MainActor
final class DownloadPreviewController: UIViewController {
  let preview = QLPreviewController()
  private(set) lazy var closeButton = DeveloperToolsController.smallButton("Close") {
    [weak self] in self?.onClose?()
  }
  private lazy var previewNavigation = UINavigationController(rootViewController: preview)
  private var reloadedAfterAttachment = false
  var onClose: (() -> Void)?

  init() {
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .fullScreen
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    let palette = DeveloperToolsController.Palette.self
    overrideUserInterfaceStyle = .dark
    view.backgroundColor = palette.panel
    let name = UILabel()
    name.text = title
    name.font = DeveloperToolsController.font(12, .medium)
    name.textColor = palette.text
    name.lineBreakMode = .byTruncatingMiddle
    let divider = UIView()
    divider.backgroundColor = palette.separator
    closeButton.accessibilityIdentifier = "folioDownloadPreviewClose"
    addChild(previewNavigation)
    preview.view.accessibilityIdentifier = "folioDownloadPreview"
    for item in [name, closeButton, divider, previewNavigation.view] as [UIView] {
      item.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(item)
    }
    let safe = view.safeAreaLayoutGuide
    NSLayoutConstraint.activate([
      closeButton.topAnchor.constraint(equalTo: safe.topAnchor, constant: 10),
      closeButton.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16),
      closeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 56),
      name.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
      name.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -16),
      name.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
      divider.topAnchor.constraint(equalTo: closeButton.bottomAnchor, constant: 10),
      divider.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      divider.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      divider.heightAnchor.constraint(equalToConstant: 1),
      previewNavigation.view.topAnchor.constraint(equalTo: divider.bottomAnchor),
      previewNavigation.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      previewNavigation.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      previewNavigation.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    previewNavigation.didMove(toParent: self)
  }
  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !reloadedAfterAttachment else { return }
    reloadedAfterAttachment = true
    // QuickLook now has a navigation context and a window. Reload the public
    // data source after containment/appearance, rather than during construction.
    preview.reloadData()
  }
}
