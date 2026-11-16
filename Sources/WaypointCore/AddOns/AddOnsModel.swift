import Foundation
import Observation

/// The add-ons of each WoW version: what the sheet shows, and the
/// automatic updates that keep current the add-ons Waypoint installed or
/// updated. All the disk and network work happens in each folder's
/// `AddOnLibrary`; every piece of work is tracked so quitting waits for it.
@MainActor
@Observable
public final class AddOnsModel {
    public init(makeLibrary: @escaping @MainActor (Game) -> AddOnLibrary? = { AddOnLibrary(game: $0) },
                holdCheck: (@MainActor (Game) -> @Sendable () -> Bool)? = nil) {
        self.makeLibrary = makeLibrary
        self.customHoldCheck = holdCheck
    }

    @ObservationIgnored private let makeLibrary: @MainActor (Game) -> AddOnLibrary?
    @ObservationIgnored private let customHoldCheck: (@MainActor (Game) -> @Sendable () -> Bool)?

    public enum Activity: Equatable, Sendable {
        case downloading(Double)
        case removing
    }

    public struct State: Sendable {
        public var addOns: [InstalledAddOn] = []
        public var updates: [String: AddOnUpdate] = [:]
        public var activity: [String: Activity] = [:]
        public var failures: [String: String] = [:]
        public var isScanning = false
        public var isChecking = false
        public var lastChecked: Date?
        public var scanFailure: String?
        /// The folder has been read at least once.
        public var hasScanned = false
        /// The person said so once: every recognized add-on updates on its own.
        public var keepsCurrent = false
        /// An update happened while the game was open: it needs a restart.
        public var changedWhileRunning = false
        /// Popular add-ons for this game that aren't installed.
        public var suggestions: [AddOnSearchResult] = []

        public func update(for addOn: InstalledAddOn) -> AddOnRelease? {
            if case .available(let release) = updates[addOn.id] { return release }
            return nil
        }

        public var available: [InstalledAddOn] { addOns.filter { update(for: $0) != nil } }
    }

    public private(set) var states: [String: State] = [:]
    @ObservationIgnored private var libraries: [String: AddOnLibrary] = [:]
    /// Every task that may change add-ons, so quitting can wait for them.
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var automatic: [String: UUID] = [:]
    /// A pass asked for while one runs, with the newest game (a new build).
    @ObservationIgnored private var rerun: [String: Game] = [:]
    /// Tracked tasks per game id.
    @ObservationIgnored private var taskCount: [String: Int] = [:]
    @ObservationIgnored private var lastAutomatic: [String: Date] = [:]
    /// Games whose automatic updates were due while they ran: they run when
    /// the game quits. Kept apart from `states`, which a closed sheet drops.
    @ObservationIgnored private var waitingForQuit: Set<String> = []
    /// What automatic updates couldn't do, by game and add-on: shown when
    /// the sheet opens, though the pass ran while it was closed.
    @ObservationIgnored private var automaticFailures: [String: [String: String]] = [:]
    /// Games being started (signing in, launching): automatic swaps hold off.
    @ObservationIgnored public let launching = LaunchingGames()
    /// The sheet sets this while it's open, so what it shows stays.
    @ObservationIgnored public var shown: Set<String> = []
    @ObservationIgnored private var isQuitting = false

    public func state(for game: Game) -> State { states[game.id] ?? State() }

    /// Whether add-on work could change files now: quitting and
    /// uninstalling wait for it.
    public var isBusy: Bool { !tasks.isEmpty }

    public func isWorking(_ game: Game) -> Bool {
        taskCount[game.id, default: 0] > 0 || !state(for: game).activity.isEmpty
    }

    /// One library per folder and game version: a new WoW build can make it
    /// another flavor or interface.
    private func library(for game: Game) -> AddOnLibrary? {
        let key = "\(game.id)|\(game.install.version ?? "")|\(game.install.installPath)"
        if let library = libraries[key] { return library }
        guard let library = makeLibrary(game) else { return nil }
        libraries = libraries.filter { !$0.key.hasPrefix("\(game.id)|") }
        libraries[key] = library
        return library
    }

    /// Runs `body` as tracked work; when it ends, lets go of a game whose
    /// sheet is closed.
    @discardableResult
    private func track(_ game: Game, _ body: @escaping @MainActor () async -> Void) -> UUID? {
        guard !isQuitting else { return nil }
        let id = UUID()
        taskCount[game.id, default: 0] += 1
        tasks[id] = Task { [weak self] in
            await body()
            guard let self else { return }
            self.tasks[id] = nil
            self.taskCount[game.id, default: 1] -= 1
            if self.taskCount[game.id] == 0 { self.taskCount[game.id] = nil }
            if !self.shown.contains(game.id), !self.isWorking(game) { self.forget(game) }
        }
        return id
    }

