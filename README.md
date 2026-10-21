# dsh-computer-use

A **DeepSeek Harness (DSH) plugin** that gives the agent eyes and hands on a Windows desktop: screenshots, mouse, keyboard, window control — plus a small always-on-top indicator so you can see when the agent is driving.

[中文说明见下方](#中文说明)

---

## What it does

Registers a single `computer` tool with the Host:

| action | meaning |
|---|---|
| `screenshot` | capture the whole screen or one window to a PNG |
| `windows` | list visible top-level windows (hwnd, title, process, rect) |
| `focus` | bring a window to the foreground |
| `click` / `move` / `drag` / `scroll` | mouse input at absolute screen coordinates |
| `type` | paste text into the focused field (clipboard based, CJK safe) |
| `key` | press a `+` chord such as `ctrl+s`, `alt+tab` |
| `cursor` / `screen` | read pointer position / virtual screen size |
| `wait` | sleep |

The agent loop is: `windows` → `focus` → `screenshot` → read the image with the `read_image` tool → `click`/`type` at measured coordinates → screenshot again.

## Requirements

- Windows 10/11
- DSH with the `plugin_manager` tool available
- Windows PowerShell 5.1 (built in, no extra install)

## Install

```powershell
# from DSH, ask the agent:
#   install the bundle at D:\path\to\dsh-computer-use
```

or with the `plugin_manager` tool:

```json
{ "action": "install_bundle", "target": "D:\\path\\to\\dsh-computer-use" }
```

The bundle adds one entry (`computer-use`) to the current profile. Toggle it with `set_bundle` if needed.

## The indicator

`indicator.ps1` starts a borderless, click-through, always-on-top pill in the bottom-right corner. It fades in while a tool call runs, shows the current action, and fades out about a second later.

- **Scale**: right-click the tray icon → 提示框大小 → 75% / 100% / 125% / 150% / 200%. The choice is stored in `%LOCALAPPDATA%\dsh-computer\hud.json`.
- The window is `WS_EX_TRANSPARENT | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW`, so it never swallows a click and never steals focus.
- It is deliberately captured by screenshots too — that is how the agent proves it was working.

## Files

```
index.js          tool registration + helper process plumbing
ui.ps1            native layer: GDI capture, user32 input, window enumeration
indicator.ps1     the desktop pill + tray menu
cordis.patch.yml  bundle patch
locale/           en + zh display metadata
icon.svg          plugin icon
```

## Notes and limits

- Coordinates are **physical screen pixels**; the helper calls `SetProcessDPIAware()` so 125%/150% scaling does not shift clicks.
- `type` goes through the clipboard and restores the previous contents, so Chinese and emoji work.
- Fullscreen-exclusive games, UAC-elevated windows and some anti-cheat protected apps ignore synthetic input. The tool reports what it attempted; it does not detect that the input was swallowed.
- Everything runs locally. No telemetry, no network calls.

## License

MIT

---

## 中文说明

给 **DeepSeek Harness** 用的桌面操控插件。装好之后 Agent 多一个 `computer` 工具，能截屏、点击、拖拽、滚轮、输入文字、按组合键、枚举和切换窗口。

右下角会浮出一个小胶囊提示（`DeepSeek 正在操作电脑 · 输入文字`），鼠标可以穿透，不会抢焦点；右键托盘图标可以调 75%~200% 缩放。

**安装**：让 Agent 用 `plugin_manager` 的 `install_bundle`，`target` 指向本目录即可。

**已知限制**：
- 独占全屏的游戏、UAC 提权窗口会吞掉模拟输入；
- 每一步都要截图确认，比人慢很多；
- 自动化精度取决于模型看图估坐标的能力，精细拖拽不靠谱。
