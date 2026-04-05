#!/usr/bin/env bun
/**
 * safari-browser Channel Server
 *
 * Pushes real-time page change events to Claude Code via Channels.
 * Uses safari-vision (local VLM) to analyze screenshots and only
 * pushes text summaries when changes are detected.
 *
 * Start with:
 *   claude --dangerously-load-development-channels server:safari-browser-channel
 */

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  ListToolsRequestSchema,
  CallToolRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { execFileSync } from "child_process";
import { unlinkSync, existsSync } from "fs";

// --- Configuration ---
// Monitor loop is OFF by default (#10). Set SB_CHANNEL_MONITOR=1 to enable.
// Reply tool (safari_action) works regardless of monitor state.
const MONITOR_ENABLED = process.env.SB_CHANNEL_MONITOR === "1";
const INTERVAL_MS = parseInt(
  process.env.SB_CHANNEL_INTERVAL ?? "1500",
  10
);
const SAFARI_BROWSER = process.env.SB_BINARY ?? "safari-browser";
const SAFARI_VISION = process.env.SB_VISION_BINARY ?? "safari-vision";
const SCREENSHOT_PATH = "/tmp/sb-channel-frame.png";
const VLM_PROMPT =
  process.env.SB_VLM_PROMPT ??
  "Describe the current state of this webpage in one sentence. Focus on what changed.";

// --- Valid safari-browser subcommands (for reply tool validation) ---
const VALID_COMMANDS = new Set([
  "open", "back", "forward", "reload", "close",
  "snapshot", "js",
  "get", "click", "dblclick", "fill", "type", "select",
  "hover", "focus", "check", "uncheck", "scroll", "scrollintoview",
  "press", "drag", "highlight", "find",
  "screenshot", "pdf", "upload",
  "is", "cookies", "storage", "mouse", "console", "errors",
  "tabs", "tab", "wait", "set",
]);

// --- MCP Server ---
const mcp = new Server(
  { name: "safari-browser-channel", version: "2.1.0" },
  {
    capabilities: {
      experimental: { "claude/channel": {} },
      tools: {},
    },
    instructions: [
      'Page change events arrive as <channel source="safari-browser-channel" event="page_change" timestamp="...">.',
      "Each event contains a one-sentence VLM description of the current page state.",
      "Events only fire when the page visually changes — no spam.",
      "",
      "To interact with Safari, use the safari_action tool:",
      '  safari_action({ command: "click", args: ["button.submit"] })',
      '  safari_action({ command: "fill", args: ["input#email", "user@example.com"] })',
      '  safari_action({ command: "get", args: ["url"] })',
      "",
      "The observe → decide → act loop:",
      "1. You receive a page_change event describing what you see",
      "2. You decide what action to take",
      "3. You call safari_action to execute it",
      "4. Wait for the next page_change event to see the result",
    ].join("\n"),
  }
);

// --- Monitor runtime state ---
// monitor: interval handle (null when loop not started)
// monitorActive: anti-overlap guard (false while a cycle is mid-flight)
// monitorPaused (#12): user-requested silence via safari_monitor_pause tool
//   — distinct from monitorActive; survives across cycles
// lastEventAt (#12): timestamp (ms) of last pushed page_change, null if none
let monitor: ReturnType<typeof setInterval> | null = null;
let monitorActive = true;
let monitorPaused = false;
let lastDescription = "";
let lastEventAt: number | null = null;

// --- Reply Tools ---
mcp.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: "safari_action",
      description:
        "Execute a safari-browser CLI command. Returns stdout as result.",
      inputSchema: {
        type: "object" as const,
        properties: {
          command: {
            type: "string",
            description:
              "safari-browser subcommand (click, fill, get, open, js, snapshot, etc.)",
          },
          args: {
            type: "array",
            items: { type: "string" },
            description: "Arguments for the command",
          },
        },
        required: ["command"],
      },
    },
    {
      name: "safari_monitor_pause",
      description:
        "Pause the vision monitor loop — stop emitting page_change events until resumed. Use during multi-step safari_action sequences to avoid stale/transitional observations.",
      inputSchema: { type: "object" as const, properties: {} },
    },
    {
      name: "safari_monitor_resume",
      description:
        "Resume the vision monitor loop — start emitting page_change events again. No-op if monitor was not paused.",
      inputSchema: { type: "object" as const, properties: {} },
    },
    {
      name: "safari_monitor_status",
      description:
        "Report current monitor state: { enabled, paused, running, interval_ms, last_event_at }.",
      inputSchema: { type: "object" as const, properties: {} },
    },
  ],
}));

