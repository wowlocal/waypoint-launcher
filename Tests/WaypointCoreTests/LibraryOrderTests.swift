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
