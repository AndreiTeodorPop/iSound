import SwiftUI
import Combine

final class ThemeManager: ObservableObject {
    @Published private(set) var current: AppTheme

    private let userDefaultsKey = "selectedThemeID"

    init() {
        let saved = UserDefaults.standard.string(forKey: "selectedThemeID")
        current = AppTheme.allThemes.first { $0.id == saved } ?? AppTheme.`default`
    }

    func select(_ theme: AppTheme) {
        current = theme
        UserDefaults.standard.set(theme.id, forKey: userDefaultsKey)
    }
}
