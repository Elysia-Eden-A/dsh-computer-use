import { spawn } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { tmpdir } from "node:os";
import { appendFileSync, mkdirSync } from "node:fs";

export const name = "dsh-computer-use";
export const inject = ["tools"];

const HERE = dirname(fileURLToPath(import.meta.url));
const SCRIPT = join(HERE, "ui.ps1");
const INDICATOR = join(HERE, "indicator.ps1");
const POWERSHELL = join(process.env.SystemRoot ?? "C:\\Windows", "System32", "WindowsPowerShell", "v1.0", "powershell.exe");

let defineTool;
try {
  ({ defineTool } = await import("@deepseek-ai/dsh-tools"));
} catch {
  defineTool = undefined;
}

const HUD_LABELS = {
  screenshot: "读取屏幕",
  windows: "查看窗口",
  focus: "切换窗口",
  click: "点击",
  move: "移动鼠标",
  drag: "拖拽",
  scroll: "滚动",
  type: "输入文字",
  key: "按键",
  wait: "等待",
  cursor: "读取光标",
  screen: "读取屏幕",
};

let hud = null;

function hudLog(message) {
  try {
    appendFileSync(join(tmpdir(), "dsh-hud-node.log"), `${new Date().toISOString()} ${message}\n`);
  } catch {
    /* ignore */
  }
}

function hudProcess() {
  if (hud !== null && hud.exitCode === null && !hud.killed) return hud;
  const child = spawn(POWERSHELL, [
    "-NoProfile",
    "-NonInteractive",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    INDICATOR,
  ], { windowsHide: true, stdio: ["pipe", "ignore", "ignore"] });
  hudLog(`spawn pid=${child.pid}`);
  child.on("error", (error) => { hudLog(`error ${error.message}`); if (hud === child) hud = null; });
  child.on("exit", (code) => { if (code !== 0) hudLog(`exit ${code}`); if (hud === child) hud = null; });
  child.stdin.on("error", (error) => hudLog(`stdin error ${error.message}`));
  hud = child;
  return child;
}

function hudShow(text) {
  try {
    const child = hudProcess();
    if (child.stdin.writable) child.stdin.write(Buffer.from(`show|${text}\n`, "utf8"));
  } catch {
    /* the indicator is cosmetic; never fail a tool call because of it */
  }
}

function hudHide() {
  try {
    if (hud !== null && hud.stdin.writable) hud.stdin.write(Buffer.from("hide\n", "utf8"));
  } catch {
    /* ignore */
  }
}

function hudStop() {
  try { hud?.kill(); } catch { /* ignore */ }
  hud = null;
}

function runHelper(payload, signal) {
  const encoded = Buffer.from(JSON.stringify(payload), "utf8").toString("base64");
  return new Promise((resolve, reject) => {
    const child = spawn(POWERSHELL, [
      "-NoProfile",
      "-NonInteractive",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      SCRIPT,
      "-Payload",
      encoded,
    ], { windowsHide: true, stdio: ["ignore", "pipe", "pipe"] });

    let out = "";
    let err = "";
    const timer = setTimeout(() => {
      child.kill();
      reject(new Error("ui helper timed out after 75s"));
    }, 75_000);

    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => { out += chunk; });
    child.stderr.on("data", (chunk) => { err += chunk; });
    child.on("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      const text = out.trim();
      if (!text) {
        reject(new Error(`ui helper produced no output (exit ${code}): ${err.trim().slice(0, 800)}`));
        return;
      }
      try {
        resolve(JSON.parse(text));
      } catch {
        reject(new Error(`ui helper returned non-JSON: ${text.slice(0, 800)}`));
      }
    });

    if (signal !== undefined) {
      if (signal.aborted) {
        child.kill();
        reject(new Error("aborted"));
        return;
      }
      signal.addEventListener("abort", () => child.kill(), { once: true });
    }
  });
}

function shotPath(requested) {
  if (typeof requested === "string" && requested.trim() !== "") return requested.trim();
  const dir = join(tmpdir(), "dsh-computer");
  mkdirSync(dir, { recursive: true });
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  return join(dir, `screen-${stamp}.png`);
}

const ACTIONS = ["screenshot", "windows", "focus", "click", "move", "drag", "scroll", "type", "key", "wait", "cursor", "screen"];

const DESCRIPTION = [
  "Drive the user's Windows desktop: capture the screen, move/click the mouse, drag, scroll, type text, press key chords, and list or focus application windows.",
  "",
  "Standard loop:",
  "1. action=windows to find the target window (returns hwnd, title, process, x/y/width/height).",
  "2. action=focus with that hwnd (or a title substring) to raise it.",
  "3. action=screenshot (optionally window=<hwnd> to crop just that window). The result gives a PNG path plus width/height.",
  "4. Read that PNG with the read_image tool, then act with action=click/move/drag/scroll/type/key using coordinates you measured in that image.",
  "5. Take a fresh screenshot after every action that changes the UI; never chain blind clicks.",
  "",
  "Coordinates are physical screen pixels, origin at the top-left of the virtual screen. If the image you inspected was resized, scale your estimate by (returned width / inspected width). Screenshots of a window use window-relative coordinates only for reading; clicks still take absolute screen coordinates.",
  "",
  "action=type pastes through the clipboard (so Chinese and emoji work), then restores the previous clipboard. It needs the target field already focused — click it first. action=key takes a '+' chord such as ctrl+s, alt+tab, enter, esc, f5, shift+click-style modifiers are not supported.",
  "",
  "Notes: the desktop is live and shared with the user. Prefer small, reversible steps and confirm before anything destructive. Some apps (games, exclusive fullscreen, elevated/UAC windows) ignore synthetic input; say so instead of retrying forever.",
].join("\n");

