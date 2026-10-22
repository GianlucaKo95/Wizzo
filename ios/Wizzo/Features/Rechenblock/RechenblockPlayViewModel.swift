import Foundation
import Supabase

/// Mirrors ManualGamePlay in App.tsx: entering Ansage/Stiche round by round
/// for an in-progress Rechenblock game. Unlike LobbyViewModel/GameViewModel
/// there's no Realtime/poll here - a manual game has exactly one writer
/// (the host, entering results from the real table) and the web app itself
/// never gives a linked (non-host) player any viewing UI either, even
/// though their read-only RLS access exists (010_manual_games.sql) - so
/// this view model just reloads explicitly after each of its own writes.
@MainActor
final class RechenblockPlayViewModel: ObservableObject {
    @Published var game: ManualGame?
    @Published var players: [ManualGamePlayer] = []
    @Published var rounds: [ManualGameRound] = []
    @Published var isLoading = true

    @Published var bids: [Int: String] = [:]
    @Published var gots: [Int: String] = [:]
    @Published var locking = false
    @Published var saving = false
    @Published var finishing = false
    @Published var errorMessage: String?
    @Published var wolkePicking = false
    @Published var wolkePlayer: Int?
    @Published var editingRound: Int?
    @Published var editBid: [Int: String] = [:]
    @Published var editGot: [Int: String] = [:]
    @Published var editSaving = false
    @Published var editErrorMessage: String?

    let manualGameId: UUID
    /// Called once the game is finished or discarded, so the owning
    /// RechenblockView can drop back to the setup/finished-game screens.
    var onFinishedOrDiscarded: () -> Void = {}

    private var lastTrackedRoundNum: Int?
    private var lastTrackedPendingPresent: Bool?

    init(manualGameId: UUID) {
        self.manualGameId = manualGameId
    }

    var currentRoundNum: Int { rounds.count + 1 }
    var isDone: Bool { (game?.maxRounds).map { currentRoundNum > $0 } ?? false }
    var dealerIndex: Int { players.isEmpty ? 0 : (currentRoundNum - 1) % players.count }
    var dealer: ManualGamePlayer? { players.first { $0.playerIndex == dealerIndex } }
    var gotSum: Int { players.reduce(0) { $0 + (Int(gots[$1.playerIndex] ?? "") ?? 0) } }

    var pendingBids: [Int: Int]? {
        guard let raw = game?.pendingBids else { return nil }
        var out: [Int: Int] = [:]
        for (key, value) in raw { if let index = Int(key) { out[index] = value } }
        return out
    }

    var runningByRound: [Int: [Int: Int]] {
        computeManualRunningTotals(playerIndexes: players.map(\.playerIndex), rounds: rounds)
    }

    var lastRoundNum: Int? { rounds.last?.round }

    func isLeader(atRound round: Int, playerIndex: Int) -> Bool {
        guard round == lastRoundNum, let totals = runningByRound[round] else { return false }
        let maxTotal = totals.values.max() ?? 0
        return maxTotal > 0 && totals[playerIndex] == maxTotal
    }

    /// Bidding proceeds one player at a time, left of the dealer first,
    /// dealer last - mirrors the real turn order instead of a shared row.
    var biddingOrder: [ManualGamePlayer] {
        guard !isDone, pendingBids == nil, !players.isEmpty else { return [] }
        return (0..<players.count).compactMap { offset in
            let targetIndex = (dealerIndex + 1 + offset) % players.count
            return players.first { $0.playerIndex == targetIndex }
        }
    }

    var nextBidder: ManualGamePlayer? { biddingOrder.first { bids[$0.playerIndex] == nil } }

    var nextGoter: ManualGamePlayer? {
        guard !isDone, pendingBids != nil else { return nil }
        return players.first { gots[$0.playerIndex] == nil }
    }

    /// Stichzwang: only the dealer (last to bid) can face this - the one
    /// total that would make every bid add up to exactly the round's
    /// trick count is forbidden for them.
    var dealerForbiddenBid: Int? {
        guard nextBidder?.playerIndex == dealerIndex else { return nil }
        let sum = players.filter { $0.playerIndex != dealerIndex }
            .reduce(0) { $0 + (Int(bids[$1.playerIndex] ?? "") ?? 0) }
        let forbidden = currentRoundNum - sum
        return (forbidden >= 0 && forbidden <= currentRoundNum) ? forbidden : nil
    }

