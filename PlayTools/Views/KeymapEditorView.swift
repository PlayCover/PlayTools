//
//  KeymapEditorView.swift
//  PlayTools
//
//  Created by Isaac Marovitz on 09/09/2022.
//

import SwiftUI

struct KeymapEditorView: View {
    var body: some View {
        Group {
            Text("SwiftUI")
        }
        .background(Color.blue.opacity(0.3))
        .contextMenu {
            SwiftUI.Button(action: {
                print("Single Key")
            }, label: {
                Text("Single Key")
            })
            SwiftUI.Button(action: {
                print("Joystick")
            }, label: {
                Text("Joystick")
            })
            SwiftUI.Button(action: {
                print("D-Pad")
            }, label: {
                Text("D-Pad")
            })
        }
    }
}
