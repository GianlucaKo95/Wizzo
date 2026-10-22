import SwiftUI

extension Card {
    /// Mirrors cardLabel() in wizard/frontend/src/types.ts, extended with the
    /// special-card labels from CardView.tsx's specialConfigs (wizardfool is
    /// a special case there too: shows N/Z while still a choice, then the
    /// resolved Z/N once `type` is rewritten server-side after playing).
    var label: String {
        if specialType == "wizardfool" {
            if type == "wizard" { return "Z" }
            if type == "fool" { return "N" }
            return "N/Z"
        }
        if let specialType { return Theme.specialLabel(specialType) }
        if type == "wizard" { return "Z" }
        if type == "fool" { return "N" }
        return String(Int(value))
    }

    /// Mirrors labelColor in CardView.tsx.
    var displayColor: Color {
        if specialType == "wizardfool" {
            if type == "wizard" { return Theme.gold }
            if type == "fool" { return Theme.ivoryDim }
            return Color(hex: 0xD3A625)
        }
        if let specialType { return Theme.specialColor(specialType) }
        if type == "wizard" || type == "fool" { return Theme.gold }
        return Theme.suitColor(suit)
    }
}

/// Minimal text-based card visual - no illustrated card art yet (that's a
/// separate asset pipeline, not part of this phase's scope, see
/// docs/IOS.md). Colored via Card.displayColor (suit for number cards,
/// Theme.specialColor for special cards, gold for wizard/fool).
struct CardChipView: View {
    let card: Card
    var isSelected: Bool = false

    private var showsSuitSymbol: Bool {
        card.suit != nil && card.specialType == nil
    }

    var body: some View {
        VStack(spacing: 2) {
            Text(card.label)
                .font(.system(size: 18, weight: .heavy, design: .rounded))
            if showsSuitSymbol {
                Text(Theme.suitSymbol(card.suit))
                    .font(.system(size: 10, weight: .bold))
            }
        }
        .foregroundColor(card.displayColor)
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
