//
//  eSoundApp.swift
//  eSound
//
//  Created by Pop Andrei on 14.03.2026.
//

import SwiftUI

@main
struct iMusicApp: App {
    @StateObject private var sharedPlayer = AudioPlayer()
    @StateObject private var themeManager = ThemeManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(sharedPlayer)
                .environmentObject(themeManager)
                .tint(themeManager.current.accent)
                .task { @MainActor in
                    sharedPlayer.configureAudioSession()
                }
        }
    }
}
