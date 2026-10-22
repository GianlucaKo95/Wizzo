import SwiftUI

/// Mirrors the `Avatar` component in App.tsx: a circular profile image when
/// `url` is set, otherwise a colored circle with the name's first letter -
/// shared by every screen that shows a person next to their name (Profile,
/// Freunde, Lobby, ...).
struct AvatarView: View {
    let url: String?
    let name: String
    var size: CGFloat = 28

    var body: some View {
        Group {
            if let url, let imageURL = URL(string: url) {
                AsyncImage(url: imageURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var placeholder: some View {
        Circle()
            .fill(Theme.accent)
            .overlay(
                Text(name.prefix(1).uppercased())
                    .font(.system(size: size * 0.45, weight: .bold))
                    .foregroundColor(Theme.ivory)
            )
    }
}

#Preview {
    VStack(spacing: 12) {
        AvatarView(url: nil, name: "Spieler", size: 60)
        AvatarView(url: "https://example.com/missing.jpg", name: "Spieler", size: 60)
    }
}
