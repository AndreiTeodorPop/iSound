import SwiftUI
import UIKit

struct AlphabetIndexView<ID: Hashable>: View {
    let proxy: ScrollViewProxy
    let availableLetters: Set<String>
    let firstID: (String) -> ID?

    private let allLetters: [String] = ["#"] + (65...90).map { String(UnicodeScalar($0)!) }
    private let letterHeight: CGFloat = 16
    @State private var activeLetter: String? = nil

    private var letters: [String] { allLetters.filter { availableLetters.contains($0) } }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(letters, id: \.self) { letter in
                Text(letter)
                    .font(.system(size: 10, weight: activeLetter == letter ? .bold : .semibold))
                    .foregroundStyle(activeLetter == letter ? Color.accentColor : Color.secondary)
                    .frame(width: 16, height: letterHeight)
            }
        }
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let index = max(0, min(Int((value.location.y - 4) / letterHeight), letters.count - 1))
                    let letter = letters[index]
                    if letter != activeLetter {
                        activeLetter = letter
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        if let id = firstID(letter) {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                proxy.scrollTo(id, anchor: .top)
                            }
                        }
                    }
                }
                .onEnded { _ in
                    withAnimation(.easeOut(duration: 0.2)) { activeLetter = nil }
                }
        )
    }
}
