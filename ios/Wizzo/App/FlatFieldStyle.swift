import SwiftUI

/// Shared text-field chrome (AuthView, HomeView's room-code field, ...) -
/// dark panel background + thin gold outline, matching the flat-UI style
/// used throughout wizard/frontend/src/App.tsx (flatInput).
struct FlatFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .background(Theme.bgPanel)
            .foregroundColor(Theme.ivory)
            .cornerRadius(Theme.Radius.sm)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .stroke(Theme.gold.opacity(0.2), lineWidth: 1)
            )
    }
}

extension View {
    func flatFieldStyle() -> some View {
        modifier(FlatFieldStyle())
    }
}
