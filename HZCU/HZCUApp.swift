//
//  HZCUApp.swift
//  HZCU
//
//  Created by DataNeko.IO on 2026/05/31.
//

import SwiftUI

@main
struct HZCUApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
    }
}
