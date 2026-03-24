import SwiftUI

struct AppTheme: Identifiable, Hashable {
    let id: String
    let name: String
    let accent: Color
    let secondaryAccent: Color

    static let allThemes: [AppTheme] = [
        AppTheme(id: "purple",  name: "Purple",  accent: Color(red: 0.75, green: 0.35, blue: 0.95), secondaryAccent: .pink),
        AppTheme(id: "ocean",   name: "Ocean",   accent: .blue,                                      secondaryAccent: .teal),
        AppTheme(id: "sunset",  name: "Sunset",  accent: .orange,                                    secondaryAccent: .red),
        AppTheme(id: "forest",  name: "Forest",  accent: .green,                                     secondaryAccent: .mint),
        AppTheme(id: "rose",    name: "Rose",    accent: .pink,                                      secondaryAccent: .purple),
        AppTheme(id: "indigo",  name: "Indigo",  accent: .indigo,                                    secondaryAccent: .cyan),
    ]

    static let `default` = allThemes[0]
}
