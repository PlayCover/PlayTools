# Repository Guidelines（仓库指南）

## 项目结构与模块划分

PlayTools 是供 PlayCover 使用的 Xcode Framework，负责画面控制、按键映射、输入转换及绕过辅助功能。主要源码位于 `PlayTools/`。`PlayTools/Controls/` 负责运行时输入分发与动作执行，`PlayTools/Editor/` 包含游戏内映射编辑界面，`PlayTools/Keymap/` 处理按键名称和布局，`PlayTools/MysticRunes/` 提供绕过与 Swizzle 支持，`PlayTools/Utils/` 存放通用工具。多语言文本位于 `PlayTools/*.lproj/Playtools.strings`，Xcode 项目配置位于 `PlayTools.xcodeproj/`，CocoaPods 元数据位于 `PlayTools.podspec`。

配套的 PlayCover 主项目位于 `/Users/wuhu/code/PlayCover`。涉及 PlayTools 集成、依赖更新、完整应用构建或 DMG 打包时，应同时检查该仓库；仅修改 Framework 内部逻辑时，优先在当前 PlayTools 仓库完成和验证。

## 构建、测试与开发命令

构建 iOS Framework：

```bash
xcodebuild -project PlayTools.xcodeproj -scheme PlayTools -configuration Debug -destination 'generic/platform=iOS' build
```

若本机已安装 SwiftLint，可运行：

```bash
swiftlint
```

测试 PlayCover 集成时，在 `/Users/wuhu/code/PlayCover/Cartfile` 中将依赖指向本仓库、本地分支或标签：

```text
git "file:///path/to/playtools" "branch-or-tag"
```

本地热替换请遵循 README：先构建 iOS 版本，再用 `vtool -set-build-version maccatalyst 11.0 14.0` 修改平台信息，通过 `codesign -fs-` 进行 ad-hoc 签名，最后将 Framework 或二进制复制进 PlayCover。

## 编码风格与命名约定

Swift 代码应与现有文件保持一致：使用 4 空格缩进、清晰的类型名和简洁的方法名。Objective-C 文件采用常规的 `.h`/`.m` 配对。映射模型应使用能说明用途的名称，例如 `RadialSelectorAction`、`ActionDispatcher` 和 `KeyCodeNames`。SwiftLint 配置位于 `.swiftlint.yml`；项目关闭了 `inclusive_language` 和 `todo` 规则，并允许标识符及类型名包含 `_`。

## 测试要求

项目目前没有独立的 XCTest Target。修改后至少完成一次干净的 Xcode 构建，并在 PlayCover 中进行针对性手动测试。按键映射改动需要验证导入导出兼容性、编辑器显示、已保存 `.playmap` 的重新加载，以及真实游戏内的运行行为。修改本地化时，确认对应 `Playtools.strings` 已复制到运行中的应用或通过 PlayCover 正确打包。

## Commit 与 Pull Request 规范

近期提交使用 Conventional Commits 风格的 `feat:`、`fix:`、`merge:` 等前缀。本 Fork 通常使用中英双语摘要，例如 `fix: prioritize radial selector over thumbstick drag / 修复轮盘优先于摇杆拖拽`。每个提交应聚焦单一改动，不要包含生成的构建产物。Pull Request 需说明用户可见的行为变化、手动测试范围和受影响的映射格式；涉及 UI 或编辑器时附上截图或短视频。

## Agent 操作注意事项

不要恢复或覆盖无关的本地修改。仓库中可能存在用户生成的 Xcode Workspace 文件或本地构建产物；编辑前先检查 `git status`，提交时只包含当前任务所需的文件。

任务同时涉及 PlayTools 与 `/Users/wuhu/code/PlayCover` 时，分别检查两个仓库的分支和工作区状态，并分别提交。不要把一个仓库生成的临时依赖、构建产物或签名文件误提交到另一个仓库。
