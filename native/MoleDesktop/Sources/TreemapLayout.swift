import CoreGraphics

struct TreemapLayout<ID: Hashable> {
    typealias Weight = (id: ID, bytes: Int64)

    indirect enum Partition: Equatable {
        case leaf(ID)
        case split(horizontal: Bool, Partition, Partition)

        var ids: Set<ID> {
            switch self {
            case .leaf(let id): return [id]
            case .split(_, let first, let second): return first.ids.union(second.ids)
            }
        }
    }

    let partition: Partition?
    let frames: [ID: CGRect]

    init(_ weights: [Weight], in bounds: CGRect, keeping previous: Partition?) {
        var rectangles = [ID: CGRect]()

        func place(_ items: [Weight], in rect: CGRect, keeping prior: Partition?) -> Partition {
            if items.count == 1 {
                rectangles[items[0].id] = rect
                return .leaf(items[0].id)
            }
            let total = items.reduce(0.0) { $0 + Double($1.bytes) }
            var horizontal = rect.width >= rect.height
            var first = [Weight](), second = [Weight]()
            var firstPlan: Partition?, secondPlan: Partition?
            var firstWeight = 0.0

            if case let .split(axis, left, right) = prior {
                let leftIDs = left.ids, rightIDs = right.ids
                var newcomers = [Weight]()
                var secondWeight = 0.0
                for item in items {
                    if leftIDs.contains(item.id) { first.append(item); firstWeight += Double(item.bytes) }
                    else if rightIDs.contains(item.id) { second.append(item); secondWeight += Double(item.bytes) }
                    else { newcomers.append(item) }
                }
                if first.count + second.count > 0 {
                    horizontal = axis
                    firstPlan = left
                    secondPlan = right
                    for item in newcomers {
                        if firstWeight <= secondWeight { first.append(item); firstWeight += Double(item.bytes) }
                        else { second.append(item); secondWeight += Double(item.bytes) }
                    }
                    if first.isEmpty { return place(second, in: rect, keeping: right) }
                    if second.isEmpty { return place(first, in: rect, keeping: left) }
                }
            }

            if first.isEmpty {
                var cut = 1
                firstWeight = Double(items[0].bytes)
                while cut < items.count - 1 {
                    let next = firstWeight + Double(items[cut].bytes)
                    if abs(total / 2 - firstWeight) <= abs(total / 2 - next) { break }
                    firstWeight = next
                    cut += 1
                }
                first = Array(items[..<cut])
                second = Array(items[cut...])
            }
            let distance = (horizontal ? rect.width : rect.height) * (firstWeight / total)
            let (leading, trailing) = rect.divided(atDistance: distance, from: horizontal ? .minXEdge : .minYEdge)
            return .split(horizontal: horizontal, place(first, in: leading, keeping: firstPlan),
                          place(second, in: trailing, keeping: secondPlan))
        }

        partition = weights.isEmpty ? nil : place(weights, in: bounds, keeping: previous)
        frames = rectangles
    }
}
