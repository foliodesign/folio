import UIKit

/// UIKit may forward presentation from a child to its containing controller.
/// Resolve that controller before committing queue state, and use the same window
/// for the popover anchor. No WebKit structure or private API is involved.
@MainActor
enum B3DownloadsPresentation {
  /// A request with no UIKit relationship yet is pending, not detached.
  /// Completion is a terminal acknowledgement; without it, observe attachment
  /// before accepting detachment. Never use elapsed time as a rejection signal.
  @MainActor
  struct Attachment {
    var observed = false
    var attached = false
    var completed = false

    mutating func observe(_ controller: UIViewController) {
      attached =
        attached
        || (controller.presentingViewController != nil && controller.viewIfLoaded?.window != nil)
      observed =
        observed || controller.presentingViewController != nil
        || controller.viewIfLoaded?.window != nil || controller.isBeingPresented
    }

    mutating func resolved(_ controller: UIViewController) -> Bool {
      observe(controller)
      return attachedAndSettled(controller)
        || ((observed || completed) && detached(controller))
    }
  }

  #if DEBUG
    private struct PendingAttachment {
      weak var controller: UIViewController?
      weak var window: UIWindow?
    }
    private static var pendingAttachments: [ObjectIdentifier: PendingAttachment] = [:]

    static func requested(_ controller: UIViewController, from host: UIViewController) {
      pendingAttachments[ObjectIdentifier(controller)] = PendingAttachment(
        controller: controller, window: host.viewIfLoaded?.window)
    }

    static func resolved(_ controller: UIViewController) {
      pendingAttachments.removeValue(forKey: ObjectIdentifier(controller))
    }

    // Native fixture teardown must also wait for requests whose UIKit modal
    // relationship does not exist yet. Weak entries never own a test or window.
    static func hasPendingAttachment(in window: UIWindow) -> Bool {
      pendingAttachments = pendingAttachments.filter { $0.value.controller != nil }
      return pendingAttachments.values.contains { $0.window === window }
    }
  #endif

  static func containmentIDs(_ source: UIViewController?) -> [ObjectIdentifier] {
    var result: [ObjectIdentifier] = []
    var candidate = source
    while let controller = candidate {
      result.append(ObjectIdentifier(controller))
      candidate = controller.parent
    }
    return result
  }

  static func host(for source: UIViewController) -> UIViewController? {
    guard let window = source.viewIfLoaded?.window else { return nil }
    var host = source
    while let parent = host.parent { host = parent }
    var candidate: UIViewController? = source
    while let controller = candidate {
      guard controller.presentedViewController == nil,
        !controller.isBeingPresented, !controller.isBeingDismissed,
        controller.transitionCoordinator == nil
      else { return nil }
      candidate = controller.parent
    }
    guard host.viewIfLoaded?.window === window else { return nil }
    host.view.layoutIfNeeded()
    // Layout can deliver appearance/containment callbacks. Recheck the chain
    // after those callbacks before committing a system presentation.
    candidate = source
    while let controller = candidate {
      guard controller.viewIfLoaded?.window === window,
        controller.presentedViewController == nil,
        !controller.isBeingPresented, !controller.isBeingDismissed,
        controller.transitionCoordinator == nil
      else { return nil }
      candidate = controller.parent
    }
    guard !host.view.bounds.isEmpty, !source.view.bounds.isEmpty else { return nil }
    return host
  }

  static func anchor(_ controller: UIViewController, to host: UIViewController) {
    controller.popoverPresentationController?.sourceView = host.view
    controller.popoverPresentationController?.sourceRect = CGRect(
      x: host.view.bounds.midX, y: host.view.bounds.midY, width: 1, height: 1)
  }

  static func attachedAndSettled(_ controller: UIViewController) -> Bool {
    guard let host = controller.presentingViewController,
      host.presentedViewController === controller,
      controller.viewIfLoaded?.window != nil,
      !controller.isBeingPresented, !controller.isBeingDismissed,
      controller.transitionCoordinator == nil,
      !host.isBeingPresented, !host.isBeingDismissed, host.transitionCoordinator == nil
    else { return false }
    return true
  }

  static func detached(_ controller: UIViewController) -> Bool {
    controller.presentingViewController == nil && controller.viewIfLoaded?.window == nil
      && !controller.isBeingPresented && !controller.isBeingDismissed
      && controller.transitionCoordinator == nil
  }

  static func dismiss(_ controller: UIViewController, completion: @escaping () -> Void) {
    // Do not invoke dismiss while UIKit is attaching a system controller, or on
    // an already detached controller which could own a different successor.
    guard controller.presentingViewController != nil,
      !controller.isBeingPresented, !controller.isBeingDismissed,
      controller.transitionCoordinator == nil
    else { return }
    controller.dismiss(animated: false, completion: completion)
  }

  #if DEBUG
    static func state(_ source: UIViewController?) -> String {
      var result: [String] = []
      var candidate = source
      while let controller = candidate {
        result.append(
          "\(type(of: controller)) window=\(controller.viewIfLoaded?.window != nil)"
            + " modal=\(controller.presentedViewController.map { String(describing: type(of: $0)) } ?? "nil")"
            + " presenting=\(controller.isBeingPresented) dismissing=\(controller.isBeingDismissed)"
            + " transition=\(controller.transitionCoordinator != nil)")
        candidate = controller.parent
      }
      return result.joined(separator: " / ")
    }
  #endif
}
