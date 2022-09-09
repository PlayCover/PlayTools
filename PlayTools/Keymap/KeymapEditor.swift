//
//  KeymapEditor.swift
//  PlayTools
//
//  Created by Isaac Marovitz on 09/09/2022.
//

import SwiftUI

@main
struct PlayToolsApp: App {
    var body: some Scene {
        WindowGroup {
            KeymapEditor()
        }
    }
}

struct KeymapEditor: View {
    var body: some View {
        ZStack {
            Color.red
                .ignoresSafeArea(.all)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text("Test")
                .font(.largeTitle)
        }
    }
}
