import Foundation

/// The order the person dragged the library's games into. Keyed by the
/// game (its uid), not the install, so HotS keeps its place across editions.
public enum LibraryOrder {
    /// `items` in `order`. Those it doesn't name (a game installed since)
    /// come after, in the order they came in.
    public static func sorted<T>(_ items: [T], by order: [String], id: (T) -> String) -> [T] {
        let place = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return items.enumerated().sorted { a, b in
            switch (place[id(a.element)], place[id(b.element)]) {
            case let (x?, y?): x != y ? x < y : a.offset < b.offset
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): a.offset < b.offset
            }
        }.map(\.element)
    }

    /// Where a game picked up from row `from` goes once it has been carried
    /// `carried` points down the list (negative: up): the row it would be
    /// dropped before, `from` while it stays, the rows' count for the end.
    /// It passes a row once it covers half of it, so it takes the place
    /// nearest to where it is held. `heights`: the rows' heights; its own
    /// doesn't count.
    public static func landing(from: Int, carried: Double, heights: [Double]) -> Int {
        var row = from, passed = 0.0
        if carried > 0 {
            while row + 1 < heights.count, carried >= passed + heights[row + 1] / 2 {
                row += 1
                passed += heights[row]
            }
            return row == from ? from : row + 1
        }
        while row > 0, -carried >= passed + heights[row - 1] / 2 {
            row -= 1
            passed += heights[row]
        }
        return row
    }

    /// The order after `moved` is dropped before `target` (nil: at the end)
    /// in the list `shown`. Games remembered but not shown (on a drive not
    /// read yet, say) keep their places: each stays after the shown game it
    /// followed before.
    public static func moving(_ moved: String, before target: String?, in shown: [String], remembered: [String]) -> [String] {
        var ids = shown
        if let from = ids.firstIndex(of: moved), moved != target {
            ids.remove(at: from)
            ids.insert(moved, at: target.flatMap { ids.firstIndex(of: $0) } ?? ids.count)
        }
        let visible = Set(shown)
        // The game dragged isn't an anchor: what followed it stays put.
        var anchor: String?, leading = 0, attached: [String: Int] = [:]
        for id in remembered {
            if visible.contains(id) {
                if id != moved { anchor = id }
                continue
            }
            guard !ids.contains(id) else { continue }
            if let anchor, let place = ids.firstIndex(of: anchor) {
                ids.insert(id, at: place + 1 + attached[anchor, default: 0])
                attached[anchor, default: 0] += 1
            } else {
                ids.insert(id, at: leading)
                leading += 1
            }
        }
        return ids
    }
}
