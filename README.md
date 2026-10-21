# dsh-computer-use

给 DeepSeek Harness 加一个 `computer` 工具，让 Agent 能真的看一眼屏幕、点一下鼠标。

## 起因

Agent 平时只会跑命令、改文件。碰上"帮我把这个窗口里的按钮点掉"就卡住了——它没有眼睛，也没有手。这插件就是给它补上这两样。

写完之后发现一个副作用：它现在会去点真实的桌面，点错了就是错了。所以又加了个提示条，至少你能看见它在动。

## 能干什么

就一个工具，十来种动作：

截屏、列窗口、切到某个窗口、点、拖、滚轮、打字、按组合键、读光标位置、干等。

用起来没什么玄机，就是**截屏 → 看图 → 算坐标 → 点 → 再截屏确认**。笨，但管用。

打字走的是剪贴板（复制进去再按 Ctrl+V），所以中文和 emoji 都能打，不会变成问号。

## 屏幕上那个小胶囊

操作的时候，右下角会浮出一条黑色的，写着 `DeepSeek 正在操作电脑 · 输入文字`，一秒后自己淡掉。

几个当时特意处理过的地方：

- **点它不会挡路**：加了 `WS_EX_TRANSPARENT`，鼠标直接穿过去
- **不抢焦点**：`WS_EX_NOACTIVATE`，不会把正在打字的窗口顶到后面
- **能调大小**：右键托盘图标，75% 到 200%
- **出现在截图里**：这是故意的。我截的图里如果有它，就说明那一刻我确实在操作

## 装

用 `plugin_manager`：

```json
{ "action": "install_bundle", "target": "D:\\path\\to\\dsh-computer-use" }
```

Windows，DSH，自带的 PowerShell 5.1，没别的依赖。

## 不好使的地方

这些是实测出来的，不是免责声明：

- **慢**。每步都要截一次图，二十步的操作要跑三五分钟，比人慢一个数量级
- **不准**。坐标靠看图估，差几个像素是常事。拖拽调参数这种精细活基本别指望
- **会被吞**。独占全屏的游戏、UAC 弹窗、带反作弊的程序，输入发出去没反应。工具只会老实报告"我点了"，点没点中它并不知道
- **瞎**。没有无障碍树，纯靠像素。屏幕上没画出来的东西它一概不知

## 文件

```
index.js          注册工具，管理子进程
ui.ps1            原生长手：GDI 截屏、user32 输入、窗口枚举
indicator.ps1     那个悬浮条，顺带托盘菜单
cordis.patch.yml  bundle 声明
locale/           中英文显示信息
icon.svg
```

## License

MIT

---

## English, briefly

A DeepSeek Harness plugin that gives the agent a `computer` tool: screenshot, list/focus windows, click, drag, scroll, type, press keys.

The loop is dumb on purpose — grab a screenshot, look at it, work out the coordinates, click, screenshot again to check. It is slow (minutes for a couple of dozen steps) and imprecise (coordinates are eyeballed from pixels, so fine drags are unreliable). Fullscreen games, UAC prompts and anti-cheat programs simply swallow synthetic input.

A small always-on-top pill appears while a call runs, so you can see when the agent is driving. It is click-through and never takes focus, its size is adjustable from the tray menu, and it shows up in screenshots on purpose — that is the evidence that something actually happened.

Windows only. MIT.
