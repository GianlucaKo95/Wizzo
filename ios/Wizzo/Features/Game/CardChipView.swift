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

/// Mirrors CardView.tsx's `small` prop - two fixed sizes instead of one, so
/// a context that needs the smaller web size (trick area, Indianer-Poker's
/// visible opponent card, witch-swap picks) doesn't have to fake it with
/// `.scaleEffect()` on the large size, which also shrinks stroke widths and
/// corner radii out of proportion and crops the corner labels illegibly
/// small. `.large` is the own-hand/picker size (own hand was previously
/// stuck at the same cramped 44x60 everything else used).
enum CardSize {
    case large, small

    var frame: CGSize {
        switch self {
        case .large: return CGSize(width: 72, height: 100)
        case .small: return CGSize(width: 40, height: 56)
        }
    }

    var labelFontSize: CGFloat { self == .large ? 12 : 9 }
    var sigilFontSize: CGFloat { self == .large ? 8 : 6 }
    var cornerRadius: CGFloat { self == .large ? Theme.Radius.md : Theme.Radius.sm }
}

/// Illustrated card visual - the same WebP art the web app uses
/// (Resources/Cards/, see Card+Art.swift), with the same two corner label
/// pills (value + house sigil) CardView.tsx overlays on top of its art.
/// Falls back to the old plain text-chip look if an image is missing (e.g.
/// an id this hasn't been taught to map yet) rather than showing nothing.
struct CardChipView: View {
    let card: Card
    var isSelected: Bool = false
    /// Round 1 "Indianer Poker": your own hand is dealt face down (you can't
    /// see its value, only your opponents can) - mirrors `faceDown={room.round
    /// === 1}` on the web's own-hand CardView. The card is still fully
    /// tappable/playable at its normal position; only the face differs.
    var faceDown: Bool = false
    /// Trick-end winning card: pulsing gold glow, mirrors CardView.tsx's
    /// `winner` prop/cardGlow animation.
    var winner: Bool = false
    var size: CardSize = .large

    private var showsSigil: Bool {
        card.suit != nil && card.specialType == nil && card.type == "number"
    }

    @State private var glow = false

    var body: some View {
        ZStack {
            if faceDown {
                faceDownArt
            } else if let art = card.artImageName.flatMap(CardArtCache.image(named:)) {
                Image(uiImage: art)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    // Matches CardView.tsx's objectPosition "center top" -
                    // the art is portrait character art, cropping from the
                    // center would cut off faces more often than feet.
                    .frame(width: size.frame.width, height: size.frame.height, alignment: .top)
                    .clipped()
                cornerLabel(rotated: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                cornerLabel(rotated: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            } else {
                textFallback
            }
        }
        .frame(width: size.frame.width, height: size.frame.height)
        .background(Theme.bgPanel)
        .cornerRadius(size.cornerRadius)
        .overlay(
            RoundedRectangle(cornerRadius: size.cornerRadius)
                .stroke(winner ? Theme.gold : isSelected ? Theme.gold : Theme.gold.opacity(0.25), lineWidth: winner || isSelected ? 2 : 1)
        )
        .shadow(color: winner ? Theme.gold.opacity(glow ? 0.75 : 0.25) : .clear, radius: winner ? (glow ? 10 : 4) : 0)
        .onAppear {
            guard winner else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { glow = true }
        }
        .offset(y: isSelected ? -8 : 0)
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }

    private var faceDownArt: some View {
        ZStack {
            Rectangle().fill(Theme.bgDark)
            Text("⚡")
                .font(.system(size: size == .large ? 20 : 14))
                .foregroundColor(Theme.gold.opacity(0.35))
        }
    }

    private var textFallback: some View {
        VStack(spacing: 2) {
            Text(card.label)
                .font(.system(size: size == .large ? 22 : 15, weight: .heavy, design: .rounded))
            if showsSigil {
                Text(Theme.suitSymbol(card.suit))
                    .font(.system(size: size == .large ? 12 : 9, weight: .bold))
            }
        }
        .foregroundColor(card.displayColor)
    }

    private func cornerLabel(rotated: Bool) -> some View {
        VStack(spacing: 0) {
            Text(card.label)
                .font(.system(size: size.labelFontSize, weight: .heavy, design: .serif))
                .foregroundColor(card.displayColor)
            if showsSigil {
                Text(Theme.suitSymbol(card.suit))
                    .font(.system(size: size.sigilFontSize, weight: .bold))
                    .foregroundColor(card.displayColor)
            }
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 1)
        .background(Color.black.opacity(0.7))
        .cornerRadius(3)
        .rotationEffect(rotated ? .degrees(180) : .zero)
        .padding(rotated ? [.bottom, .trailing] : [.top, .leading], 3)
    }
}

#Preview {
    VStack {
        HStack {
            CardChipView(card: Card(id: "red-7", type: "number", suit: "red", value: 7, specialType: nil))
            CardChipView(card: Card(id: "wizard-0", type: "wizard", suit: nil, value: 14, specialType: nil))
            CardChipView(card: Card(id: "dragon", type: "special", suit: nil, value: 0, specialType: "dragon"))
            CardChipView(card: Card(id: "red-7", type: "number", suit: "red", value: 7, specialType: nil), faceDown: true)
        }
        HStack {
            CardChipView(card: Card(id: "red-7", type: "number", suit: "red", value: 7, specialType: nil), size: .small)
            CardChipView(card: Card(id: "wizard-0", type: "wizard", suit: nil, value: 14, specialType: nil), size: .small)
        }
    }
    .padding()
    .background(Theme.bgDark)
}
