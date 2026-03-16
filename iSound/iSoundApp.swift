//
//  eSoundApp.swift
//  eSound
//
//  Created by Pop Andrei on 14.03.2026.
//

import SwiftUI

@main
struct iSoundApp: App {
    @StateObject private var sharedPlayer = AudioPlayer()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(sharedPlayer)
                .task { @MainActor in
                    sharedPlayer.configureAudioSession()
                }
        }
    }
}
