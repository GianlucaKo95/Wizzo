import SwiftUI

extension Card {
    /// Mirrors cardLabel() in wizard/frontend/src/types.ts exactly.
    var label: String {
        if type == "wizard" { return "Z" }
        if type == "fool" { return "N" }
        return String(Int(value))
    }
}

/// Minimal text-based card visual - no illustrated card art yet (that's a
/// separate asset pipeline, not part of this phase's scope, see
/// docs/IOS.md). Colored by suit, matching Theme.suitColor/suitSymbol;
/// wizard/fool have no suit, so they render in gold instead.
struct CardChipView: View {
    let card: Card
    var isSelected: Bool = false

    private var isSuited: Bool { card.suit != nil }

    var body: some View {
        VStack(spacing: 2) {
            Text(card.label)
                .font(.system(size: 18, weight: .heavy, design: .rounded))
            if isSuited {
                Text(Theme.suitSymbol(card.suit))
                    .font(.system(size: 10, weight: .bold))
            }
        }
        .foregroundColor(isSuited ? Theme.suitColor(card.suit) : Theme.gold)
        .frame(width: 44, height: 60)
        .background(Theme.bgPanel)
        .cornerRadius(Theme.Radius.sm)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .stroke(isSelected ? Theme.gold : Theme.gold.opacity(0.25), lineWidth: isSelected ? 2 : 1)
        )
        .offset(y: isSelected ? -8 : 0)
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }
}

#Preview {
    HStack {
        CardChipView(card: Card(id: "red-7", type: "number", suit: "red", value: 7, specialType: nil))
        CardChipView(card: Card(id: "wizard-0", type: "wizard", suit: nil, value: 14, specialType: nil))
        CardChipView(card: Card(id: "fool-0", type: "fool", suit: nil, value: 0, specialType: nil))
    }
    .padding()
    .background(Theme.bgDark)
}