    // MARK: Showing

    /// Reads the folder, then checks for updates unless that was done in the
    /// last five minutes (or `force`).
    public func refresh(_ game: Game, force: Bool = false) async {
        guard let library = library(for: game) else { return }
        states[game.id, default: State()].isScanning = true
        do {
            let addOns = try await library.scan()
            states[game.id, default: State()].addOns = addOns
            states[game.id, default: State()].suggestions = await library.suggestions(for: addOns)
            states[game.id, default: State()].keepsCurrent = await library.keepsCurrent()
            states[game.id, default: State()].scanFailure = nil
            for (id, message) in automaticFailures[game.id] ?? [:] where states[game.id]?.failures[id] == nil {
                states[game.id, default: State()].failures[id] = message
            }
        } catch {
            Log.warning(.addOns, "scan_failed", nil, ["uid": game.id, "error": error])
            states[game.id, default: State()].scanFailure = errorMessage(error)
        }
        states[game.id, default: State()].isScanning = false
        states[game.id, default: State()].hasScanned = true
        let state = state(for: game)
        guard force || state.lastChecked.map({ Date().timeIntervalSince($0) > 300 }) ?? true, !state.isChecking else { return }
        await check(game, library: library)
    }

    private func check(_ game: Game, library: AddOnLibrary) async {
        states[game.id, default: State()].isChecking = true
        let updates = await library.check(state(for: game).addOns)
        states[game.id, default: State()].updates = updates
        states[game.id, default: State()].isChecking = false
        states[game.id, default: State()].lastChecked = Date()
    }

    /// Lets go of what was read for a game whose sheet closed, unless work
    /// is still going on.
    public func forget(_ game: Game) {
        guard !isWorking(game) else { return }
        states[game.id] = nil
        libraries = libraries.filter { !$0.key.hasPrefix("\(game.id)|") }
    }

    // MARK: Changing, from the sheet

    public func update(_ game: Game, _ addOn: InstalledAddOn, evenIfChanged: Bool = false) {
        guard let release = state(for: game).update(for: addOn) else { return }
        track(game) { [weak self] in
            await self?.consent(game)
            await self?.install(game, release: release, name: addOn.name, replacing: addOn, evenIfChanged: evenIfChanged)
            await self?.noteBaselines(game)
        }
    }

    /// The person's Update or Install is the say-so for this game: from now
    /// on its recognized add-ons update on their own. Quick: how each one
    /// looks (to tell later edits by hand) is noted after the change, by
    /// `noteBaselines`.
    private func consent(_ game: Game) async {
        guard let library = library(for: game), !state(for: game).keepsCurrent else { return }
        do {
            try await library.setKeepsCurrent()
            states[game.id]?.keepsCurrent = true
        } catch {
            Log.warning(.addOns, "keeps_current_failed", nil, ["uid": game.id, "error": error])
        }
    }

    /// Every update, one after another. An add-on whose files someone
    /// changed is left alone and says so.
    public func updateAll(_ game: Game) {
        let due = state(for: game).available
        track(game) { [weak self] in
            await self?.consent(game)
            for addOn in due {
                guard let self, !self.isQuitting, let release = self.state(for: game).update(for: addOn) else { continue }
                await self.install(game, release: release, name: addOn.name, replacing: addOn)
            }
            await self?.noteBaselines(game)
        }
    }

    public func install(_ game: Game, _ result: AddOnSearchResult) {
        guard !isQuitting, let library = library(for: game), state(for: game).activity[result.id] == nil else { return }
        states[game.id, default: State()].failures[result.id] = nil
        states[game.id, default: State()].activity[result.id] = .downloading(0)
        track(game) { [weak self] in
            guard let self else { return }
            await self.consent(game)
            do {
                try await library.install(result.ref, name: result.name, progress: self.progress(game, result.id))
                self.noteChange(game)
            } catch {
                self.fail(game, result.id, error)
            }
            self.states[game.id, default: State()].activity[result.id] = nil
            await self.rescan(game)
            await self.noteBaselines(game)
        }
    }

    public func remove(_ game: Game, _ addOn: InstalledAddOn) {
        guard !isQuitting, let library = library(for: game), state(for: game).activity[addOn.id] == nil else { return }
        states[game.id, default: State()].activity[addOn.id] = .removing
        track(game) { [weak self] in
            guard let self else { return }
            do {
                try await library.remove(addOn)
            } catch {
                self.fail(game, addOn.id, error)
            }
            self.states[game.id, default: State()].activity[addOn.id] = nil
            await self.rescan(game)
        }
    }

    public func search(_ game: Game, _ text: String) async throws -> [AddOnSearchResult] {
        guard let library = library(for: game) else { return [] }
        return try await library.search(text)
    }

