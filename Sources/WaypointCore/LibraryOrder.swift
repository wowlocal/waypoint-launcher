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
