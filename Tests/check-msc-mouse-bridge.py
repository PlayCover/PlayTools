#!/usr/bin/env python3
"""Isolated unit tests for PlayLoader's MSCWebView mouse-to-touch bridge JS."""

import ast
import json
import re
import shutil
import subprocess
import tempfile
from pathlib import Path


def extract_bridge_js(loader_path: Path) -> str:
    text = loader_path.read_text(encoding="utf-8")
    m = re.search(
        r"#if TARGET_OS_MACCATALYST\s+typedef id \(\*pt_msc_load_html_fn\).*?pt_mscMouseTouchBridgeSource\(void\)\s*\{\s*return\s+((?:\s*@\"[^\"]*\"\n?)+);",
        text,
        re.S,
    )
    if not m:
        raise AssertionError("pt_mscMouseTouchBridgeSource() missing or not gated with #if TARGET_OS_MACCATALYST")
    lines = re.findall(r'@(".*")', m.group(1))
    return "".join(ast.literal_eval(s) for s in lines)


HARNESS_JS = r"""
var _print = (typeof print === "function") ? print : console.log;
var _timers = {};
var _nextTimer = 1;
function setTimeout(fn, _ms) { var id = _nextTimer++; _timers[id] = fn; return id; }
function clearTimeout(id) { delete _timers[id]; }
function flushTimers() {
  var ids = Object.keys(_timers);
  for (var i = 0; i < ids.length; i++) {
    var fn = _timers[ids[i]];
    delete _timers[ids[i]];
    if (fn) fn();
  }
}

function makeTarget() {
  var self = {};
  self.windowListeners = {};
  self.docListeners = {};
  self.dispatched = [];
  self.hidden = false;
  self.protocol = "mscfile:";
  self.isTop = true;

  function addListener(map, type, fn, cap) {
    if (!map[type]) map[type] = [];
    map[type].push({ fn: fn, cap: !!cap });
  }
  function makeElem(tag) {
    return {
      nodeType: 1,
      tagName: tag,
      children: [],
      listeners: {},
      contains: function(other) {
        if (other === this) return true;
        for (var i = 0; i < this.children.length; i++) {
          if (this.children[i].contains(other)) return true;
        }
        return false;
      },
      addEventListener: function(type, fn, cap) { addListener(this.listeners, type, fn, cap); },
      dispatchEvent: function(ev) {
        ev.target = ev.target || this;
        var winL = self.windowListeners[ev.type] || [];
        for (var i = 0; i < winL.length; i++) {
          if (winL[i].cap) {
            winL[i].fn(ev);
            if (ev._stopped) return !ev.defaultPrevented;
          }
        }
        var elL = this.listeners[ev.type] || [];
        for (var j = 0; j < elL.length; j++) {
          elL[j].fn(ev);
          if (ev._stopped) return !ev.defaultPrevented;
        }
        for (var k = 0; k < winL.length; k++) {
          if (!winL[k].cap) winL[k].fn(ev);
        }
        self.dispatched.push({ type: ev.type, target: this.tagName, prevented: ev.defaultPrevented, stopped: !!ev._stopped });
        return !ev.defaultPrevented;
      }
    };
  }
  function makeEvent(type, extra) {
    var ev = Object.assign({
      type: type,
      isTrusted: true,
      defaultPrevented: false,
      _stopped: false,
      preventDefault: function() { this.defaultPrevented = true; },
      stopPropagation: function() { this._stopped = true; }
    }, extra || {});
    return ev;
  }
  self.Touch = function(init) { Object.assign(this, init); };
  self.TouchEvent = function(type, init) {
    var ev = makeEvent(type, init);
    return ev;
  };
  self.body = makeElem("BODY");
  self.makeElem = makeElem;
  self.makeEvent = makeEvent;
  self.location = { get protocol() { return self.protocol; } };
  self.document = {
    get hidden() { return self.hidden; },
    get body() { return self.body; },
    addEventListener: function(type, fn, cap) { addListener(self.docListeners, type, fn, cap); },
    fire: function(ev) {
      var list = self.docListeners[ev.type] || [];
      for (var i = 0; i < list.length; i++) list[i].fn(ev);
    }
  };
  self.window = {
    get top() { return self.isTop ? self.window : {}; },
    location: self.location,
    addEventListener: function(type, fn, cap) { addListener(self.windowListeners, type, fn, cap); },
    fire: function(ev) {
      var list = self.windowListeners[ev.type] || [];
      for (var i = 0; i < list.length; i++) list[i].fn(ev);
      return ev;
    }
  };
  return self;
}

function runInEnv(bridgeSource, fn) {
  var env = makeTarget();
  var runner = new Function(
    "window", "document", "location", "Touch", "TouchEvent", "setTimeout", "clearTimeout",
    bridgeSource + "\n;return function(cb){ return cb(); };"
  );
  runner(env.window, env.document, env.location, env.Touch, env.TouchEvent, setTimeout, clearTimeout);
  fn(env);
}

var results = [];
function check(name, cond, detail) {
  results.push({ name: name, ok: !!cond, detail: detail || "" });
}

// 1. Same mouse gesture click dedup when touchstart/touchend prevents default
runInEnv(BRIDGE_SRC, function(env) {
  var row1 = env.makeElem("ROW1");
  row1.addEventListener("touchend", function(e) { e.preventDefault(); });
  env.window.fire(env.makeEvent("pointerdown", { pointerType: "mouse", pointerId: 1, button: 0, buttons: 1, target: row1, clientX: 10, clientY: 10 }));
  env.window.fire(env.makeEvent("pointerup", { pointerType: "mouse", pointerId: 1, button: 0, buttons: 0, target: row1, clientX: 10, clientY: 10 }));
  var clk = env.window.fire(env.makeEvent("click", { pointerType: "mouse", pointerId: 1, button: 0, detail: 1, target: row1 }));
  check("same_mouse_click_dedup", clk.defaultPrevented && clk._stopped, JSON.stringify(clk));
});

// 2. Keyboard activation in same tick on same target AND ancestor MUST NOT be swallowed
runInEnv(BRIDGE_SRC, function(env) {
  var parent = env.makeElem("PARENT");
  var row1 = env.makeElem("ROW1");
  parent.children.push(row1);
  row1.addEventListener("touchend", function(e) { e.preventDefault(); });
  env.window.fire(env.makeEvent("pointerdown", { pointerType: "mouse", pointerId: 1, button: 0, buttons: 1, target: row1, clientX: 10, clientY: 10 }));
  env.window.fire(env.makeEvent("pointerup", { pointerType: "mouse", pointerId: 1, button: 0, buttons: 0, target: row1, clientX: 10, clientY: 10 }));
  var kbdSelf = env.window.fire(env.makeEvent("click", { pointerType: "", pointerId: -1, button: 0, detail: 0, target: row1 }));
  var kbdAnc = env.window.fire(env.makeEvent("click", { pointerType: "", pointerId: -1, button: 0, detail: 0, target: parent }));
  check("keyboard_activation_not_swallowed",
        !kbdSelf.defaultPrevented && !kbdSelf._stopped && !kbdAnc.defaultPrevented && !kbdAnc._stopped,
        "self=" + kbdSelf.defaultPrevented + " anc=" + kbdAnc.defaultPrevented);
});

// 3. Keydown clears pendingDedup immediately before click
runInEnv(BRIDGE_SRC, function(env) {
  var row1 = env.makeElem("ROW1");
  row1.addEventListener("touchend", function(e) { e.preventDefault(); });
  env.window.fire(env.makeEvent("pointerdown", { pointerType: "mouse", pointerId: 1, button: 0, buttons: 1, target: row1 }));
  env.window.fire(env.makeEvent("pointerup", { pointerType: "mouse", pointerId: 1, button: 0, buttons: 0, target: row1 }));
  env.window.fire(env.makeEvent("keydown", { key: "Enter" }));
  var clk = env.window.fire(env.makeEvent("click", { pointerType: "mouse", pointerId: 1, button: 0, detail: 1, target: row1 }));
  check("keydown_clears_dedup", !clk.defaultPrevented && !clk._stopped);
});

// 4. Different mouse pointerId MUST NOT be swallowed
runInEnv(BRIDGE_SRC, function(env) {
  var row1 = env.makeElem("ROW1");
  row1.addEventListener("touchend", function(e) { e.preventDefault(); });
  env.window.fire(env.makeEvent("pointerdown", { pointerType: "mouse", pointerId: 1, button: 0, buttons: 1, target: row1 }));
  env.window.fire(env.makeEvent("pointerup", { pointerType: "mouse", pointerId: 1, button: 0, buttons: 0, target: row1 }));
  var clkOther = env.window.fire(env.makeEvent("click", { pointerType: "mouse", pointerId: 2, button: 0, detail: 1, target: row1 }));
  check("different_pointerId_not_swallowed", !clkOther.defaultPrevented && !clkOther._stopped);
});

// 5. Rapid consecutive clicks across two rows (both with and without setTimeout flush)
runInEnv(BRIDGE_SRC, function(env) {
  var row1 = env.makeElem("ROW1");
  var row2 = env.makeElem("ROW2");
  var row2Touches = [];
  row1.addEventListener("touchend", function(e) { e.preventDefault(); });
  row2.addEventListener("touchstart", function() { row2Touches.push("start"); });
  row2.addEventListener("touchend", function() { row2Touches.push("end"); });

  env.window.fire(env.makeEvent("pointerdown", { pointerType: "mouse", pointerId: 1, button: 0, buttons: 1, target: row1 }));
  env.window.fire(env.makeEvent("pointerup", { pointerType: "mouse", pointerId: 1, button: 0, buttons: 0, target: row1 }));
  var clk1 = env.window.fire(env.makeEvent("click", { pointerType: "mouse", pointerId: 1, button: 0, detail: 1, target: row1 }));

  env.window.fire(env.makeEvent("pointerdown", { pointerType: "mouse", pointerId: 1, button: 0, buttons: 1, target: row2 }));
  env.window.fire(env.makeEvent("pointerup", { pointerType: "mouse", pointerId: 1, button: 0, buttons: 0, target: row2 }));
  var clk2 = env.window.fire(env.makeEvent("click", { pointerType: "mouse", pointerId: 1, button: 0, detail: 1, target: row2 }));

  check("rapid_consecutive_two_rows",
        clk1.defaultPrevented && row2Touches.join(",") === "start,end" && !clk2.defaultPrevented,
        row2Touches.join(","));
  flushTimers();
});

// 6. Blur / pointercancel / hidden cancels active touch and clears pending dedup
runInEnv(BRIDGE_SRC, function(env) {
  var row1 = env.makeElem("ROW1");
  var cancels = 0;
  row1.addEventListener("touchcancel", function() { cancels++; });
  env.window.fire(env.makeEvent("pointerdown", { pointerType: "mouse", pointerId: 1, button: 0, buttons: 1, target: row1 }));
  env.window.fire(env.makeEvent("blur", {}));
  env.window.fire(env.makeEvent("pointerdown", { pointerType: "mouse", pointerId: 1, button: 0, buttons: 1, target: row1 }));
  env.window.fire(env.makeEvent("pointercancel", { pointerType: "mouse", pointerId: 1 }));
  env.window.fire(env.makeEvent("pointerdown", { pointerType: "mouse", pointerId: 1, button: 0, buttons: 1, target: row1 }));
  env.hidden = true;
  env.document.fire(env.makeEvent("visibilitychange", {}));
  check("cancel_blur_visibility_cleanup", cancels === 3, "cancels=" + cancels);
});

// 7. Native touch pointerType ignored (no synthetic TouchEvent)
runInEnv(BRIDGE_SRC, function(env) {
  var row1 = env.makeElem("ROW1");
  var synthCount = 0;
  row1.addEventListener("touchstart", function() { synthCount++; });
  row1.addEventListener("touchend", function() { synthCount++; });
  env.window.fire(env.makeEvent("pointerdown", { pointerType: "touch", pointerId: 10, button: 0, buttons: 1, target: row1 }));
  env.window.fire(env.makeEvent("pointerup", { pointerType: "touch", pointerId: 10, button: 0, buttons: 0, target: row1 }));
  check("native_touch_ignored", synthCount === 0, "synthCount=" + synthCount);
});

// 8. Scope guard blocks non-mscfile and subframes
(function() {
  var httpsEnv = makeTarget();
  httpsEnv.protocol = "https:";
  new Function("window", "document", "location", "Touch", "TouchEvent", "setTimeout", "clearTimeout", BRIDGE_SRC)(
    httpsEnv.window, httpsEnv.document, httpsEnv.location, httpsEnv.Touch, httpsEnv.TouchEvent, setTimeout, clearTimeout
  );
  var subEnv = makeTarget();
  subEnv.isTop = false;
  new Function("window", "document", "location", "Touch", "TouchEvent", "setTimeout", "clearTimeout", BRIDGE_SRC)(
    subEnv.window, subEnv.document, subEnv.location, subEnv.Touch, subEnv.TouchEvent, setTimeout, clearTimeout
  );
  check("scope_guard_https_and_subframe",
        !httpsEnv.window.__ptMscMouseTouchBridgeInstalled && !subEnv.window.__ptMscMouseTouchBridgeInstalled);
})();

_print(JSON.stringify(results));
"""


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    loader = repo_root / "PlayTools" / "PlayLoader.m"
    bridge_js = extract_bridge_js(loader)

    jsc = Path("/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Helpers/jsc")
    node = shutil.which("node")
    if jsc.is_file():
        runner = [str(jsc)]
    elif node and Path(node).is_file():
        runner = [node]
    else:
        raise RuntimeError("Neither jsc nor node runtime available")

    combined = f"var BRIDGE_SRC = {json.dumps(bridge_js)};\n{HARNESS_JS}"
    with tempfile.NamedTemporaryFile("w", suffix=".js", encoding="utf-8", delete=True) as tmp:
        tmp.write(combined)
        tmp.flush()
        proc = subprocess.run(runner + [tmp.name], capture_output=True, text=True, check=False)

    if proc.returncode != 0:
        print(f"JS runner failed ({proc.returncode}): {proc.stdout} {proc.stderr}")
        return 1

    results = json.loads(proc.stdout.strip().splitlines()[-1])
    failed = [r for r in results if not r["ok"]]
    print(f"MSC Mouse Bridge Tests ({Path(runner[0]).name}): {len(results) - len(failed)}/{len(results)} PASS")
    for r in results:
        status = "PASS" if r["ok"] else "FAIL"
        suffix = f" ({r['detail']})" if r.get("detail") else ""
        print(f"  {status} {r['name']}{suffix}")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
