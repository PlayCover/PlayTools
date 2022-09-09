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
                               yCoord: data.transform.yCoord * screen.height,
                               size: data.transform.size * 10,
                               key: data.keyCode.keyCodeString())
                })
                ForEach(Keymapping.shared.keymapData.draggableButtonModels, id: \.transform, content: { data in
                    ButtonView(xCoord: data.transform.xCoord * screen.width,
                               yCoord: data.transform.yCoord * screen.height,
                               size: data.transform.size * 10,
                               key: data.keyCode.keyCodeString())
                })
                ForEach(Keymapping.shared.keymapData.joystickModel, id: \.transform, content: { data in
                    JoystickView(xCoord: data.transform.xCoord * screen.width,
                                 yCoord: data.transform.yCoord * screen.height,
                                 size: data.transform.size * 10,
                                 upKey: data.upKeyCode.keyCodeString(),
                                 rightKey: data.rightKeyCode.keyCodeString(),
                                 downKey: data.downKeyCode.keyCodeString(),
                                 leftKey: data.leftKeyCode.keyCodeString())
                })
                ForEach(Keymapping.shared.keymapData.mouseAreaModel, id: \.transform, content: { data in
                    MouseAreaView(xCoord: data.transform.xCoord * screen.width,
                                  yCoord: data.transform.yCoord * screen.height,
                                  size: data.transform.size * 10)
                })
            }
        }
        .ignoresSafeArea(.all)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.3))
        .contextMenu {
            SwiftUI.Button(action: {
                print("Button")
            }, label: {
                Text("Button")
            })
            SwiftUI.Button(action: {
                print("Dragable Button")
            }, label: {
                Text("Dragable Button")
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
    @State var size: CGFloat

    @State var key: String

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

struct JoystickView: View {
    @State var xCoord: CGFloat
    @State var yCoord: CGFloat
    @State var size: CGFloat

    @State var upKey: String
    @State var rightKey: String
    @State var downKey: String
    @State var leftKey: String

    var body: some View {
        ZStack {
            Circle()
                .fill(.thinMaterial)
                .frame(width: size*2, height: size*2)
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Text(upKey)
                        .rotationEffect(Angle(degrees: -45))
                    Text(rightKey)
                        .rotationEffect(Angle(degrees: -45))
                }
                HStack(spacing: 10) {
                    Text(leftKey)
                        .rotationEffect(Angle(degrees: -45))
                    Text(downKey)
                        .rotationEffect(Angle(degrees: -45))
                }
            }
            .rotationEffect(Angle(degrees: 45))
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

struct MouseAreaView: View {
    @State var xCoord: CGFloat
    @State var yCoord: CGFloat
    @State var size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(.thinMaterial)
                .frame(width: size, height: size)
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

extension Int {
    func keyCodeString() -> String {
        return KeyCodeNames.keyCodes[self]!
    }
}
