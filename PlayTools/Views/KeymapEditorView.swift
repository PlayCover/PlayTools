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
            ButtonView()
        }
        .ignoresSafeArea(.all)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.3))
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
                print("Mouse")
            }, label: {
                Text("Mouse")
            })
        }
    }
}

struct ButtonView: View {
    var body: some View {
        ZStack {
            if #available(iOS 15.0, *) {
                Circle()
                    .fill(.regularMaterial)
                    .frame(width: 40, height: 40)
            }
        }
    }
}
