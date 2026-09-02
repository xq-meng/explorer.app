import AppKit

/// A window-level navigation sidebar that can route locations to whichever
/// browser pane the host considers active.
@MainActor
public final class BrowserNavigationSidebarViewController: NSViewController {
    public var onAction: ((BrowserAction) -> Void)?
    public var viewState = BrowserViewState.empty {
        didSet { sidebarController.viewState = viewState }
    }

    private let sidebarController = BrowserSidebarController()

    public override func loadView() {
        let container = NSVisualEffectView()
        container.material = .sidebar
        container.blendingMode = .withinWindow
        container.state = .active

        sidebarController.viewState = viewState
        sidebarController.onAction = { [weak self] action in
            self?.onAction?(action)
        }

        let scrollView = NSScrollView()
        scrollView.documentView = sidebarController.outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -3),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
        ])
        view = container
    }

    public func display(_ locations: [BrowserSidebarLocation]) {
        sidebarController.displayRoots(locations)
    }

    public func select(_ location: BrowserLocation?) {
        sidebarController.select(location)
    }
}
