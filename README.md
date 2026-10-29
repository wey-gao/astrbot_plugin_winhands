# 桌面之手 (astrbot_plugin_winhands)

让 AstrBot 里的模型**真正操作 Windows 桌面**：看屏幕、动鼠标、敲键盘、切窗口。

不是靠猜坐标——模型可以截图看画面、读窗口矩形、按按钮的名字点击，
像人一样一步步确认再动手。

## 它解决什么问题

大部分"桌面助手"只能截图给模型看，看完就没法动；能动的又只能盲点坐标。
这个插件把两件事接起来：

1. **看得见**：截图以图片形式直接进模型上下文（走 MCP `ImageContent`），模型真的"看到"画面。
2. **动得了**：鼠标、键盘、窗口都走真实输入事件（`SendInput` + UI Automation），
   对浏览器、记事本、Electron 客户端、游戏启动器都有效。

## 能力清单

| 工具 | 作用 |
| --- | --- |
| `pc_screen_info` | 屏幕尺寸、鼠标位置、当前前台窗口 |
| `pc_screenshot` | 截图并返回图片，可只截一块区域、可缩放 |
| `pc_mouse_move` | 移动鼠标，带平滑步进 |
| `pc_click` | 左/右/中键点击，可指定坐标 |
| `pc_type_text` | 输入文字，中文和全角标点都支持 |
| `pc_press_key` | 组合键：`CTRL+S`、`ALT+F4`、`WIN+R`、`F5` … |
| `pc_list_windows` | 列出所有窗口、进程、PID、矩形 |
| `pc_window_rect` | 拿单个窗口的位置和大小 |
| `pc_focus_window` | 把窗口切到前台并校验是否成功 |
| `pc_find_controls` | 列出窗口里所有按钮（名字 + 坐标） |
| `pc_click_control` | 按按钮名字点击，不用算坐标 |
| `pc_close_window` | 关窗口 |

指令：

- `/winhands` — 查看状态
- `/winhands_shot` — 截一张屏发到对话里

## 安装

在 AstrBot 插件管理里用仓库地址安装：

```
https://github.com/wey-gao/astrbot_plugin_winhands
```

或者手动丢进 `data/plugins/astrbot_plugin_winhands/`，重启 AstrBot。

要求：

- AstrBot **>= 4.28.0**
- Windows 10 / 11，系统自带 Windows PowerShell 5.1
- 无第三方 Python 依赖

## 配置

| 项 | 默认 | 说明 |
| --- | --- | --- |
| `enabled` | `true` | 总开关 |
| `allow_users` | `[]` | 允许操作电脑的 QQ 号白名单，**建议一定填** |
| `screenshot_max_width` | `1280` | 截图宽度，越小越省 token |
| `text_max_length` | `2000` | 单次输入字数上限 |
| `timeout` | `60` | 单次操作超时秒数 |
| `powershell` | `powershell` | 可换成 `pwsh` |

## 用法示例

> 你：打开记事本，把我说的记下来
>
> 模型：*pc_press_key(WIN+R) → pc_type_text(notepad) → pc_press_key(ENTER) → pc_focus_window(Notepad) → pc_type_text(...)*

> 你：看看我现在屏幕上那个报错是啥
>
> 模型：*pc_screenshot()* → 读图 → 回答

## 安全须知

**这个插件等于把键鼠交给模型。** 它能点任何按钮、打任何字、关任何窗口。

- `allow_users` 一定设成自己的 QQ 号，别留空。
- 不建议在多人共用、或者公网可访问的机器人上开。
- 插件不记录上屏内容，但截图会落在系统临时目录，一小时后由 `terminate` 清理。
- 敏感操作（转账、删除）请自己去确认，别让模型闭环操作。

## 实现说明

- `winctl.ps1` 负责所有底层动作，每个子命令输出一行 JSON；
- `main.py` 只做编排、鉴权、把 JSON 转成对话内容；
- 子进程一律 `CREATE_NO_WINDOW`，不会弹黑框；
- 截图默认缩到 1280 宽，避免把几 MB 的 PNG 塞进上下文；
- 组合键按下/释放之间留了真实间隔，`ALT+F4` 这类才不会丢。

## License

MIT
