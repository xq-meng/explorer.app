import AppKit
import ExplorerUI

@MainActor
final class ExplorerWindowContentViewController: NSViewController {
    var onCancelOperation: (() -> Void)?

    let browserController: ExplorerTabController

    private let activityView = BrowserOperationActivityView()
    private var activityHeightConstraint: NSLayoutConstraint?

    init(browserController: ExplorerTabController) {
        self.browserController = browserController
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true

        addChild(browserController)
        let browserView = browserController.view
        browserView.translatesAutoresizingMaskIntoConstraints = false
        activityView.translatesAutoresizingMaskIntoConstraints = false
        activityView.onCancel = { [weak self] in self?.onCancelOperation?() }

        view.addSubview(browserView)
        view.addSubview(activityView)

        let activityHeight = activityView.heightAnchor.constraint(equalToConstant: 0)
        activityHeightConstraint = activityHeight
        NSLayoutConstraint.activate([
            browserView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            browserView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            browserView.topAnchor.constraint(equalTo: view.topAnchor),
            browserView.bottomAnchor.constraint(equalTo: activityView.topAnchor),
            activityView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            activityView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            activityView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            activityHeight,
        ])
    }

    func setOperationActivity(_ activity: BrowserOperationActivity?) {
        loadViewIfNeeded()
        activityView.display(activity)
        activityHeightConstraint?.constant = activity == nil ? 0 : 56
    }
}