const computerTool = {
  name: "computer",
  description: DESCRIPTION,
  parameters: {
    type: "object",
    additionalProperties: false,
    required: ["action"],
    properties: {
      action: {
        type: "string",
        enum: ACTIONS,
        description: "The desktop operation to perform.",
      },
    x: { type: "number", description: "Absolute screen X for click/move/scroll (physical pixels)." },
    y: { type: "number", description: "Absolute screen Y for click/move/scroll (physical pixels)." },
    to_x: { type: "number", description: "Drag end X." },
    to_y: { type: "number", description: "Drag end Y." },
    from_x: { type: "number", description: "Drag start X." },
    from_y: { type: "number", description: "Drag start Y." },
    button: { type: "string", enum: ["left", "right", "middle"], description: "Mouse button; defaults to left." },
    count: { type: "number", description: "Click count, e.g. 2 for double-click. Defaults to 1." },
    clicks: { type: "number", description: "Scroll notches; positive scrolls up, negative down. Defaults to 1." },
    duration: { type: "number", description: "Drag duration in milliseconds. Defaults to 500." },
    ms: { type: "number", description: "action=wait duration in milliseconds. Defaults to 500." },
    text: { type: "string", description: "action=type: the text to paste." },
    keys: { type: "string", description: "action=key: a '+' chord such as ctrl+s, alt+tab, ctrl+shift+esc." },
    window: { type: "string", description: "Window hwnd (number) or a case-insensitive title substring, for focus and screenshot." },
      path: { type: "string", description: "action=screenshot: absolute PNG output path. Defaults to a temp file." },
    },
  },
  output: {
    schema: {
      type: "object",
      additionalProperties: false,
      properties: {
        ok: { type: "boolean" },
        action: { type: "string" },
        detail: { type: "string" },
        path: { type: "string" },
        width: { type: "number" },
        height: { type: "number" },
      },
    },
    render: (_args, value) => [{ type: "text", text: value.detail }],
    presentationMeta: (args) => ({ action: args?.action }),
  },
  timeoutMs: 90_000,
  isConcurrencySafe: () => false,
  async execute(args, exec) {
    const action = String(args?.action ?? "");
    if (!ACTIONS.includes(action)) throw new Error(`unknown action: ${action}`);

    const payload = { action };
    for (const key of ["x", "y", "to_x", "to_y", "from_x", "from_y", "count", "clicks", "duration", "ms"]) {
      if (typeof args?.[key] === "number") payload[key] = args[key];
    }
    for (const key of ["button", "text", "keys", "window"]) {
      if (typeof args?.[key] === "string" && args[key] !== "") payload[key] = args[key];
    }
    if (action === "screenshot") payload.path = shotPath(args?.path);

    hudShow(`DeepSeek 正在操作电脑 · ${HUD_LABELS[action] ?? action}`);
    let raw;
    try {
      raw = await runHelper(payload, exec?.signal);
    } finally {
      hudHide();
    }

    if (raw?.ok === false) {
      return {
        ok: false,
        action,
        detail: `computer ${action} failed: ${raw.error ?? "unknown error"}`,
      };
    }

    const base = { ok: true, action };
    switch (action) {
      case "screenshot":
        return {
          ...base,
          path: raw.path,
          width: raw.width,
          height: raw.height,
          detail: `screenshot ${raw.width}x${raw.height} saved to ${raw.path}\nRead it with read_image on that exact path.`,
        };
      case "windows": {
        const rows = Array.isArray(raw.windows) ? raw.windows : [];
        const lines = rows.map((w) => `- [${w.hwnd}] "${w.title}" (${w.process || "?"}) ${w.width}x${w.height} at ${w.x},${w.y}${w.minimized ? " [minimized]" : ""}`);
        return { ...base, detail: `${rows.length} visible windows:\n${lines.join("\n")}` };
      }
      case "cursor":
        return { ...base, detail: `cursor at ${raw.x},${raw.y}` };
      case "screen":
        return { ...base, detail: `virtual screen ${raw.width}x${raw.height} at origin ${raw.left},${raw.top}` };
      case "click":
        return { ...base, detail: `clicked ${raw.button ?? "left"} x${raw.count ?? 1} at ${raw.x},${raw.y}` };
      case "move":
        return { ...base, detail: `cursor moved to ${raw.x},${raw.y}` };
      case "drag":
        return { ...base, detail: `dragged ${raw.from_x},${raw.from_y} -> ${raw.to_x},${raw.to_y}` };
      case "scroll":
        return { ...base, detail: `scrolled ${raw.clicks} notches` };
      case "type":
        return { ...base, detail: `typed ${raw.length} characters into the focused field` };
      case "key":
        return { ...base, detail: `pressed ${raw.keys}` };
      case "focus":
        return { ...base, detail: `focused hwnd ${raw.hwnd} (foreground now ${raw.foreground})` };
      case "wait":
        return { ...base, detail: `waited ${raw.ms}ms` };
      default:
        return { ...base, detail: JSON.stringify(raw) };
    }
  },
  presentCall: (args) => ({
    card: "generic",
    title: `computer · ${args?.action ?? "?"}`,
    kind: "execute",
    rawInput: args,
  }),
};

export function apply(ctx) {
  const register = (definition) => {
    const tool = defineTool === undefined ? definition : defineTool(definition);
    return ctx.tools.register(tool);
  };
  ctx.effect(() => {
    const dispose = register(computerTool);
    try {
      hudProcess();
    } catch {
      /* pre-warm only: the indicator starts hidden */
    }
    return () => {
      dispose();
      hudStop();
    };
  });
}
