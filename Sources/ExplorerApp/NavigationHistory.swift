import Foundation

enum NavigationOrigin {
    case newLocation
    case back
    case forward
    case refresh
}

struct NavigationHistory<Location: Equatable> {
    private(set) var back: [Location] = []
    private(set) var forward: [Location] = []

    var previous: Location? { back.last }
    var next: Location? { forward.last }

    mutating func commit(origin: NavigationOrigin, current: Location?, destination: Location) -> Bool {
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
