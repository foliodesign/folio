import UIKit

/// Native card shown when a page cannot load, for example while offline. It names the likely
/// cause from the URL error code only (descriptions can contain URLs) and offers Retry.
final class LoadFailureView: UIView {
  struct Message: Equatable {
    let title: String
    let detail: String
  }

  static func message(for error: NSError) -> Message? {
    guard error.domain == NSURLErrorDomain, error.code != NSURLErrorCancelled else { return nil }
    switch error.code {
    case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
      NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff, NSURLErrorCallIsActive:
      return Message(
        title: "You're offline",
        detail: "Folio needs an internet connection to open Figma. Connect, then try again.")
    case NSURLErrorTimedOut:
      return Message(
        title: "Figma is taking too long",
        detail: "The page didn't respond in time. Check your connection, then try again.")
    case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed:
      return Message(
        title: "Can't reach the page",
        detail: "The server couldn't be reached. Check your connection, then try again.")
    case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
      NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateNotYetValid,
      NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorClientCertificateRejected:
      return Message(
        title: "Couldn't connect securely",
        detail:
          "A secure connection to the page failed. Check the network and the iPad's date and time, then try again."
      )
    default:
      return Message(
        title: "The page couldn't load",
        detail: "Something went wrong while loading. Try again in a moment.")
    }
  }

  init(message: Message, retry: @escaping () -> Void) {
    super.init(frame: .zero)
    backgroundColor = ChromePalette.bar
    layer.cornerRadius = 14
    layer.cornerCurve = .continuous
    layer.borderWidth = 1
    layer.borderColor = ChromePalette.divider.cgColor
    layer.shadowColor = UIColor.black.cgColor
    layer.shadowOpacity = 0.18
    layer.shadowRadius = 18
    layer.shadowOffset = CGSize(width: 0, height: 6)

    let icon = UIImageView(
      image: UIImage(
        systemName: "wifi.exclamationmark",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 28, weight: .regular)))
    icon.tintColor = ChromePalette.secondaryText
    icon.contentMode = .scaleAspectFit

    let title = UILabel()
    title.text = message.title
    title.font = .preferredFont(forTextStyle: .headline)
    title.adjustsFontForContentSizeCategory = true
    title.textColor = ChromePalette.primaryText
    title.textAlignment = .center
    title.numberOfLines = 0
    title.accessibilityTraits.insert(.header)

    let detail = UILabel()
    detail.text = message.detail
    detail.font = .preferredFont(forTextStyle: .subheadline)
    detail.adjustsFontForContentSizeCategory = true
    detail.textColor = ChromePalette.secondaryText
    detail.textAlignment = .center
    detail.numberOfLines = 0

    var config = UIButton.Configuration.filled()
    config.title = "Try Again"
    config.baseBackgroundColor = ChromePalette.figmaBlue
    config.baseForegroundColor = .white
    config.cornerStyle = .medium
    config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 18, bottom: 8, trailing: 18)
    let button = UIButton(configuration: config)
    button.addAction(UIAction { _ in retry() }, for: .touchUpInside)

    let stack = UIStackView(arrangedSubviews: [icon, title, detail, button])
    stack.axis = .vertical
    stack.alignment = .center
    stack.spacing = 8
    stack.setCustomSpacing(16, after: detail)
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: topAnchor, constant: 24),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
    ])
    accessibilityViewIsModal = false
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    // CGColor borders don't follow appearance changes on their own.
    layer.borderColor = ChromePalette.divider.cgColor
  }
}
