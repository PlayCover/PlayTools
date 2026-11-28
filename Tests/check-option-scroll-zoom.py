#!/usr/bin/env python3
"""Contract test for Option + Scroll Wheel -> Two-Finger Pinch Zoom math & sub-stepping."""
import subprocess
import tempfile
from pathlib import Path

source_path = (
    Path(__file__).resolve().parents[1]
    / "PlayTools"
    / "Controls"
    / "OptionScrollZoomController.swift"
)
source = source_path.read_text(encoding="utf-8")
start_marker = "// MARK: - OptionScrollZoomMath"
end_marker = "// MARK: - OptionScrollZoomController"
math_body = source[source.index(start_marker):source.index(end_marker)]

harness = r'''
import CoreGraphics
import Foundation

''' + math_body + r'''

func assertPointInside(_ point: CGPoint, _ rect: CGRect, _ label: String) {
    precondition(
        point.x >= rect.minX - 0.01 && point.x <= rect.maxX + 0.01 &&
        point.y >= rect.minY - 0.01 && point.y <= rect.maxY + 0.01,
        "\(label): point \(point) escaped safe rect \(rect)"
    )
}

// 1. Multiplicative zoom factor scaling, direction, and clamping
precondition(OptionScrollZoomMath.zoomFactor(deltaY: 1.0, isPrecise: false) > 1.15, "Discrete +1 zooms in")
precondition(OptionScrollZoomMath.zoomFactor(deltaY: -1.0, isPrecise: false) < 0.87, "Discrete -1 zooms out")
precondition(
    abs(OptionScrollZoomMath.zoomFactor(deltaY: 1.0, isPrecise: false)
        * OptionScrollZoomMath.zoomFactor(deltaY: -1.0, isPrecise: false) - 1.0) < 0.001,
    "Opposite deltas are multiplicative inverses"
)
precondition(
    OptionScrollZoomMath.zoomFactor(deltaY: 10.0, isPrecise: false)
        == OptionScrollZoomMath.zoomFactor(deltaY: 3.5, isPrecise: false),
    "Discrete positive clamp"
)
precondition(
    OptionScrollZoomMath.zoomFactor(deltaY: -10.0, isPrecise: false)
        == OptionScrollZoomMath.zoomFactor(deltaY: -3.5, isPrecise: false),
    "Discrete negative clamp"
)
precondition(OptionScrollZoomMath.zoomFactor(deltaY: .nan, isPrecise: false) == 1.0, "NaN delta guard")
precondition(OptionScrollZoomMath.zoomFactor(deltaY: 10.0, isPrecise: true) > 1.10, "Precise trackpad zoom in")
precondition(OptionScrollZoomMath.zoomFactor(deltaY: -10.0, isPrecise: true) < 0.90, "Precise trackpad zoom out")

// 2. Portrait (414x896) and large landscape (920x780, Baidu Map) anchors
let portrait = CGRect(x: 0, y: 0, width: 414, height: 896)
let landscape = CGRect(x: 0, y: 0, width: 920, height: 780)

guard let pIn = OptionScrollZoomMath.computeAnchor(
    cursor: CGPoint(x: 207, y: 448), bounds: portrait, deltaY: 1
) else { fatalError("Expected portrait zoom-in anchor") }
precondition(pIn.center == CGPoint(x: 207, y: 448), "Center cursor should not shift")
precondition(pIn.startRadius == 60.0, "Zoom-in starts at 60pt")
precondition(pIn.minRadius == 32.0, "Minimum radius keeps >= 64pt two-finger span")

guard let lOut = OptionScrollZoomMath.computeAnchor(
    cursor: CGPoint(x: 460, y: 390), bounds: landscape, deltaY: -3
) else { fatalError("Expected landscape zoom-out anchor") }
precondition(lOut.startRadius == 180.0, "Large-window zoom-out starts wide at 180pt")
precondition(lOut.startRadius - lOut.minRadius >= 140.0, "Large-window zoom-out has generous runway")

// 3. Fast zoom-out regression check (Baidu Map: deltaY = -2 x4 ticks & deltaY = -3 x3 ticks):
//    Every individual frame must shrink by <= 16.5% and <= 24.5pt, and 4x deltaY=-2 completes with 0 re-anchors!
var current = lOut.startRadius
var target = lOut.startRadius
var firstMove = true
var totalFrames = 0
for _ in 0..<4 {
    target = OptionScrollZoomMath.targetRadius(from: target, deltaY: -2, isPrecise: false, anchor: lOut)
    while abs(target - current) > 0.5 {
        let next = OptionScrollZoomMath.nextFrameRadius(current: current, target: target, isFirstMove: firstMove)
        let ratio = next / current
        precondition(ratio >= 0.835 && ratio < 1.0, "Single-frame shrink too aggressive: \(current) -> \(next) (ratio=\(ratio))")
        precondition(current - next <= 24.5, "Single-frame point drop too large: \(current - next)")
        current = next
        firstMove = false
        totalFrames += 1
        precondition(totalFrames < 60, "Sub-stepper did not converge")
    }
}
precondition(current > lOut.minRadius, "4x deltaY=-2 on 920x780 should finish above minRadius without reanchor churn (r=\(current))")
precondition(current < lOut.startRadius * 0.35, "4x deltaY=-2 should achieve strong zoom-out scale (r=\(current))")

// 4. Single discrete notch emits >= 2 moved frames (initial kick + final target) for UIPinchGestureRecognizer
let oneUpTarget = OptionScrollZoomMath.targetRadius(from: pIn.startRadius, deltaY: 1, isPrecise: false, anchor: pIn)
let oneUpKick = OptionScrollZoomMath.nextFrameRadius(current: pIn.startRadius, target: oneUpTarget, isFirstMove: true)
precondition(oneUpKick > pIn.startRadius && oneUpKick < oneUpTarget, "Single +1 notch emits intermediate kick")

let oneDownTarget = OptionScrollZoomMath.targetRadius(from: lOut.startRadius, deltaY: -1, isPrecise: false, anchor: lOut)
let oneDownKick = OptionScrollZoomMath.nextFrameRadius(current: lOut.startRadius, target: oneDownTarget, isFirstMove: true)
precondition(oneDownKick < lOut.startRadius && oneDownKick > oneDownTarget, "Single -1 notch emits intermediate kick")

// 5. Corner cursor clamping guarantees both fingers stay inside safeRect across [minRadius, maxRadius]
for rect in [portrait, landscape] {
    let safeRect = rect.insetBy(dx: 16, dy: 16)
    for corner in [
        CGPoint(x: 2, y: 2),
        CGPoint(x: rect.maxX - 2, y: 2),
        CGPoint(x: 2, y: rect.maxY - 2),
        CGPoint(x: rect.maxX - 2, y: rect.maxY - 2)
    ] {
        for deltaY in [CGFloat(3), CGFloat(-3)] {
            guard let anchor = OptionScrollZoomMath.computeAnchor(
                cursor: corner, bounds: rect, deltaY: deltaY
            ) else { fatalError("Corner \(corner) in \(rect) should produce valid anchor") }
            for radius in [anchor.minRadius, anchor.startRadius, anchor.maxRadius] {
                let (first, second) = OptionScrollZoomMath.fingerPoints(center: anchor.center, radius: radius)
                assertPointInside(first, safeRect, "rect \(rect.size) corner \(corner) r=\(radius) first")
                assertPointInside(second, safeRect, "rect \(rect.size) corner \(corner) r=\(radius) second")
            }
        }
    }
}

// 6. Tiny window safely declines instead of generating invalid/out-of-bounds touches
precondition(
    OptionScrollZoomMath.computeAnchor(
        cursor: CGPoint(x: 15, y: 15),
        bounds: CGRect(x: 0, y: 0, width: 60, height: 60),
        deltaY: 1
    ) == nil,
    "Tiny window must return nil"
)

print("{\"optionScrollZoomMathOK\":true,\"portraitInStart\":\(pIn.startRadius),\"landscapeOutStart\":\(lOut.startRadius),\"framesFor4xMinus2\":\(totalFrames)}")
'''

with tempfile.TemporaryDirectory(prefix="playtools-option-scroll-zoom-") as directory:
    work = Path(directory)
    (work / "main.swift").write_text(harness, encoding="utf-8")
    subprocess.run(
        ["/usr/bin/xcrun", "swiftc", "-O", str(work / "main.swift"), "-o", str(work / "probe")],
        check=True,
    )
    subprocess.run([str(work / "probe")], check=True)
