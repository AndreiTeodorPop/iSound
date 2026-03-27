//
//  eSoundApp.swift
//  eSound
//
//  Created by Pop Andrei on 14.03.2026.
//

import SwiftUI
import AppIntents

@main
struct iMusicApp: App {
    @StateObject private var sharedPlayer = AudioPlayer()
    @StateObject private var themeManager = ThemeManager()
    @State private var showSplash = true

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    .environmentObject(sharedPlayer)
                    .environmentObject(themeManager)
                    .tint(themeManager.current.accent)
                    .task { @MainActor in
                        sharedPlayer.configureAudioSession()
                        iMusicShortcuts.updateAppShortcutParameters()
                    }

                if showSplash {
                    SplashView()
                        .transition(.opacity)
                        .zIndex(1)
                        .task {
                            try? await Task.sleep(for: .milliseconds(1800))
                            withAnimation(.easeOut(duration: 0.5)) {
                                showSplash = false
                            }
                        }
                }
            }
        }
    }
}
