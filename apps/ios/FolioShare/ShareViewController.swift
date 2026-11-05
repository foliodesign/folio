import UIKit
import UniformTypeIdentifiers

@MainActor
final class ShareViewController: UIViewController {
  private let message = UILabel()
  private let save = UIButton(type: .system)
  private var link: URL?

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    message.text = "Checking shared link…"
    message.numberOfLines = 0
    save.setTitle("Save link for Folio", for: .normal)
    save.isEnabled = false
    save.addAction(UIAction { [weak self] _ in self?.saveLink() }, for: .touchUpInside)
    let close = UIButton(type: .system)
    close.setTitle("Done", for: .normal)
    close.addAction(
      UIAction { [weak self] _ in
        self?.extensionContext?.completeRequest(returningItems: nil)
      }, for: .touchUpInside)
    let stack = UIStackView(arrangedSubviews: [message, save, close])
    stack.axis = .vertical
    stack.spacing = 20
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
      stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
    ])
    Task { await readLink() }
  }

  private func readLink() async {
    let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
    let providers = items.flatMap { $0.attachments ?? [] }.filter {
      $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
    }
    guard providers.count == 1 else {
      message.text = "Share one HTTPS figma.com link."
      return
    }
    let url: URL? = await withCheckedContinuation { continuation in
      providers[0].loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
        let url = (item as? URL) ?? (item as? String).flatMap(URL.init(string:))
        continuation.resume(returning: url)
      }
    }
    link = url.flatMap(FolioLink.validated)
    message.text =
      link == nil
      ? "Only HTTPS figma.com links are accepted." : "Save this link, then open Folio to continue."
    save.isEnabled = link != nil
  }

  private func saveLink() {
    guard let link, SharedLinkInbox.shared?.save(link) == true else {
      message.text = "Could not save the link. Open Folio and try again."
      return
    }
    save.isEnabled = false
    message.text = "Link saved. Tap Done, then open Folio to continue."
  }
}
