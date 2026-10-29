# -*- coding: utf-8 -*-
"""AstrBot 插件: 桌面之手 (winhands)

让 LLM / 用户直接操作 Windows 桌面：看屏幕、移动鼠标、点击、打字、按快捷键、
读写窗口。所有输入走真实输入事件（SendInput），因此对绝大多数桌面程序有效。

设计取舍:
- 只支持 Windows。依赖系统自带的 Windows PowerShell 5.1，不引入任何第三方包。
- 操作逻辑放在同目录的 winctl.ps1 里，本文件只负责编排、鉴权和把结果写进对话。
- 子进程一律 CREATE_NO_WINDOW，不弹黑色控制台窗口。
- 高危操作（点哪、打什么）完全由调用方决定，插件本身不做猜测。
"""

from __future__ import annotations

import asyncio
import base64
import json
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

from mcp.types import CallToolResult, ImageContent

from astrbot.api import AstrBotConfig, logger
from astrbot.api.event import AstrMessageEvent, filter
from astrbot.api.star import Context, Star, register

PLUGIN_DIR = Path(__file__).resolve().parent
WINCTL = PLUGIN_DIR / "winctl.ps1"

_CREATE_NO_WINDOW = 0x08000000 if sys.platform == "win32" else 0


@register(
    "astrbot_plugin_winhands",
    "大肥鱼",
    "让 LLM 直接操作 Windows 桌面：截图看屏、移动点击、打字、快捷键、窗口管理",
    "1.0.0",
    "https://github.com/wey-gao/astrbot_plugin_winhands",
)
class WinHandsPlugin(Star):
    def __init__(self, context: Context, config: AstrBotConfig | None = None):
        super().__init__(context)
        self.config = config or {}
        self._shot_dir = Path(tempfile.gettempdir()) / "astrbot_winhands"
        self._shot_dir.mkdir(parents=True, exist_ok=True)
        self._last_shot: Path | None = None

    # ------------------------------------------------------------------ 基础

    def _cfg(self, key, default):
        try:
            val = self.config.get(key, default)
        except Exception:
            return default
        return default if val is None else val

    def _deny_reason(self, event: AstrMessageEvent) -> str | None:
        if not self._cfg("enabled", True):
            return "桌面之手插件当前已关闭（enabled=false）。"
        allow = [str(x).strip() for x in (self._cfg("allow_users", []) or []) if str(x).strip()]
        if allow:
            try:
                sid = str(event.get_sender_id())
            except Exception:
                sid = ""
            if sid not in allow:
                return f"你没有操作这台电脑的权限（{sid} 不在 allow_users 白名单里）。"
        return None

    async def _call(self, *args: str, timeout: float | None = None) -> dict:
        """调用 winctl.ps1，返回解析后的 dict。"""
        if sys.platform != "win32":
            return {"ok": False, "error": "只支持 Windows"}
        script = PLUGIN_DIR / str(self._cfg("script_name", "winctl.ps1"))
        if not script.exists():
            return {"ok": False, "error": f"缺少控制脚本: {script.name}"}
        tmo = float(timeout or self._cfg("timeout", 60))
        argv = [
            str(self._cfg("powershell", "powershell")),
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy", "Bypass",
            "-File", str(script),
            *[str(a) for a in args],
        ]
        try:
            proc = await asyncio.create_subprocess_exec(
                *argv,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                creationflags=_CREATE_NO_WINDOW,
            )
            out, err = await asyncio.wait_for(proc.communicate(), timeout=tmo)
        except asyncio.TimeoutError:
            return {"ok": False, "error": f"操作超时（{tmo:.0f}s）"}
        except FileNotFoundError:
            return {"ok": False, "error": "找不到 powershell，可在插件配置里指定 powershell 路径"}
        except Exception as exc:  # noqa: BLE001
            return {"ok": False, "error": f"调用失败: {exc}"}

        text = (out or b"").decode("utf-8", "replace").strip()
        if not text:
            msg = (err or b"").decode("utf-8", "replace").strip()
            return {"ok": False, "error": msg[:500] or "脚本没有任何输出"}
        for line in reversed(text.splitlines()):
            line = line.strip()
            if line.startswith("{"):
                try:
                    return json.loads(line)
                except json.JSONDecodeError:
                    continue
        return {"ok": False, "error": text[:500]}

    @staticmethod
    def _fmt(data: dict) -> str:
        if data.get("ok"):
            payload = {k: v for k, v in data.items() if k not in ("ok", "action")}
            return json.dumps(payload, ensure_ascii=False)
        return "失败: " + str(data.get("error", "未知错误"))

    # ------------------------------------------------------------------ LLM 工具

    @filter.llm_tool(name="pc_screen_info")
    async def pc_screen_info(self, event: AstrMessageEvent):
        """查看这台电脑的屏幕尺寸、鼠标当前位置和当前前台窗口。

        在不知道窗口在哪、或者要确认操作是否生效时，先调用它。
        """
        denied = self._deny_reason(event)
        if denied:
            return denied
        return self._fmt(await self._call("info"))

    @filter.llm_tool(name="pc_screenshot")
    async def pc_screenshot(
        self,
        event: AstrMessageEvent,
        region: str = "",
        max_width: float = 0,
    ):
        """截取当前电脑屏幕并查看画面。

        这是"看屏幕"的唯一方式：图片会直接返回给你，用于判断窗口位置、
        确认上一步操作是否成功、读屏上的文字。

        Args:
            region(string): 可选，只截一块区域，格式 "x,y,width,height"，留空表示整个屏幕
            max_width(number): 可选，图片最大宽度（像素），0 表示使用配置默认值
        """
        denied = self._deny_reason(event)
        if denied:
            return denied

        width = int(max_width or self._cfg("screenshot_max_width", 1280))
        name = f"shot_{int(time.time())}_{uuid.uuid4().hex[:6]}.png"
        path = self._shot_dir / name
        args = ["shot", "-Out", str(path), "-MaxWidth", str(width)]
        if region:
            args += ["-Region", region]
        data = await self._call(*args)
        if not data.get("ok"):
            return self._fmt(data)

        try:
            raw = path.read_bytes()
        except OSError as exc:
            return f"截图保存失败: {exc}"
        self._last_shot = path

        b64 = base64.b64encode(raw).decode()
        return CallToolResult(
            content=[
                ImageContent(type="image", data=b64, mimeType="image/png"),
            ]
        )

    @filter.llm_tool(name="pc_mouse_move")
    async def pc_mouse_move(self, event: AstrMessageEvent, x: float, y: float, steps: float = 6):
        """把鼠标移动到屏幕坐标 (x, y)。

        坐标是虚拟桌面坐标，左上角为主屏原点，副屏在左边的会是负数。
        先用 pc_screenshot 或 pc_window_rect 拿到坐标，别凭感觉猜。

        Args:
            x(number): 目标横坐标
            y(number): 目标纵坐标
            steps(number): 移动步数，1 为瞬移，越大越像人手，默认 6
        """
        denied = self._deny_reason(event)
        if denied:
            return denied
        data = await self._call("move", "-X", str(int(x)), "-Y", str(int(y)), "-Steps", str(int(max(1, steps))))
        return self._fmt(data)

    @filter.llm_tool(name="pc_click")
    async def pc_click(
        self,
        event: AstrMessageEvent,
        x: float = -1,
        y: float = -1,
        button: str = "left",
    ):
        """在指定坐标点一下鼠标。

        不填坐标就在鼠标当前位置点击。

        Args:
            x(number): 横坐标，-1 表示不移动直接点当前位置
            y(number): 纵坐标，-1 表示不移动直接点当前位置
            button(string): left / right / middle，默认 left
        """
        denied = self._deny_reason(event)
        if denied:
            return denied
        data = await self._call("click", "-X", str(int(x)), "-Y", str(int(y)), "-Button", button or "left")
        return self._fmt(data)

    @filter.llm_tool(name="pc_type_text")
    async def pc_type_text(self, event: AstrMessageEvent, text: str):
        """把一段文字打进当前获得焦点的窗口里。

        走 Unicode 输入事件，中文、全角标点、emoji 之外的字符都能输。
        打字前通常要先用 pc_focus_window 把目标窗口切到前台。

        Args:
            text(string): 要输入的文字
        """
        denied = self._deny_reason(event)
        if denied:
            return denied
        limit = int(self._cfg("text_max_length", 2000))
        if len(text) > limit:
            return f"文字太长（{len(text)} 字），上限 {limit} 字，请分段发送。"
        data = await self._call("type", "-Text", text)
        return self._fmt(data)

    @filter.llm_tool(name="pc_press_key")
    async def pc_press_key(self, event: AstrMessageEvent, combo: str):
        """按一个组合键，比如 CTRL+S、ALT+TAB、ENTER、WIN+R、F5。

        支持修饰键 CTRL / SHIFT / ALT / WIN，用 + 连接，最后一个是主键。
        主键可用：单字符、ENTER、TAB、ESC、SPACE、BACKSPACE、DELETE、INSERT、
        HOME、END、PGUP、PGDN、UP、DOWN、LEFT、RIGHT、F1~F12。

        Args:
            combo(string): 组合键字符串，例如 "CTRL+SHIFT+S"
        """
        denied = self._deny_reason(event)
        if denied:
            return denied
        data = await self._call("key", "-Text", combo)
        return self._fmt(data)

    @filter.llm_tool(name="pc_list_windows")
    async def pc_list_windows(self, event: AstrMessageEvent):
        """列出当前所有带标题的窗口，含进程名、PID 和窗口矩形。

        想知道现在开了哪些程序、某个窗口叫什么名字（给其他工具当 title 用）时调它。
        """
        denied = self._deny_reason(event)
        if denied:
            return denied
        data = await self._call("windows")
        return self._fmt(data)

    @filter.llm_tool(name="pc_window_rect")
    async def pc_window_rect(self, event: AstrMessageEvent, title: str):
        """拿到某个窗口的位置和大小，返回 x / y / width / height。

        有了矩形就能算出窗口中心的坐标，再去点击或截图窗口内的区域。
        title 支持正则，匹配第一个符合的窗口。

        Args:
            title(string): 窗口标题关键字或正则，例如 "记事本" 或 "Chrome"
        """
        denied = self._deny_reason(event)
        if denied:
            return denied
        return self._fmt(await self._call("rect", "-Title", title))

    @filter.llm_tool(name="pc_focus_window")
    async def pc_focus_window(self, event: AstrMessageEvent, title: str):
        """把某个窗口切到前台（最小化会自动还原），并返回是否真的切过去了。

        打字或按快捷键之前先调这个，否则输入会跑到别的窗口。

        Args:
            title(string): 窗口标题关键字或正则
        """
        denied = self._deny_reason(event)
        if denied:
            return denied
        return self._fmt(await self._call("focus", "-Title", title))

    @filter.llm_tool(name="pc_find_controls")
    async def pc_find_controls(self, event: AstrMessageEvent, title: str = ""):
        """列出一个窗口里所有按钮（名称 + 中心坐标）。

        比靠截图猜坐标靠谱得多：拿到按钮名字后用 pc_click_control 点它。
        对 Electron / Chromium 类界面可能列不出东西，那种情况还是截图点坐标。

        Args:
            title(string): 窗口标题关键字；留空表示当前前台窗口
        """
        denied = self._deny_reason(event)
        if denied:
            return denied
        args = ["controls"] + (["-Title", title] if title else [])
        return self._fmt(await self._call(*args))

    @filter.llm_tool(name="pc_click_control")
    async def pc_click_control(self, event: AstrMessageEvent, name: str, title: str = ""):
        """按按钮名字点击，不用自己算坐标。

        找不到会返回错误，错的时候可以再调 pc_find_controls 看看有哪些按钮。

        Args:
            name(string): 按钮显示名，支持正则，例如 "保存" 或 "确定|OK"
            title(string): 限定在哪个窗口里找；留空则先当前窗口、再全桌面兜底
        """
        denied = self._deny_reason(event)
        if denied:
            return denied
        args = ["uia-click", "-Name", name] + (["-Title", title] if title else [])
        return self._fmt(await self._call(*args))

    @filter.llm_tool(name="pc_close_window")
    async def pc_close_window(self, event: AstrMessageEvent, title: str):
        """关掉一个窗口（相当于点右上角 ×）。

        如果窗口有未保存内容，会弹出确认框，再用 pc_click_control 点"不保存"之类。

        Args:
            title(string): 窗口标题关键字或正则
        """
        denied = self._deny_reason(event)
        if denied:
            return denied
        return self._fmt(await self._call("close", "-Title", title))

    # ------------------------------------------------------------------ 指令

    @filter.command("winhands")
    async def cmd_help(self, event: AstrMessageEvent):
        """查看桌面之手状态与可用能力。"""
        data = await self._call("info")
        lines = [
            "桌面之手 · 状态",
            f"- 插件开关: {'开' if self._cfg('enabled', True) else '关'}",
            f"- 白名单: {self._cfg('allow_users', []) or '未限制'}",
        ]
        if data.get("ok"):
            lines += [
                f"- 屏幕: {data.get('screen')}",
                f"- 鼠标: {data.get('cursor')}",
                f"- 前台窗口: {data.get('foreground')}",
            ]
        else:
            lines.append("- 探测失败: " + str(data.get("error")))
        lines += [
            "",
            "对话里直接说「截个屏」「帮我点一下那个按钮」就行，模型会调工具。",
            "指令: /winhands 状态   /winhands_shot 截图",
        ]
        yield event.plain_result("\n".join(lines))

    @filter.command("winhands_shot")
    async def cmd_shot(self, event: AstrMessageEvent):
        """截一张当前屏幕发到对话里。"""
        denied = self._deny_reason(event)
        if denied:
            yield event.plain_result(denied)
            return
        width = int(self._cfg("screenshot_max_width", 1280))
        path = self._shot_dir / f"cmd_{int(time.time())}.png"
        data = await self._call("shot", "-Out", str(path), "-MaxWidth", str(width))
        if not data.get("ok"):
            yield event.plain_result(self._fmt(data))
            return
        yield event.image_result(str(path))

    async def terminate(self):
        """插件卸载/重载时清掉临时截图。"""
        try:
            for f in self._shot_dir.glob("*.png"):
                if time.time() - f.stat().st_mtime > 3600:
                    f.unlink(missing_ok=True)
        except Exception as exc:  # noqa: BLE001
            logger.debug(f"[winhands] 清理临时截图失败: {exc}")
