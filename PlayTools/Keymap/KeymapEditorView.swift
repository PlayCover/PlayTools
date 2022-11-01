//
//  KeymapEditorView.swift
//  PlayTools
//
//  Created by Isaac Marovitz on 31/10/2022.
//

import SwiftUI

struct KeymapEditorView: View {
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
            ForEach(Array(Keymapping.shared.keymapData.buttonModels.enumerated()), id: \.offset) { index, element in
                ButtonView(xCoord: Binding(get: {
                                                Keymapping.shared.keymapData.buttonModels[index].transform.xCoord * screen.width
                                            }, set: {
                                                Keymapping.shared.keymapData.buttonModels[index].transform.xCoord = $0 / screen.width
                                                Keymapping.shared.encode()
                                            }),
                           yCoord: Binding(get: {
                                                Keymapping.shared.keymapData.buttonModels[index].transform.yCoord * screen.height
                                            }, set: {
                                                Keymapping.shared.keymapData.buttonModels[index].transform.yCoord = $0 / screen.height
                                                Keymapping.shared.encode()
                                            }),
                           size: element.transform.size * 10,
                           key: element.keyCode.keyCodeString())
            }
            /*ForEach(Keymapping.shared.keymapData.draggableButtonModels, id: \.transform, content: { data in
                ButtonView(xCoord: data.transform.xCoord * screen.width,
                           yCoord: data.transform.yCoord * screen.height,
                           size: data.transform.size * 10,
                           key: data.keyCode.keyCodeString())
            })*/
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
        .ignoresSafeArea(.all)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ButtonView: View {
    @Binding var xCoord: CGFloat
    @Binding var yCoord: CGFloat
    @State var size: CGFloat

    @State var key: String

    var body: some View {
        Text(key)
            .frame(width: 80, height: 80)
            .background(Circle()
                .stroke(.white, lineWidth: 1)
                .background(Circle().fill(.regularMaterial)))
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
        Text("")
            .frame(width: 200, height: 200)
            .background(Circle()
                .stroke(.white, lineWidth: 1)
                .background(Circle().fill(.regularMaterial)))
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
