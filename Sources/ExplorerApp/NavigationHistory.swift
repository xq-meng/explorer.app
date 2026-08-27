import Foundation

enum NavigationOrigin {
    case newLocation
    case back
    case forward
    case refresh
}

struct NavigationHistory {
    private(set) var back: [URL] = []
    private(set) var forward: [URL] = []

    var previous: URL? { back.last }
    var next: URL? { forward.last }

    mutating func commit(origin: NavigationOrigin, current: URL?, destination: URL) -> Bool {
        switch origin {
        case .newLocation:
            if let current, current != destination {
                back.append(current)
                forward.removeAll()
            }
        case .back:
            guard back.last == destination else { return false }
            back.removeLast()
            if let current { forward.append(current) }
        case .forward:
            guard forward.last == destination else { return false }
            forward.removeLast()
            if let current { back.append(current) }
        case .refresh:
            break
        }
        return true
    }
}
