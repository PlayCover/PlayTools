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
            ZStack {
                ForEach(Keymapping.shared.keymapData.buttonModels, id: \.transform, content: { data in
                    ButtonView(xCoord: data.transform.xCoord * screen.width,
                               yCoord: (data.transform.yCoord - 0.5) * screen.height,
                               key: KeyCodeNames.keyCodes[data.keyCode]!,
                               size: data.transform.size*10)
                })
            }
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
    @State var xCoord: CGFloat
    @State var yCoord: CGFloat
    @State var key: String
    @State var size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(.thinMaterial)
                .frame(width: size, height: size)
            Text(key)
        }
        .position(x: xCoord, y: yCoord)
        .gesture(
            DragGesture()
                .onChanged { gesture in
                    xCoord = gesture.location.x
                    yCoord = gesture.location.y
                }
        )
    }
}
