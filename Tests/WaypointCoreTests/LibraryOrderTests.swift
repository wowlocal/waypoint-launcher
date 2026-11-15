import Testing
@testable import WaypointCore

@Test func gamesFollowTheDraggedOrderAndNewOnesComeAfterInTheirOwnOrder() {
    let found = ["wow", "hs", "d4", "sc2", "new1", "new2"]
    #expect(LibraryOrder.sorted(found, by: [], id: { $0 }) == found)
    #expect(LibraryOrder.sorted(found, by: ["d4", "wow", "gone", "sc2", "hs"], id: { $0 })
            == ["d4", "wow", "sc2", "hs", "new1", "new2"])
}

@Test func movingAGamePutsItBeforeItsTargetOrLast() {
    let shown = ["wow", "hs", "d4", "sc2"]
    #expect(LibraryOrder.moving("sc2", before: "wow", in: shown, remembered: []) == ["sc2", "wow", "hs", "d4"])
    #expect(LibraryOrder.moving("wow", before: "d4", in: shown, remembered: []) == ["hs", "wow", "d4", "sc2"])
    #expect(LibraryOrder.moving("wow", before: nil, in: shown, remembered: []) == ["hs", "d4", "sc2", "wow"])
    // Dropped where it already is.
    #expect(LibraryOrder.moving("hs", before: "hs", in: shown, remembered: []) == shown)
    #expect(LibraryOrder.moving("hs", before: "d4", in: shown, remembered: []) == shown)
}

@Test func gamesNotShownKeepTheirRememberedPlaceAfterAMove() {
    let order = LibraryOrder.moving("hs", before: "wow", in: ["wow", "hs"], remembered: ["wow", "offline", "hs"])
    #expect(order == ["hs", "wow", "offline"])
    #expect(LibraryOrder.sorted(["wow", "offline", "hs"], by: order, id: { $0 }) == ["hs", "wow", "offline"])
}

@Test func unreadGamesStayBetweenTheGamesTheyFollowedAndDontTravelWithTheDraggedOne() {
    // x and y are on a drive not read yet.
    let remembered = ["a", "x", "b", "c", "y"]
    #expect(LibraryOrder.moving("c", before: "a", in: ["a", "b", "c"], remembered: remembered) == ["c", "a", "x", "b", "y"])
    #expect(LibraryOrder.moving("a", before: nil, in: ["a", "b", "c"], remembered: remembered) == ["x", "b", "c", "y", "a"])
}

@Test func bothHeroesEditionsShareOnePlace() {
    struct Game { let id, uid: String }
    let games = [Game(id: "wow", uid: "wow"), Game(id: "heroes@windows", uid: "heroes")]
    #expect(LibraryOrder.sorted(games, by: ["heroes", "wow"], id: \.uid).map(\.id) == ["heroes@windows", "wow"])
}

@Test func aCarriedGameTakesThePlaceNearestToWhereItIsHeld() {
    let heights = [68.0, 68, 68, 68]
    // It stays until it covers half of the next row.
    #expect(LibraryOrder.landing(from: 1, carried: 0, heights: heights) == 1)
    #expect(LibraryOrder.landing(from: 1, carried: 33, heights: heights) == 1)
    #expect(LibraryOrder.landing(from: 1, carried: -33, heights: heights) == 1)
    // Down: before the row after the ones it passed, or at the end.
    #expect(LibraryOrder.landing(from: 1, carried: 34, heights: heights) == 3)
    #expect(LibraryOrder.landing(from: 1, carried: 101, heights: heights) == 3)
    #expect(LibraryOrder.landing(from: 1, carried: 102, heights: heights) == 4)
    #expect(LibraryOrder.landing(from: 1, carried: 5000, heights: heights) == 4)
    // Up: before the first row it passed.
    #expect(LibraryOrder.landing(from: 3, carried: -34, heights: heights) == 2)
    #expect(LibraryOrder.landing(from: 3, carried: -102, heights: heights) == 1)
    #expect(LibraryOrder.landing(from: 3, carried: -5000, heights: heights) == 0)
    // Nowhere to go past the ends.
    #expect(LibraryOrder.landing(from: 0, carried: -50, heights: heights) == 0)
    #expect(LibraryOrder.landing(from: 3, carried: 50, heights: heights) == 3)
}

@Test func aCarriedGamePassesATallRowAtItsMiddleWhateverItsOwnHeight() {
    // Its own height (a row hidden while dragged reports none) doesn't count.
    let heights = [68.0, 0, 100, 68]
    #expect(LibraryOrder.landing(from: 1, carried: 49, heights: heights) == 1)
    #expect(LibraryOrder.landing(from: 1, carried: 50, heights: heights) == 3)
    #expect(LibraryOrder.landing(from: 1, carried: 133, heights: heights) == 3)
    #expect(LibraryOrder.landing(from: 1, carried: 134, heights: heights) == 4)
    // Back up, the tall row is passed at the same place.
    #expect(LibraryOrder.landing(from: 3, carried: -49, heights: [68, 68, 100, 0]) == 3)
    #expect(LibraryOrder.landing(from: 3, carried: -50, heights: [68, 68, 100, 0]) == 2)
}
