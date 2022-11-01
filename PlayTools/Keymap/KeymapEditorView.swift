//
//  KeymapEditorView.swift
//  PlayTools
//
//  Created by Isaac Marovitz on 31/10/2022.
//

import SwiftUI

struct KeymapEditorView: View {
    @State var selected: KeyModelTransform?

    var body: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea(.all)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            ForEach(Keymapping.shared.keymapData.buttonModels, id: \.transform) { data in
                ButtonView(transform: data.transform,
                           selected: $selected,
                           key: data.keyCode.keyCodeString())
            }
            ForEach(Keymapping.shared.keymapData.joystickModel, id: \.transform, content: { data in
                JoystickView(transform: data.transform,
                             selected: $selected,
                             upKey: data.upKeyCode.keyCodeString(),
                             rightKey: data.rightKeyCode.keyCodeString(),
                             downKey: data.downKeyCode.keyCodeString(),
                             leftKey: data.leftKeyCode.keyCodeString())
            })
            ForEach(Keymapping.shared.keymapData.mouseAreaModel, id: \.transform, content: { data in
                MouseAreaView(transform: data.transform,
                              selected: $selected)
            })
        }
        .ignoresSafeArea(.all)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onTapGesture {
            selected = nil
        }
    }
}

struct ButtonView: View {
    @State var transform: KeyModelTransform
    @Binding var selected: KeyModelTransform?

    @State var key: String

    var body: some View {
        Text(key)
            .frame(width: 80, height: 80)
            .background(Circle()
                .stroke(selected == transform ? .white : .accentColor, lineWidth: 1)
                .background(Circle().fill(.regularMaterial)))
            .position(x: transform.xCoord * screen.width,
                      y: transform.yCoord * screen.height)
            .onTapGesture {
                selected = transform
            }
            .gesture(
                DragGesture()
                    .onChanged { gesture in
                        transform.xCoord = gesture.location.x
                        transform.yCoord = gesture.location.y
                    }
            )
    }
}

struct JoystickView: View {
    @State var transform: KeyModelTransform
    @Binding var selected: KeyModelTransform?

    @State var upKey: String
    @State var rightKey: String
    @State var downKey: String
    @State var leftKey: String

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white, lineWidth: 1)
                .frame(width: 200, height: 200)
                .background(Circle().fill(.regularMaterial))
            VStack(alignment: .center, spacing: 15) {
                HStack(alignment: .center, spacing: 15) {
                    Text(upKey)
                        .frame(width: 60, height: 60)
                        .background(Circle().stroke(.white, lineWidth: 1))
                        .rotationEffect(Angle(degrees: -45))
                    Text(rightKey)
                        .frame(width: 60, height: 60)
                        .background(Circle().stroke(.white, lineWidth: 1))
                        .rotationEffect(Angle(degrees: -45))
                }
                HStack(alignment: .center, spacing: 15) {
                    Text(leftKey)
                        .frame(width: 60, height: 60)
                        .background(Circle().stroke(.white, lineWidth: 1))
                        .rotationEffect(Angle(degrees: -45))
                    Text(downKey)
                        .frame(width: 60, height: 60)
                        .background(Circle().stroke(.white, lineWidth: 1))
                        .rotationEffect(Angle(degrees: -45))
                }
            }
            .rotationEffect(Angle(degrees: 45))
        }
        .position(x: transform.xCoord * screen.width,
                  y: transform.yCoord * screen.height)
        .onTapGesture {
            selected = transform
        }
        .gesture(
            DragGesture()
                .onChanged { gesture in
                    transform.xCoord = gesture.location.x
                    transform.yCoord = gesture.location.y
                }
        )
    }
}

struct MouseAreaView: View {
    @State var transform: KeyModelTransform
    @Binding var selected: KeyModelTransform?

    var body: some View {
        Text("")
            .frame(width: 200, height: 200)
            .background(Circle()
                .stroke(.white, lineWidth: 1)
                .background(Circle().fill(.regularMaterial)))
            .position(x: transform.xCoord * screen.width,
                      y: transform.yCoord * screen.height)
            .onTapGesture {
                selected = transform
            }
            .gesture(
                DragGesture()
                    .onChanged { gesture in
                        transform.xCoord = gesture.location.x
                        transform.yCoord = gesture.location.y
                    }
            )
    }
}

extension Int {
    func keyCodeString() -> String {
        return KeyCodeNames.keyCodes[self]!
    }
}
