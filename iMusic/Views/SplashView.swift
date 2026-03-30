import SwiftUI

struct SplashView: View {
    @EnvironmentObject private var themeManager: ThemeManager

    @State private var logoScale: CGFloat = 0.3
    @State private var logoOpacity: Double = 0
    @State private var textOpacity: Double = 0
    @State private var textOffset: CGFloat = 0
    @State private var hatRotation: Double = -15
    @State private var waveOffset: CGFloat = 0

    var body: some View {
        ZStack {
            // Theme-tinted dark background
            ZStack {
                Color.black
                LinearGradient(
                    colors: [
                        themeManager.current.accent.opacity(0.55),
                        themeManager.current.secondaryAccent.opacity(0.35),
                        themeManager.current.accent.opacity(0.20)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .ignoresSafeArea()

            // Animated wave lines
            VStack {
                Spacer()
                ZStack {
                    ForEach(0..<3) { i in
                        WaveShape(offset: waveOffset + CGFloat(i) * 40)
                            .fill(Color.white.opacity(0.04 + Double(i) * 0.02))
                            .frame(height: 80)
                            .offset(y: CGFloat(i * 12))
                    }
                }
                .frame(height: 100)
            }
            .ignoresSafeArea()

            VStack(spacing: 24) {
                // Logo
                Image("iMusicLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 110, height: 110)
                    .clipShape(RoundedRectangle(cornerRadius: 26))
                    .shadow(color: themeManager.current.accent.opacity(0.5), radius: 20, y: 8)
                    .scaleEffect(logoScale)
                    .opacity(logoOpacity)
                    .rotation3DEffect(.degrees(hatRotation), axis: (x: 0, y: 1, z: 0))

                VStack(spacing: 8) {
                    Text("iMusic")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [
                                    themeManager.current.accent,
                                    themeManager.current.secondaryAccent
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .shadow(color: themeManager.current.accent.opacity(0.6), radius: 8)

                    Text("Your music, your way.")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.75))
                        .italic()
                }
                .opacity(textOpacity)
                .offset(y: textOffset)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.65)) {
                logoScale = 1.0
                logoOpacity = 1.0
                hatRotation = 0
            }
            withAnimation(.easeOut(duration: 1.2).delay(0.5)) {
                textOpacity = 1.0
            }
            withAnimation(.linear(duration: 4).repeatForever(autoreverses: false)) {
                waveOffset = 60
            }
        }
    }
}

struct WaveShape: Shape {
    var offset: CGFloat

    var animatableData: CGFloat {
        get { offset }
        set { offset = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let width = rect.width
        let height = rect.height
        let midHeight = height * 0.5

        path.move(to: CGPoint(x: 0, y: midHeight))
        for x in stride(from: 0, through: width, by: 2) {
            let y = midHeight + sin((x + offset) / 30) * 10
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.addLine(to: CGPoint(x: width, y: height))
        path.addLine(to: CGPoint(x: 0, y: height))
        path.closeSubpath()
        return path
    }
}