    func effectiveBid(_ playerIndex: Int) -> String {
        if let b = bids[playerIndex] { return b }
        if let pb = pendingBids?[playerIndex] { return String(pb) }
        return ""
    }

    /// Wolke (9¾): exactly ±1 on the trick winner's already-locked Ansage,
    /// never below 0.
    func adjustBid(_ playerIndex: Int, delta: Int) {
        let current = Int(effectiveBid(playerIndex)) ?? 0
        bids[playerIndex] = String(max(0, current + delta))
    }

    func load() async {
        do {
            let fetchedGame: ManualGame = try await SupabaseService.client
                .from("manual_games")
                .select()
                .eq("id", value: manualGameId)
                .single()
                .execute()
                .value
            async let playersFetch: [ManualGamePlayer] = SupabaseService.client
                .from("manual_game_players")
                .select()
                .eq("manual_game_id", value: manualGameId)
                .order("player_index")
                .execute()
                .value
            async let roundsFetch: [ManualGameRound] = SupabaseService.client
                .from("manual_game_rounds")
                .select()
                .eq("manual_game_id", value: manualGameId)
                .order("round")
                .execute()
                .value
            game = fetchedGame
            players = try await playersFetch
            rounds = try await roundsFetch

            // Mirrors the useEffect([currentRoundNum, !!pendingBids]) reset
            // in App.tsx - only wipe local taps once the round/phase has
            // actually moved on, not on every reload mid-entry.
            let roundNum = rounds.count + 1
            let pendingPresent = fetchedGame.pendingBids != nil
            if lastTrackedRoundNum != roundNum || lastTrackedPendingPresent != pendingPresent {
                bids = [:]
                gots = [:]
                errorMessage = nil
                wolkePicking = false
                wolkePlayer = nil
            }
            lastTrackedRoundNum = roundNum
            lastTrackedPendingPresent = pendingPresent
        } catch {
            // best-effort - keep showing whatever was loaded before
        }
        isLoading = false
    }

    func undoLastBid() {
        guard let last = biddingOrder.filter({ bids[$0.playerIndex] != nil }).last else { return }
        bids.removeValue(forKey: last.playerIndex)
    }

    func undoLastGot() {
        guard let last = players.filter({ gots[$0.playerIndex] != nil }).last else { return }
        gots.removeValue(forKey: last.playerIndex)
    }

    /// Mirrors recordBid() in App.tsx: once the dealer (last in turn order)
    /// has bid, every player's Ansage is locked into `pending_bids`
    /// immediately.
    func recordBid(_ playerIndex: Int, value: Int) async {
        bids[playerIndex] = String(value)
        guard playerIndex == dealerIndex, let game else { return }
        locking = true
        defer { locking = false }
        var asObject: [String: Int] = [:]
        for p in players { asObject[String(p.playerIndex)] = Int(bids[p.playerIndex] ?? "") ?? 0 }
        do {
            try await SupabaseService.client
                .from("manual_games")
                .update(PendingBidsUpdate(pendingBids: asObject))
                .eq("id", value: game.id)
                .execute()
            await load()
        } catch {
            errorMessage = "Ansagen konnten nicht gespeichert werden"
        }
    }

    /// Mirrors recordGot() in App.tsx: tricks won are tapped in one player
    /// at a time, in seat order; the round auto-saves once the last one's
    /// in.
    func recordGot(_ playerIndex: Int, value: Int) async {
        gots[playerIndex] = String(value)
        let stillMissing = players.contains { (gots[$0.playerIndex] ?? "").isEmpty }
        guard !stillMissing else { return }
        await saveRound(gotsOverride: gots)
    }

    func saveRound(gotsOverride: [Int: String]? = nil) async {
        guard let game, pendingBids != nil else { return }
        let resolvedGots = gotsOverride ?? gots
        errorMessage = nil
        for p in players {
            if effectiveBid(p.playerIndex).isEmpty || (resolvedGots[p.playerIndex] ?? "").isEmpty {
                errorMessage = "Bitte für jeden Spieler Ansage und Stiche eintragen"
                return
            }
        }
        saving = true
        defer { saving = false }
        let results: [RoundResult] = players.map { p in
            let bid = Int(effectiveBid(p.playerIndex)) ?? 0
            let got = Int(resolvedGots[p.playerIndex] ?? "") ?? 0
            let delta = bid == got ? 20 + bid * 10 : -abs(bid - got) * 10
            return RoundResult(playerIndex: p.playerIndex, name: p.displayName, bid: bid, got: got, delta: delta, totalScore: nil)
        }
        do {
            try await SupabaseService.client
                .from("manual_game_rounds")
                .insert(NewManualGameRound(manualGameId: game.id, round: currentRoundNum, results: results))
                .execute()
            try await SupabaseService.client
                .from("manual_games")
                .update(PendingBidsUpdate(pendingBids: nil))
                .eq("id", value: game.id)
                .execute()
            await load()
        } catch {
            errorMessage = "Runde konnte nicht gespeichert werden"
        }
    }

