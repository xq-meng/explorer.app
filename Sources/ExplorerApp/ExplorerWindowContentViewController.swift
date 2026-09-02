import AppKit
import ExplorerUI

@MainActor
final class ExplorerWindowContentViewController: NSViewController {
    var onCancelOperation: (() -> Void)?
    var onSidebarWidthChange: ((CGFloat) -> Void)?
    var onSidebarAction: ((BrowserAction) -> Void)?

    private(set) var paneControllers: [ExplorerTabController]

    private let activityView = BrowserOperationActivityView()
    private let workspaceSplitView = NSSplitView()
    private let paneSplitView = NSSplitView()
    private let sidebarController = BrowserNavigationSidebarViewController()
    private var activityHeightConstraint: NSLayoutConstraint?
    private var requestedSidebarWidth: CGFloat
    private var isApplyingSidebarWidth = false
    private var canReportSidebarWidth = false

    init(
        browserController: ExplorerTabController,
        sidebarLocations: [BrowserSidebarLocation],
        sidebarWidth: CGFloat?
    ) {
        paneControllers = [browserController]
        requestedSidebarWidth = min(300, max(148, sidebarWidth ?? 176))
        super.init(nibName: nil, bundle: nil)
        sidebarController.display(sidebarLocations)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true

        workspaceSplitView.isVertical = true
        workspaceSplitView.dividerStyle = .thin
        workspaceSplitView.delegate = self
        workspaceSplitView.translatesAutoresizingMaskIntoConstraints = false
        paneSplitView.isVertical = true
        paneSplitView.dividerStyle = .thin
        paneSplitView.delegate = self
        paneSplitView.translatesAutoresizingMaskIntoConstraints = false
        activityView.translatesAutoresizingMaskIntoConstraints = false
        activityView.onCancel = { [weak self] in self?.onCancelOperation?() }

        addChild(sidebarController)
        sidebarController.onAction = { [weak self] action in self?.onSidebarAction?(action) }
        let sidebarView = sidebarController.view
        sidebarView.translatesAutoresizingMaskIntoConstraints = true
        workspaceSplitView.addArrangedSubview(sidebarView)
        workspaceSplitView.addArrangedSubview(paneSplitView)

        view.addSubview(workspaceSplitView)
        view.addSubview(activityView)
        installPaneControllers(paneControllers)

        let activityHeight = activityView.heightAnchor.constraint(equalToConstant: 0)
        activityHeightConstraint = activityHeight
        NSLayoutConstraint.activate([
            workspaceSplitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            workspaceSplitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            workspaceSplitView.topAnchor.constraint(equalTo: view.topAnchor),
            workspaceSplitView.bottomAnchor.constraint(equalTo: activityView.topAnchor),
            activityView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            activityView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            activityView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            activityHeight,
        ])
        applySidebarPosition()
        DispatchQueue.main.async { [weak self] in
            self?.applySidebarPosition()
            self?.canReportSidebarWidth = true
        }
    }

    func setOperationActivity(_ activity: BrowserOperationActivity?) {
        loadViewIfNeeded()
        activityView.display(activity)
        activityHeightConstraint?.constant = activity == nil ? 0 : 56
    }

    var paneCount: Int { paneControllers.count }
    var hasSharedSidebar: Bool { sidebarController.parent === self }

    func displaySidebarLocations(_ locations: [BrowserSidebarLocation]) {
        sidebarController.display(locations)
    }

    func setSidebarViewState(_ state: BrowserViewState) {
        sidebarController.viewState = state
    }

    func selectSidebarLocation(_ location: BrowserLocation?) {
        sidebarController.select(location)
    }

    func showSinglePane(_ controller: ExplorerTabController) {
        loadViewIfNeeded()
        installPaneControllers([controller])
    }

    func showSplitPane(
        primary: ExplorerTabController,
        secondary: ExplorerTabController
    ) {
        loadViewIfNeeded()
        installPaneControllers([primary, secondary])
        applyEqualPaneWidths()
        DispatchQueue.main.async { [weak self] in
            self?.applyEqualPaneWidths()
        }
    }

    private func installPaneControllers(_ controllers: [ExplorerTabController]) {
        let removedControllers = paneControllers.filter { existing in
            !controllers.contains { $0 === existing }
        }
        for arrangedSubview in paneSplitView.arrangedSubviews {
            paneSplitView.removeArrangedSubview(arrangedSubview)
            arrangedSubview.removeFromSuperview()
        }
        for controller in removedControllers {
            controller.removeFromParent()
        }

        paneControllers = controllers
        for controller in controllers {
            if controller.parent !== self { addChild(controller) }
            let paneView = controller.view
            paneView.translatesAutoresizingMaskIntoConstraints = true
            paneSplitView.addArrangedSubview(paneView)
        }
        paneSplitView.adjustSubviews()
    }

    private func applyEqualPaneWidths() {
        guard paneControllers.count == 2, paneSplitView.bounds.width > 0 else { return }
        let availableWidth = paneSplitView.bounds.width - paneSplitView.dividerThickness
        paneSplitView.setPosition(
            floor(availableWidth / 2),
            ofDividerAt: 0
        )
    }

    private func applySidebarPosition() {
        guard workspaceSplitView.bounds.width > 0 else { return }
        isApplyingSidebarWidth = true
        workspaceSplitView.setPosition(requestedSidebarWidth, ofDividerAt: 0)
        isApplyingSidebarWidth = false
    }
}

extension ExplorerWindowContentViewController: NSSplitViewDelegate {
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard let splitView = notification.object as? NSSplitView else { return }
        if splitView === workspaceSplitView {
            guard canReportSidebarWidth, !isApplyingSidebarWidth,
                  let sidebar = workspaceSplitView.subviews.first else { return }
            requestedSidebarWidth = min(300, max(148, sidebar.frame.width))
            onSidebarWidthChange?(requestedSidebarWidth)
        }
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard dividerIndex == 0 else { return proposedMinimumPosition }
        if splitView === workspaceSplitView {
            return max(proposedMinimumPosition, 148)
        }
        if splitView === paneSplitView {
            return max(proposedMinimumPosition, 320)
        }
        return proposedMinimumPosition
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard dividerIndex == 0 else { return proposedMaximumPosition }
        if splitView === workspaceSplitView {
            return min(proposedMaximumPosition, 300)
        }
        if splitView === paneSplitView {
            return min(proposedMaximumPosition, max(320, splitView.bounds.width - 320))
        }
        return proposedMaximumPosition
    }

    func splitView(
        _ splitView: NSSplitView,
        shouldAdjustSizeOfSubview view: NSView
    ) -> Bool {
        guard splitView === workspaceSplitView,
              let sidebar = workspaceSplitView.subviews.first else { return true }
        return view !== sidebar
    }
}