    public func searchIndex(_ game: Game, _ text: String) async -> [AddOnSearchResult] {
        guard let library = library(for: game) else { return [] }
        return await library.searchIndex(text)
    }

    public func searchWoWInterface(_ game: Game, _ text: String) async throws -> [AddOnSearchResult] {
        guard let library = library(for: game) else { return [] }
        return try await library.searchWoWInterface(text)
    }

    /// `holds`: for automatic updates, true while the game is open or
    /// starting; the library asks it again right before the swap.
    @discardableResult
    private func install(_ game: Game, release: AddOnRelease, name: String, replacing: InstalledAddOn,
                         evenIfChanged: Bool = false, holds: (@Sendable () -> Bool)? = nil) async -> Error? {
        guard let library = library(for: game), state(for: game).activity[replacing.id] == nil else { return nil }
        states[game.id, default: State()].failures[replacing.id] = nil
        states[game.id, default: State()].activity[replacing.id] = .downloading(0)
        var failure: Error?
        do {
            try await library.install(release, name: name, replacing: replacing, evenIfChanged: evenIfChanged,
                                      holds: holds, progress: progress(game, replacing.id))
            states[game.id, default: State()].updates[replacing.id] = .current(release)
            automaticFailures[game.id]?[replacing.id] = nil
            if holds == nil { noteChange(game) }
            // The record makes it `ref`'s row from now on.
            if let ref = replacing.ref { states[game.id, default: State()].updates[ref.description] = .current(release) }
        } catch AddOnError.gameRunning {
            failure = AddOnError.gameRunning
        } catch {
            failure = error
            fail(game, replacing.id, error)
        }
        states[game.id, default: State()].activity[replacing.id] = nil
        await rescan(game)
        return failure
    }

    /// A change made by hand while the game runs needs a restart of it.
    /// The process list is read off the main thread.
    private func noteChange(_ game: Game) {
        let running = customHoldCheck?(game) ?? holdCheck(for: game)
        Task { [weak self] in
            guard await Task.detached(operation: { running() }).value else { return }
            // Only while the game's state is kept (its sheet open or work on).
            self?.states[game.id]?.changedWhileRunning = true
        }
    }

    /// After a change by hand: how the other recognized add-ons look now.
    private func noteBaselines(_ game: Game) async {
        guard let library = library(for: game), await library.keepsCurrent(),
              let addOns = try? await library.scan() else { return }
        try? await library.recordBaselines(for: addOns)
    }

    private func rescan(_ game: Game) async {
        guard let library = library(for: game), let addOns = try? await library.scan() else { return }
        states[game.id]?.addOns = addOns
        states[game.id]?.suggestions = await library.suggestions(for: addOns)
    }

    public func details(_ game: Game, _ ref: AddOnRef) async -> AddOnDetails? {
        guard let library = library(for: game) else { return nil }
        return await library.details(ref)
    }

    public func latest(_ game: Game, _ ref: AddOnRef) async -> Result<AddOnRelease, AddOnSourceError> {
        guard let library = library(for: game) else { return .failure(.unavailable) }
        return await library.latest(ref)
    }

    public func indexEntry(_ game: Game, _ ref: AddOnRef) async -> AddOnIndex.Entry? {
        await library(for: game)?.indexEntry(ref)
    }

    public func elsewhere(_ game: Game, _ text: String) async -> [String] {
        await library(for: game)?.elsewhere(matching: text) ?? []
    }

    private func progress(_ game: Game, _ id: String) -> @Sendable (Double) -> Void {
        { [weak self] fraction in
            Task { @MainActor in
                guard let self, self.states[game.id]?.activity[id] != nil else { return }
                self.states[game.id]?.activity[id] = .downloading(fraction)
            }
        }
    }

    private func fail(_ game: Game, _ id: String, _ error: Error) {
        Log.warning(.addOns, "change_failed", nil, ["uid": game.id, "addon": id, "error": error])
        states[game.id, default: State()].failures[id] = errorMessage(error)
    }

    // MARK: Automatic updates

    /// Keeps current, without asking, the add-ons Waypoint installed or
    /// updated (an Update click is the say-so): when the game updates
    /// (alongside its download, and again after, for releases made for the
    /// new patch), with the background check, and when the game quits if it
    /// was open when they were due. Never while the game is open or
    /// starting, never an add-on whose files someone changed, never on Play.
    /// `minimumInterval` keeps the background check from asking too often.
    public func updateAutomatically(_ game: Game, minimumInterval: TimeInterval = 0) {
        guard !isQuitting, game.family == .worldOfWarcraft, game.install.platform == .macOS else { return }
        if automatic[game.id] != nil {
            // The pass after a game update must use the new build: run again
            // with it.
            if minimumInterval == 0 { rerun[game.id] = game }
            return
        }
        if minimumInterval > 0, let last = lastAutomatic[game.id], Date().timeIntervalSince(last) < minimumInterval { return }
        lastAutomatic[game.id] = Date()
        automatic[game.id] = track(game) { [weak self] in
            await self?.runAutomatic(game)
            guard let self else { return }
            self.automatic[game.id] = nil
            if let newer = self.rerun.removeValue(forKey: game.id) { self.updateAutomatically(newer) }
        }
    }

