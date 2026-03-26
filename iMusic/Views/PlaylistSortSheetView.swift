import SwiftUI

struct SortSheetView<T: CaseIterable & Hashable>: View where T.AllCases: RandomAccessCollection {
    let title: String
    @Binding var selection: T
    @Binding var isPresented: Bool
    let labelFor: (T) -> String
    var onSelect: ((T) -> Void)? = nil
    @EnvironmentObject private var themeManager: ThemeManager

    var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
                .padding(.top, 16)
                .padding(.bottom, 4)

            ForEach(Array(T.allCases), id: \.self) { option in
                Button {
                    withAnimation(.spring()) {
                        if let onSelect {
                            onSelect(option)
                        } else {
                            selection = option
                        }
                        isPresented = false
                    }
                } label: {
                    Text(labelFor(option))
                        .font(.body).fontWeight(.semibold)
                        .foregroundStyle(themeManager.current.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(Capsule())
                }
            }

            Button {
                withAnimation(.spring()) { isPresented = false }
            } label: {
                Text("Cancel")
                    .font(.body).fontWeight(.semibold)
                    .foregroundStyle(themeManager.current.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(Capsule())
            }
            .padding(.top, 4)
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 12)
        .background(Color(.systemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }
}
