import ExplorerCore
import Foundation

public extension Array where Element == FileItem {
    mutating func sort(using descriptor: FileSortDescriptor) {
        sort { lhs, rhs in
            if descriptor.directoriesFirst {
                let lhsDirectory = lhs.kind == .directory || lhs.kind == .package
                let rhsDirectory = rhs.kind == .directory || rhs.kind == .package
                if lhsDirectory != rhsDirectory { return lhsDirectory }
            }
            let result = compareFileItems(lhs, rhs, descriptor: descriptor)
            return descriptor.direction == .ascending ? result < 0 : result > 0
        }
    }

    func sorted(using descriptor: FileSortDescriptor) -> [FileItem] {
        var copy = self
        copy.sort(using: descriptor)
        return copy
    }
}

private func compareFileItems(
    _ lhs: FileItem,
    _ rhs: FileItem,
    descriptor: FileSortDescriptor
) -> Int {
    let primary: Int
    switch descriptor.field {
    case .name:
        primary = comparisonValue(lhs.name.localizedStandardCompare(rhs.name))
    case .kind:
        primary = comparisonValue(lhs.kind.rawValue.localizedStandardCompare(rhs.kind.rawValue))
    case .size:
        primary = compareOptional(lhs.size, rhs.size)
    case .creationDate:
        primary = compareOptional(lhs.creationDate, rhs.creationDate)
    case .modificationDate:
        primary = compareOptional(lhs.modificationDate, rhs.modificationDate)
    }
    if primary != 0 { return primary }

    let nameResult = comparisonValue(lhs.name.localizedStandardCompare(rhs.name))
    if nameResult != 0 { return nameResult }
    return comparisonValue(lhs.url.absoluteString.compare(rhs.url.absoluteString))
}

private func compareOptional<T: Comparable>(_ lhs: T?, _ rhs: T?) -> Int {
    switch (lhs, rhs) {
    case let (lhs?, rhs?):
        if lhs == rhs { return 0 }
        return lhs < rhs ? -1 : 1
    case (nil, nil):
        return 0
    case (nil, _):
        return 1
    case (_, nil):
        return -1
    }
}

private func comparisonValue(_ result: ComparisonResult) -> Int {
    switch result {
    case .orderedAscending: return -1
    case .orderedSame: return 0
    case .orderedDescending: return 1
    }
}
