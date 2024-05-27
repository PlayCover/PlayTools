# PlayTools

PlayTools is an essential part of [PlayCover](https://github.com/PlayCover/PlayCover). PlayTools implements core functions of PlayCover, including display control, key mapping and bypassing.

## Display Control

<!-- iOS APPs running on macOS usually have fixed display settings, which may not be suitable for the user's needs. PlayTools allows you to adjust the display settings of the game, so that you can enjoy the game in a more comfortable way. -->

PlayTools allows you to control:

- Resolution: Supports 1080p, 4k, 1440p and custom resolution
- Aspect Ratio: Supports 16:9, 16:10, 4:3 and custom aspect ratio
- Scale Factor: Supports custom scale factor (e.g. 1.0, 1.5, 2.0)
- Display Orientation: Supports manually rotating the game window during game play.

## Key Mapping

PlayTools provides a key mapping tool to map game actions to the keyboard, mouse or controller.

Supported input devices include:

- Keyboard
- Mouse
- Controller

Input from these devices can be mapped to these in-game actions:

- Button
- Joystick (e.g. WASD)
- Camera Control (usually by mouse)
- Draggable Button (e.g. wheel menu selection)

More mapping options such as swiping will be added in the future.

## Bypassing

Games designed for iOS devices may not work properly on macOS. PlayTools provides a solution to bypass these issues.

### Jailbreak Bypassing

Some games refuse to work on macOS because they detect the environment as a jailbroken device. PlayTools hijacks the detection process of popular jailbreak detection tools, so that the game will think it is running on a non-jailbroken device.

PlayTools also allows per-game configuration for more advanced jailbreak bypassing techniques.

### PlayChain

PlayChain is a tool that solves key chain issues by replacing the game's key chain with a custom one. Key chain issues usually prevent the game from logging in.

### Introspection Library

Some games only work under debug environment. By inserting the Introspection Library, PlayTools tricks the game into thinking it is running under debug environment.

# How to Use

PlayTools is shipped with PlayCover, and is installed together with the game. You do not need to install PlayTools manually.

PlayTools provides in-game menus mostly for key mapping setup. Other features are accessible through the PlayCover settings menu.

Localization is handled in [Weblate](https://hosted.weblate.org/projects/playcover/).

# How it Works

PlayTools runs alongside of the game. During IPA installation, PlayTools is inserted into the game's executable. When the game is launched, PlayTools will be launched together.

PlayTools uses swizzle techniques to replace framework methods and system calls with the versions provided by PlayTools. During game play, PlayTools intercepts game input events and translates them to the corresponding touch events and feed them to the game.

# How to Build

PlayTools is built using Xcode.

## Production Build
In release builds, the building script of PlayCover will automatically fetch the latest version of PlayTools from the official repository and build it. Generally, you do not need to build PlayTools manually.

If you want to build PlayCover with a specific version of PlayTools, mostly for testing purposes, you can change the [Cartfile](https://github.com/PlayCover/PlayCover/blob/develop/Cartfile) of PlayCover to point to the specific version of PlayTools. You can specify which branch/tag of which repository to build from.

## Development Build
PlayTools can also be built separately. This is useful when you want to modify the source code.

To do so, 

1. Clone the PlayTools repository.

1. Open the PlayTools project in Xcode.

1. Set the development team in the Xcode project settings. Both `PlayTools` and `AKInterface` targets need to be set. You may need to create a development team first.

1. Build PlayTools towards iOS platform. This will create a `PlayTools.framework` in the build directory.

2. Transform the target platform to Mac Catalyst. Run this script in the build directory:
```bash
#!/bin/sh
echo "Converting to maccatalyst"
vtool \
	-set-build-version maccatalyst 11.0 14.0 \
	-replace -output \
	"PlayTools.framework/PlayTools" \
	"PlayTools.framework/PlayTools"

echo "Codesigning PlayTools"
codesign -fs- "PlayTools.framework/PlayTools"
```

2. Copy the `PlayTools.framework` into the PlayCover App, and replace the old one.
```bash
cp "PlayTools.framework" "PlayCover.app/Contents/Frameworks/PlayTools.framework"
```

3. Relaunch PlayCover.

### Temporary Build

If you are debugging and testing your own code, relaunching PlayCover every time you make a change is a bit annoying. 

In most cases, you can just copy the `PlayTools.framework/PlayTools` to `~/Library/Frameworks/PlayTools.framework/` instead of the whole `PlayTools.framework` directory, and avoid relaunching PlayCover:

```bash
cp "PlayTools.framework/PlayTools" "~/Library/Frameworks/PlayTools.framework/"
```
This change will be lost when you relaunch PlayCover.

If you modified `AKInerface` or added localization strings, you also need to copy them into the game you're testing on. This will be overwritten when you launch the game through PlayCover. You can launch the game from Finder to avoid this.

# Products

## PlayTools

The main part of PlayTools. This ends up as a dynamic library. This part is built towards iOS platform because it uses iOS APIs that are not available on Mac Catalyst.

## AKInerface

A bridge that encapsulates native macOS APIs to expose an interface for PlayTools. This includes manipulating mouse and keyboard events, controlling cursor and application state, and reading window information.

## Localizable Strings

Localizations for PlayTools are tricky. As PlayTools runs as a dynamic library inside the game, localizable strings must be copied into the game to take effect. This is done during IPA installation and every launch of the game through PlayCover.

To avoid conflicting with the game's own localizable strings, PlayTools' localizable strings are renamed to `PlayTools.strings`, instead of the default `Localizable.strings`.