    private func runAutomatic(_ game: Game) async {
        // Only once the person said so for this game; nothing is asked of
        // the sources before that.
        guard let library = library(for: game) else { return }
        guard await library.keepsCurrent() else {
            Log.info(.addOns, "automatic_off", nil, ["uid": game.id])
            return
        }
        guard let addOns = try? await library.scan() else { return }
        let managed = addOns.filter(\.isManaged)
        guard !managed.isEmpty else { return }
        states[game.id, default: State()].addOns = addOns
        states[game.id, default: State()].keepsCurrent = true
        let updates = await library.check(managed)
        states[game.id, default: State()].updates.merge(updates) { _, new in new }
        states[game.id, default: State()].lastChecked = Date()
        // Failures that no longer apply (fixed elsewhere, or no update now).
        automaticFailures[game.id] = automaticFailures[game.id]?.filter { id, _ in state(for: game).available.contains { $0.id == id } }
        try? await library.recordBaselines(for: managed)
        var due: [InstalledAddOn] = []
        for addOn in managed {
            guard let release = state(for: game).update(for: addOn), state(for: game).activity[addOn.id] == nil else { continue }
            // Recognized by name alone: only once Waypoint has updated it by hand.
            guard !addOn.isMatchedByName else { continue }
            guard await library.failedRelease(for: addOn) != release.id else { continue }
            if await library.hasLocalChanges(addOn) {
                automaticFailures[game.id, default: [:]][addOn.id] = AddOnError.changedLocally.errorDescription
                continue
            }
            due.append(addOn)
        }
        guard !due.isEmpty else {
            Log.info(.addOns, "automatic_nothing_due", nil, ["uid": game.id, "managed": managed.count])
            return
        }
        let holds = customHoldCheck?(game) ?? holdCheck(for: game)
        Log.info(.addOns, "automatic_update", nil, ["uid": game.id, "updates": due.count])
        for addOn in due {
            guard !isQuitting, !Task.isCancelled else { return }
            guard let release = state(for: game).update(for: addOn) else { continue }
            switch await install(game, release: release, name: addOn.name, replacing: addOn, holds: holds) {
            case nil: await library.setFailedRelease(nil, for: addOn)
            case AddOnError.gameRunning?:
                waitingForQuit.insert(game.id)
                Log.info(.addOns, "automatic_waits_for_game", nil, ["uid": game.id])
                return
            case let error?:
                // A dropped connection tries again next time; a zip that
                // can't be installed would only fail again.
                if Self.repeats(error) { await library.setFailedRelease(release.id, for: addOn) }
                automaticFailures[game.id, default: [:]][addOn.id] = errorMessage(error)
            }
        }
    }

    static func repeats(_ error: Error) -> Bool {
        switch error {
        case is AddOnPackageError: true
        case let error as AddOnError:
            switch error {
            case .conflict, .notSafe, .changedLocally, .unknownGame: true
            default: false
            }
        case let error as AddOnSourceError: error != .unavailable
        default: false
        }
    }

    /// True while the game runs from its folder or is being started; read
    /// fresh each time (off the main thread, in the library).
    private func holdCheck(for game: Game) -> @Sendable () -> Bool {
        // `_retail_`: what runs from it is this game.
        let folder = game.addOnsLocation!.deletingLastPathComponent().deletingLastPathComponent()
        let (launching, id) = (launching, game.id)
        return { launching.contains(id) || !RunningProcesses.inside(folder).isEmpty }
    }

    /// The game quit: what waited for it runs now.
    public func gameQuit(_ game: Game) {
        guard waitingForQuit.remove(game.id) != nil else { return }
        updateAutomatically(game)
    }

    /// Stops downloads and waits for every task: a swap in progress
    /// finishes first, so no add-on is left half replaced.
    public func prepareToQuit() async {
        isQuitting = true
        rerun = [:]
        let running = Array(tasks.values)
        for task in running { task.cancel() }
        for task in running { await task.value }
    }

    /// The quit was called off: add-on work may start again.
    public func quitCancelled() { isQuitting = false }
}

/// Which games are being started, readable from any thread.
public final class LaunchingGames: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<String> = []

    public func insert(_ id: String) { lock.withLock { _ = ids.insert(id) } }
    public func remove(_ id: String) { lock.withLock { _ = ids.remove(id) } }
    public func contains(_ id: String) -> Bool { lock.withLock { ids.contains(id) } }
}
