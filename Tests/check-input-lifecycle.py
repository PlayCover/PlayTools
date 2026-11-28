#!/usr/bin/env python3
"""Test production swipe ownership and thumbstick focus handling with transport stubs.

Run on macOS with Xcode: python3 Tests/check-input-lifecycle.py
An optional --source points to an older PlayAction.swift for a before/after check.
"""
import argparse
import subprocess
import tempfile
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source', type=Path, default=Path(__file__).resolve().parents[1] /
                    'PlayTools/Controls/Backend/Action/PlayAction.swift')
parser.add_argument('--allow-retained', action='store_true', help='Inspect a known-bad baseline without asserting release')
args = parser.parse_args()
source = args.source.read_text()
body = source[source.index('class SwipeAction:'):source.index('\nclass FakeMouseAction:')]
stubs = r'''
import Foundation
import CoreGraphics
protocol Action { func invalidate() }
enum UITouch { enum Phase { case began, moved, ended } }
enum PlayInput { static let touchQueue = DispatchQueue(label: "timer-lifecycle-test") }
struct Screen { let width: CGFloat = 1000; let height: CGFloat = 1000 }
let screen = Screen()
enum Toucher {
    static var begins = 0, ends = 0
    static func touchcam(point: CGPoint, phase: UITouch.Phase, tid: inout Int?, actionName: String, keyName: String) {
        switch phase {
        case .began: begins += 1; tid = 1
        case .ended: ends += 1; tid = nil
        case .moved: break
        }
    }
}
'''
checks = r'''
final class WeakAction { weak var value: SwipeAction?; init(_ value: SwipeAction) { self.value = value } }
var references: [WeakAction] = []
PlayInput.touchQueue.sync {
    for _ in 0..<1000 {
        let action = SwipeAction(actionName: "probe", keyName: "probe")
        references.append(WeakAction(action))
    }
}
PlayInput.touchQueue.sync {}
let retainedIdle = references.filter { $0.value != nil }.count
var active: SwipeAction?
PlayInput.touchQueue.sync {
    active = SwipeAction(actionName: "probe", keyName: "probe")
    active!.move(from: { CGPoint(x: 500, y: 500) }, deltaX: 1, deltaY: 1)
}
let deadline = Date().addingTimeInterval(0.9)
while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
PlayInput.touchQueue.sync { active!.invalidate() }
PlayInput.touchQueue.sync {}
let activeWeak = WeakAction(active!)
active = nil
PlayInput.touchQueue.sync {}
Thread.sleep(forTimeInterval: 0.05)
PlayInput.touchQueue.sync {
    print("{\"retainedIdle\":\(retainedIdle),\"retainedActive\":\(activeWeak.value != nil),\"begins\":\(Toucher.begins),\"ends\":\(Toucher.ends)}")
    precondition(Toucher.begins == 1 && Toucher.ends == 1, "Touch lifecycle changed")
    if !CommandLine.arguments.contains("--allow-retained") {
        precondition(retainedIdle == 0 && activeWeak.value == nil, "Input actions leaked")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='playtools-input-lifecycle-') as directory:
    work = Path(directory)
    (work / 'main.swift').write_text(stubs + body + checks)
    subprocess.run(['/usr/bin/xcrun', 'swiftc', '-O', str(work / 'main.swift'), '-o', str(work / 'probe')], check=True)
    subprocess.run([str(work / 'probe'), *(['--allow-retained'] if args.allow_retained else [])], check=True)

    controller_source = (Path(__file__).resolve().parents[1] /
                         'PlayTools/Controls/Frontend/EventAdapter/Controller/Instances/TouchscreenControllerEventAdapter.swift').read_text()
    controller_body = controller_source[controller_source.index('class ThumbstickCursorControl {'):]
    controller_stubs = r'''
import Foundation
import CoreGraphics
final class PlayInput {
    static let shared = PlayInput()
    static let touchQueue = DispatchQueue(label: "thumbstick-lifecycle-test")
    var acceptsControllerInput = true
}
enum ActionDispatcher {
    static var count = 0
    static func dispatch(key: String, valueX: CGFloat, valueY: CGFloat) -> Bool { count += 1; return true }
}
'''
    controller_checks = r'''
let cursor = ThumbstickCursorControl("probe")
PlayInput.touchQueue.sync { cursor.update(velocityX: 1, velocityY: 0) }
Thread.sleep(forTimeInterval: 0.1)
PlayInput.touchQueue.sync { PlayInput.shared.acceptsControllerInput = false }
Thread.sleep(forTimeInterval: 0.06)
let first = PlayInput.touchQueue.sync { ActionDispatcher.count }
Thread.sleep(forTimeInterval: 0.1)
let hidden = PlayInput.touchQueue.sync { ActionDispatcher.count }
PlayInput.touchQueue.sync {
    PlayInput.shared.acceptsControllerInput = true
    cursor.update(velocityX: 1, velocityY: 0)
}
Thread.sleep(forTimeInterval: 0.1)
let resumed = PlayInput.touchQueue.sync { ActionDispatcher.count }
cursor.update(velocityX: 0, velocityY: 0)
Thread.sleep(forTimeInterval: 0.06)
let burstStart = PlayInput.touchQueue.sync { ActionDispatcher.count }
DispatchQueue.concurrentPerform(iterations: 1000) { _ in cursor.update(velocityX: 1, velocityY: 0) }
Thread.sleep(forTimeInterval: 0.1)
let afterBurst = PlayInput.touchQueue.sync { ActionDispatcher.count }
precondition(afterBurst - burstStart <= 15, "Concurrent callbacks created duplicate polling workers")
PlayInput.touchQueue.sync { cursor.update(velocityX: 0, velocityY: 0) }
Thread.sleep(forTimeInterval: 0.06)
print("{\"backgroundDispatches\":\(hidden-first),\"resumed\":\(resumed > hidden),\"singleWorkerAfterConcurrentBurst\":true}")
precondition(first > 0 && hidden == first && resumed > hidden, "Controller polling did not stop and resume")
'''
    (work / 'main.swift').write_text(controller_stubs + controller_body + controller_checks)
    subprocess.run(['/usr/bin/xcrun', 'swiftc', '-O', str(work / 'main.swift'), '-o', str(work / 'controller')], check=True)
    subprocess.run([str(work / 'controller')], check=True)