mcp.setRequestHandler(CallToolRequestSchema, async (req) => {
  // --- Monitor control tools (#12) ---
  if (req.params.name === "safari_monitor_pause") {
    if (!MONITOR_ENABLED) {
      return {
        content: [
          {
            type: "text" as const,
            text: JSON.stringify({
              enabled: false,
              message:
                "Monitor not enabled; set SB_CHANNEL_MONITOR=1 to use pause/resume",
            }),
          },
        ],
      };
    }
    monitorPaused = true;
    return {
      content: [
        { type: "text" as const, text: JSON.stringify({ paused: true }) },
      ],
    };
  }
  if (req.params.name === "safari_monitor_resume") {
    if (!MONITOR_ENABLED) {
      return {
        content: [
          {
            type: "text" as const,
            text: JSON.stringify({
              enabled: false,
              message:
                "Monitor not enabled; set SB_CHANNEL_MONITOR=1 to use pause/resume",
            }),
          },
        ],
      };
    }
    monitorPaused = false;
    // #12: trigger immediate cycle so Claude gets fresh observation right away
    // (deferred to avoid blocking tool response with execFileSync)
    setTimeout(monitorCycle, 0);
    return {
      content: [
        { type: "text" as const, text: JSON.stringify({ paused: false }) },
      ],
    };
  }
  if (req.params.name === "safari_monitor_status") {
    return {
      content: [
        {
          type: "text" as const,
          text: JSON.stringify({
            enabled: MONITOR_ENABLED,
            paused: monitorPaused,
            running: MONITOR_ENABLED && !monitorPaused && monitor !== null,
            interval_ms: INTERVAL_MS,
            last_event_at: lastEventAt,
          }),
        },
      ],
    };
  }

  if (req.params.name === "safari_action") {
    const { command, args = [] } = req.params.arguments as {
      command: string;
      args?: string[];
    };

    // Command validation
    if (!VALID_COMMANDS.has(command)) {
      return {
        content: [
          {
            type: "text" as const,
            text: `Error: '${command}' is not a valid safari-browser subcommand. Valid: ${[...VALID_COMMANDS].join(", ")}`,
          },
        ],
        isError: true,
      };
    }

    try {
      const result = execFileSync(SAFARI_BROWSER, [command, ...args], {
        timeout: 30000,
        encoding: "utf-8",
      });
      return {
        content: [{ type: "text" as const, text: result.trim() || "(no output)" }],
      };
    } catch (e: any) {
      return {
        content: [
          {
            type: "text" as const,
            text: `Error: ${e.stderr?.trim() || e.message}`,
          },
        ],
        isError: true,
      };
    }
  }
  throw new Error(`Unknown tool: ${req.params.name}`);
});

// --- Connect to Claude Code ---
await mcp.connect(new StdioServerTransport());

// --- Monitor cycle (extracted for reuse by resume) ---
async function monitorCycle() {
  if (!monitorActive) return;
  if (monitorPaused) return;
  monitorActive = false; // prevent overlapping

  try {
    // Take screenshot
    try {
      execFileSync(SAFARI_BROWSER, ["screenshot", SCREENSHOT_PATH], {
        timeout: 10000,
        encoding: "utf-8",
      });
    } catch {
      monitorActive = true;
      return; // Safari not available, skip this cycle
    }

    // Analyze with VLM
    let desc: string;
    try {
      desc = execFileSync(
        SAFARI_VISION,
        ["analyze", SCREENSHOT_PATH, VLM_PROMPT],
        {
          timeout: 30000,
          encoding: "utf-8",
        }
      ).trim();
    } catch {
      monitorActive = true;
      return; // VLM failed, skip
    }

    // Cleanup screenshot
    try {
      if (existsSync(SCREENSHOT_PATH)) unlinkSync(SCREENSHOT_PATH);
    } catch {}

    // Change detection: only push if different
    if (desc && desc !== lastDescription && !monitorPaused) {
      lastDescription = desc;
      const ts = Date.now();
      lastEventAt = ts;
      await mcp.notification({
        method: "notifications/claude/channel",
        params: {
          content: desc,
          meta: {
            event: "page_change",
            timestamp: ts.toString(),
          },
        },
      });
    }
  } catch {
    // Swallow any unexpected errors to keep the loop alive
  } finally {
    monitorActive = true;
  }
}

// --- Monitor Loop (opt-in via SB_CHANNEL_MONITOR=1) ---
if (MONITOR_ENABLED) {
  monitor = setInterval(monitorCycle, INTERVAL_MS);
}

// --- Cleanup handlers (#10) ---
// Clean up monitor interval and temp screenshot on any exit path.
function cleanup() {
  if (monitor) {
    clearInterval(monitor);
    monitor = null;
  }
  try {
    if (existsSync(SCREENSHOT_PATH)) unlinkSync(SCREENSHOT_PATH);
  } catch {}
}

process.on("SIGINT", () => {
  cleanup();
  process.exit(0);
});
process.on("SIGTERM", () => {
  cleanup();
  process.exit(0);
});
process.on("SIGHUP", () => {
  cleanup();
  process.exit(0);
});
process.on("exit", cleanup);
// Parent (Claude Code) disconnects stdio → server should exit cleanly
process.stdin.on("end", () => {
  cleanup();
  process.exit(0);
});
