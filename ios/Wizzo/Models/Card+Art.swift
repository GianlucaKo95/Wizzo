import UIKit

/// Loads the illustrated card art bundled under Resources/Cards/ (same
/// WebP files as wizard/frontend/public/cards/ - iOS has decoded WebP via
/// ImageIO since iOS 14, no extra library needed). Cached in memory since
/// the same ~20 filenames repeat constantly across hand/trick/scoreboard
/// views during a game.
enum CardArtCache {
    private static var cache: [String: UIImage] = [:]

    static func image(named name: String) -> UIImage? {
        if let cached = cache[name] { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: "webp", subdirectory: "Cards"),
              let image = UIImage(contentsOfFile: url.path)
        else { return nil }
        cache[name] = image
        return image
    }
}

extension Card {
    /// Mirrors the `/cards/<name>.webp` filename construction in
    /// CardView.tsx exactly (house folder per suit, 1-13; Wizard_1-4/
    /// Fool_1-4 cycling through the 4 flavor-text characters by id index;
    /// one fixed filename per special card).
    var artImageName: String? {
        if let specialType {
            let specialFiles: [String: String] = [
                "dragon": "Special_Dragon", "fairy": "Special_Fairy", "witch": "Special_Witch",
                "werewolf": "Special_Werewolf", "vampire": "Special_Vampire", "bomb": "Special_Bomb",
                "rainbow7": "Special_George", "rainbow9": "Special_Platform9", "wizardfool": "Special_Ron",
            ]
            return specialFiles[specialType]
        }
        if type == "wizard" { return "Wizard_\(flavorIndex + 1)" }
        if type == "fool" { return "Fool_\(flavorIndex + 1)" }
        guard let suit else { return nil }
        let houseFolders: [String: String] = [
            "red": "Gryffindor", "blue": "Ravenclaw", "green": "Slytherin", "yellow": "Hufflepuff",
        ]
        guard let folder = houseFolders[suit] else { return nil }
        return "\(folder)_\(Int(value))"
    }

    /// The trailing "-N" in ids like "wizard-2"/"fool-1" (mirrors getIndex()
    /// in CardView.tsx) - which of the 4 flavor-text characters this
    /// particular wizard/fool card shows.
    private var flavorIndex: Int {
        guard let dash = id.lastIndex(of: "-"), let n = Int(id[id.index(after: dash)...]) else { return 0 }
        return n % 4
    }
}
