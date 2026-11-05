import QuickLook
import QuickLookThumbnailing
import UIKit
import UniformTypeIdentifiers

/// One export on a fixed grid: 32 pt tile, name over one detail line, trailing actions.
@MainActor
final class DownloadRowCell: UITableViewCell {
  static let reuse = "folioDownloadRow"
  typealias Palette = DeveloperToolsController.Palette
  static let inset: CGFloat = 16
  static let tileSize: CGFloat = 32
  /// Leading edge of the name and detail lines.
  static let textInset = inset + tileSize + 12
  private(set) var itemID: UUID?
  private let fill = UIView()
  private let tile = UIView()
  private let thumbnail = UIImageView()
  private let symbol = UIImageView()
  private let name = UILabel()
  private let detail = UILabel()
  private let progress = UIProgressView(progressViewStyle: .bar)
  private let actions = UIStackView()
  private var status: DownloadCenterCatalog.Status = .completed
  private var hovering = false
  var detailText: String? { detail.text }

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    backgroundColor = .clear
    selectionStyle = .none
    fill.layer.cornerRadius = 6
    contentView.addSubview(fill)
    addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hover(_:))))

    tile.backgroundColor = Palette.well
    tile.layer.cornerRadius = 5
    tile.layer.borderWidth = 1
    tile.layer.borderColor = Palette.border.cgColor
    tile.clipsToBounds = true
    thumbnail.contentMode = .scaleAspectFit
    symbol.contentMode = .center
    for view in [thumbnail, symbol] {
      view.translatesAutoresizingMaskIntoConstraints = false
      tile.addSubview(view)
      let pad: CGFloat = view === thumbnail ? 2 : 0
      NSLayoutConstraint.activate([
        view.topAnchor.constraint(equalTo: tile.topAnchor, constant: pad),
        view.bottomAnchor.constraint(equalTo: tile.bottomAnchor, constant: -pad),
        view.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: pad),
        view.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -pad),
      ])
    }

    name.font = DeveloperToolsController.font(12, .medium)
    name.textColor = Palette.text
    name.lineBreakMode = .byTruncatingMiddle
    detail.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    detail.lineBreakMode = .byTruncatingTail
    progress.progressTintColor = Palette.accent
    progress.trackTintColor = Palette.border
    progress.layer.cornerRadius = 1.5
    progress.clipsToBounds = true
    progress.heightAnchor.constraint(equalToConstant: 3).isActive = true

    let text = UIStackView(arrangedSubviews: [name, detail, progress])
    text.axis = .vertical
    text.spacing = 3
    text.setCustomSpacing(6, after: detail)
    actions.spacing = 2
    actions.alignment = .center
    for view in [tile, text, actions] {
      view.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(view)
    }
    text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    actions.setContentHuggingPriority(.required, for: .horizontal)
    actions.setContentCompressionResistancePriority(.required, for: .horizontal)
    NSLayoutConstraint.activate([
      tile.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Self.inset),
      tile.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      tile.widthAnchor.constraint(equalToConstant: Self.tileSize),
      tile.heightAnchor.constraint(equalToConstant: Self.tileSize),
      text.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Self.textInset),
      text.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      text.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -12),
      actions.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
      actions.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
    ])
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func layoutSubviews() {
    super.layoutSubviews()
    fill.frame = contentView.bounds.insetBy(dx: 6, dy: 2)
  }

  override func setHighlighted(_ highlighted: Bool, animated: Bool) {
    super.setHighlighted(highlighted, animated: animated)
    updateFill()
  }
  @objc private func hover(_ recognizer: UIHoverGestureRecognizer) {
    hovering = recognizer.state == .began || recognizer.state == .changed
    updateFill()
  }
  private func updateFill() {
    let pressed = isHighlighted && status == .completed
    fill.backgroundColor = pressed ? Palette.border : hovering ? Palette.hover : .clear
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    hovering = false
    updateFill()
  }

  func configure(
    item: DownloadCenterCatalog.Item, source title: String?, progress fraction: Double?,
    thumbnail image: UIImage?, buttons: [UIView]
  ) {
    itemID = item.id
    status = item.status
    name.text = item.basename
    let ext = (item.basename as NSString).pathExtension.uppercased()
    let kind = ext.isEmpty ? "File" : ext
    let time = Self.time(item.updated)
    let from = title.map { " · From \($0)" } ?? ""
    switch item.status {
    case .transferring:
      detail.textColor = Palette.secondary
    case .completed:
      let size = ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
      detail.text = "\(kind) · \(size) · \(time)\(from)"
      detail.textColor = Palette.secondary
    case .failed:
      detail.text = "Failed · \(time)\(from)"
      detail.textColor = Palette.danger
    case .cancelled:
      detail.text = "Cancelled · \(time)\(from)"
      detail.textColor = Palette.tertiary
    }
    progress.isHidden = item.status != .transferring
    showProgress(fraction)
    symbol.image = UIImage(
      systemName: Self.symbol(for: item),
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .regular))
    symbol.tintColor =
      switch item.status {
      case .transferring: Palette.accent
      case .failed: Palette.danger
      case .cancelled: Palette.tertiary
      case .completed: Palette.secondary
      }
    setThumbnail(item.status == .completed ? image : nil)
    for view in actions.arrangedSubviews { view.removeFromSuperview() }
    for button in buttons { actions.addArrangedSubview(button) }
    if let first = buttons.first, buttons.count > 1 { actions.setCustomSpacing(8, after: first) }
    updateFill()
    accessibilityLabel = [item.basename, detail.text].compactMap { $0 }.joined(separator: ", ")
  }

  func showProgress(_ fraction: Double?) {
    guard status == .transferring else { return }
    if let fraction {
      detail.text = "Downloading… \(Int((fraction * 100).rounded()))%"
      progress.setProgress(Float(fraction), animated: true)
    } else {
      detail.text = "Downloading…"
      progress.setProgress(0, animated: false)
    }
  }

  func setThumbnail(_ image: UIImage?) {
    thumbnail.image = image
    thumbnail.isHidden = image == nil
    symbol.isHidden = image != nil
  }

  private static func time(_ date: Date) -> String {
    Calendar.current.isDateInToday(date)
      ? date.formatted(date: .omitted, time: .shortened)
      : date.formatted(date: .abbreviated, time: .shortened)
  }

  private static func symbol(for item: DownloadCenterCatalog.Item) -> String {
    switch item.status {
    case .transferring: return "arrow.down"
    case .failed: return "exclamationmark.triangle"
    case .cancelled: return "xmark"
    case .completed: break
    }
    guard let type = UTType(item.type) else { return "doc" }
    if type.conforms(to: .image) { return "photo" }
    if type.conforms(to: .pdf) { return "doc.richtext" }
    if type.conforms(to: .audiovisualContent) { return "film" }
    if type.conforms(to: .archive) { return "doc.zipper" }
    if type.conforms(to: .text) || type.conforms(to: .json) { return "doc.text" }
    return "doc"
  }
}
