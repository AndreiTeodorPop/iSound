import SwiftUI

struct ThemePickerView: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 80))]

    var body: some View {
        NavigationStack {
            LazyVGrid(columns: columns, spacing: 24) {
                ForEach(AppTheme.allThemes) { theme in
                    ThemeCell(theme: theme, isSelected: themeManager.current.id == theme.id)
                        .onTapGesture { themeManager.select(theme) }
                }
            }
            .padding()
            .navigationTitle("Theme")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

private struct ThemeCell: View {
    let theme: AppTheme
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 8) {
            Circle()
                .fill(theme.accent.gradient)
                .frame(width: 56, height: 56)
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.title3.bold())
                            .foregroundStyle(.white)
                    }
                }
                .overlay {
                    Circle()
                        .strokeBorder(isSelected ? theme.accent : Color.clear, lineWidth: 3)
                        .padding(-4)
                }
            Text(theme.name)
                .font(.caption.bold())
                .foregroundStyle(isSelected ? theme.accent : .secondary)
        }
    }
}
