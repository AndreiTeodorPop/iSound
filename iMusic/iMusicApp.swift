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
    @StateObject private var sharedPlayer: AudioPlayer = .shared
    @StateObject private var themeManager = ThemeManager()

    init() {
        iMusicShortcuts.updateAppShortcutParameters()
    }
    @State private var showSplash = true
    @State private var showContent = false

    var body: some Scene {
        WindowGroup {
            ZStack {
                if showContent {
                    ContentView()
                        .environmentObject(sharedPlayer)
                        .environmentObject(themeManager)
                        .tint(themeManager.current.accent)
                        .transition(.opacity)
                        .task { @MainActor in
                            sharedPlayer.configureAudioSession()
                            sharedPlayer.restoreLastPlayedYouTube()
                            iMusicShortcuts.updateAppShortcutParameters()
                        }
                }

                if showSplash {
                    SplashView()
                        .environmentObject(themeManager)
                        .transition(.opacity)
                        .zIndex(1)
                        .task {
                            try? await Task.sleep(for: .milliseconds(2800))
                            withAnimation(.easeOut(duration: 0.6)) {
                                showSplash = false
                            }
                            try? await Task.sleep(for: .milliseconds(600))
                            withAnimation(.easeIn(duration: 0.3)) {
                                showContent = true
                            }
                        }
                }
            }
        }
    }
}