    var needsFinishConfirmation: Bool { rounds.count < 3 }

    /// Mirrors finish() in App.tsx: routed through the edge function
    /// (finishManualGame) because game_stats' insert policy is service-
    /// role-only, same protection online games get (see index.ts).
    func finish() async {
        guard let game else { return }
        finishing = true
        defer { finishing = false }
        let result = await GameActionClient.call(roomId: "", action: "finishManualGame", extra: ["manualGameId": game.id.uuidString])
        if let error = result["error"] as? String {
            errorMessage = error
        } else {
            onFinishedOrDiscarded()
        }
    }

    func discard() async {
        guard let game else { return }
        try? await SupabaseService.client.from("manual_games").delete().eq("id", value: game.id).execute()
        onFinishedOrDiscarded()
    }

    func startEditRound(_ round: ManualGameRound) {
        var eb: [Int: String] = [:]
        var eg: [Int: String] = [:]
        for p in players {
            if let entry = round.results.first(where: { $0.playerIndex == p.playerIndex }) {
                eb[p.playerIndex] = String(entry.bid)
                eg[p.playerIndex] = String(entry.got)
            } else {
                eb[p.playerIndex] = ""
                eg[p.playerIndex] = ""
            }
        }
        editBid = eb
        editGot = eg
        editErrorMessage = nil
        editingRound = round.round
    }

    func cancelEditRound() {
        editingRound = nil
        editErrorMessage = nil
    }

    func saveEditedRound(_ round: ManualGameRound) async {
        editErrorMessage = nil
        for p in players {
            if (editBid[p.playerIndex] ?? "").isEmpty || (editGot[p.playerIndex] ?? "").isEmpty {
                editErrorMessage = "Bitte für jeden Spieler Ansage und Stiche eintragen"
                return
            }
        }
        editSaving = true
        defer { editSaving = false }
        let results: [RoundResult] = players.map { p in
            let bid = Int(editBid[p.playerIndex] ?? "") ?? 0
            let got = Int(editGot[p.playerIndex] ?? "") ?? 0
            let delta = bid == got ? 20 + bid * 10 : -abs(bid - got) * 10
            return RoundResult(playerIndex: p.playerIndex, name: p.displayName, bid: bid, got: got, delta: delta, totalScore: nil)
        }
        do {
            try await SupabaseService.client
                .from("manual_game_rounds")
                .update(ResultsUpdate(results: results))
                .eq("id", value: round.id)
                .execute()
            editingRound = nil
            await load()
        } catch {
            editErrorMessage = "Runde konnte nicht aktualisiert werden"
        }
    }
}

/// Swift's auto-synthesized Encodable uses `encodeIfPresent` for Optional
/// properties, which OMITS the key entirely when nil instead of writing
/// JSON `null` - harmless for inserts (an omitted nullable column just gets
/// its default, which is null here anyway) but wrong for `saveRound()`'s
/// "clear pending_bids" update, where an omitted key means PostgREST leaves
/// the column untouched instead of actually clearing it. A manual
/// `encode(to:)` sidesteps that ambiguity entirely.
private struct PendingBidsUpdate: Encodable {
    let pendingBids: [String: Int]?

    enum CodingKeys: String, CodingKey {
        case pendingBids = "pending_bids"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let pendingBids {
            try container.encode(pendingBids, forKey: .pendingBids)
        } else {
            try container.encodeNil(forKey: .pendingBids)
        }
    }
}

private struct NewManualGameRound: Encodable {
    let manualGameId: UUID
    let round: Int
    let results: [RoundResult]

    enum CodingKeys: String, CodingKey {
        case manualGameId = "manual_game_id"
        case round
        case results
    }
}

private struct ResultsUpdate: Encodable {
    let results: [RoundResult]
}
