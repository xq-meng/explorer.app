import ExplorerBrowsing
import ExplorerCore
import ExplorerUI
import Foundation

@MainActor
final class ExplorerTabNavigationCoordinator {
    weak var presenter: ExplorerTabNavigationPresenting?

    private(set) var currentLocation: BrowserLocation?
    var currentDirectoryURL: URL? { currentLocation?.directoryURL }
    var isShowingComputer: Bool { currentLocation == .computer }
    var isLoadingDirectory: Bool { loadTask != nil }
    var backHistory: [BrowserLocation] { history.back }
    var forwardHistory: [BrowserLocation] { history.forward }

    private let loader = DirectoryLoader()
    private var history = NavigationHistory<BrowserLocation>()
    private var loadTask: Task<Void, Never>?
    private var loadGeneration: UInt = 0
    private var directoryMonitor: DirectoryChangeMonitor?
    private var monitorTask: Task<Void, Never>?
    private var monitorGeneration: UInt = 0

    deinit {
        loadTask?.cancel()
        monitorTask?.cancel()
    }

    func cancelAll() {
        loadGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        stopMonitoring()
    }

    func perform(_ command: BrowserNavigationCommand) {
        guard let presenter else { return }
        switch command {
        case .back:
            guard let previous = history.previous else {
                presenter.showStatus("No earlier folder in history.")
                return
            }
            request(previous, origin: .back)
        case .forward:
            guard let next = history.next else {
                presenter.showStatus("No later folder in history.")
                return
            }
            request(next, origin: .forward)
        case .up:
            guard let currentLocation else {
                request(.computer, origin: .newLocation)
                return
            }
            guard let parent = ExplorerTabNavigation.parent(of: currentLocation) else {
                presenter.showStatus("Already at My Computer.")
                return
            }
            request(parent, origin: .newLocation)
        case .refresh:
            if isShowingComputer {
                presenter.requestHomePageRefresh()
                showComputer(origin: .refresh)
                return
            }
            request(currentLocation ?? .computer, origin: .refresh)
        }
    }

    func restore(
        location: BrowserLocation,
        backHistory: [BrowserLocation],
        forwardHistory: [BrowserLocation]
    ) {
        cancelAll()
        history = NavigationHistory(back: backHistory, forward: forwardHistory)
        currentLocation = location
        request(location, origin: .refresh)
    }

    func request(_ location: BrowserLocation, origin: NavigationOrigin) {
        switch location {
        case .computer:
            showComputer(origin: origin)
        case let .directory(url):
            requestDirectory(url, origin: origin)
        }
    }

    func url(forSubmittedPath path: String, homeURL: URL) -> URL {
        if let url = URL(string: path), url.isFileURL { return url.standardizedFileURL }
        let expandedPath = (path as NSString).expandingTildeInPath
        return expandedPath.hasPrefix("/")
            ? URL(fileURLWithPath: expandedPath).standardizedFileURL
            : homeURL.appendingPathComponent(expandedPath).standardizedFileURL
    }

    private func requestDirectory(_ url: URL, origin: NavigationOrigin) {
        guard let presenter else { return }
        let destination = url.standardizedFileURL
        loadGeneration &+= 1
        let generation = loadGeneration
        loadTask?.cancel()
        if origin != .refresh { stopMonitoring() }
        presenter.prepareToNavigate(leavingHome: isShowingComputer, loading: .directory(destination))
        let loader = loader
        let options = DirectoryLoadOptions(
            showsHiddenFiles: presenter.showsHiddenFiles,
            sortDescriptor: presenter.directorySortDescriptor
        )
        loadTask = Task { [weak self] in
            do {
                let snapshot = try await loader.load(destination, options: options)
                guard !Task.isCancelled, let self, generation == self.loadGeneration else { return }
                self.apply(snapshot, destination: destination, origin: origin)
            } catch is CancellationError {
            } catch FileProviderError.cancelled {
            } catch {
                guard !Task.isCancelled, let self, generation == self.loadGeneration else { return }
                self.presenter?.presentNavigationFailure(
                    error.localizedDescription,
                    restoreHomePage: self.isShowingComputer
                )
                if !self.isShowingComputer, let currentDirectoryURL = self.currentDirectoryURL {
                    self.startMonitoring(currentDirectoryURL)
                }
            }
        }
    }

    private func apply(_ snapshot: DirectorySnapshot, destination: URL, origin: NavigationOrigin) {
        guard let presenter else { return }
        guard history.commit(
            origin: origin,
            current: currentLocation,
            destination: .directory(destination)
        ) else { return }
        currentLocation = .directory(snapshot.directoryURL)
        let overlay = ICloudDriveLibraries.overlayItems(
            at: snapshot.directoryURL,
            showsHiddenFiles: presenter.showsHiddenFiles
        )
        presenter.presentDirectory(snapshot, overlay: overlay, at: .directory(snapshot.directoryURL))
        if origin != .refresh || directoryMonitor == nil {
            startMonitoring(snapshot.directoryURL)
        }
    }

    private func showComputer(origin: NavigationOrigin) {
        guard let presenter else { return }
        loadGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        stopMonitoring()
        presenter.prepareToNavigate(leavingHome: false, loading: nil)
        guard history.commit(
            origin: origin,
            current: currentLocation,
            destination: .computer
        ) else { return }
        currentLocation = .computer
        presenter.presentComputer()
    }

    private func startMonitoring(_ directoryURL: URL) {
        stopMonitoring()
        monitorGeneration &+= 1
        let generation = monitorGeneration
        let monitoredURL = directoryURL.standardizedFileURL
        let monitor = DirectoryChangeMonitor()
        directoryMonitor = monitor
        monitorTask = Task { [weak self] in
            do {
                let invalidations = try await monitor.invalidations(at: monitoredURL)
                for await invalidation in invalidations {
                    guard !Task.isCancelled, let self,
                          generation == self.monitorGeneration,
                          self.currentDirectoryURL == invalidation.directoryURL else { return }
                    try await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled, generation == self.monitorGeneration,
                          self.currentDirectoryURL == invalidation.directoryURL else { return }
                    self.request(.directory(invalidation.directoryURL), origin: .refresh)
                }
            } catch is CancellationError {
            } catch {
                // Monitoring is an enhancement; browsing remains usable when a
                // provider cannot watch a particular directory.
            }
        }
    }

    private func stopMonitoring() {
        monitorGeneration &+= 1
        monitorTask?.cancel()
        monitorTask = nil
        let monitor = directoryMonitor
        directoryMonitor = nil
        if let monitor { Task { await monitor.stop() } }
    }
}
