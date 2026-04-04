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
  { name: "safari-browser-channel", version: "1.0.0" },
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

// --- Reply Tool: safari_action ---
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
  ],
}));

mcp.setRequestHandler(CallToolRequestSchema, async (req) => {
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

// --- Monitor Loop (opt-in via SB_CHANNEL_MONITOR=1) ---
let lastDescription = "";
let monitorActive = true;
let monitor: ReturnType<typeof setInterval> | null = null;

if (MONITOR_ENABLED) {
  monitor = setInterval(async () => {
    if (!monitorActive) return;
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
      if (desc && desc !== lastDescription) {
        lastDescription = desc;
        await mcp.notification({
          method: "notifications/claude/channel",
          params: {
            content: desc,
            meta: {
              event: "page_change",
              timestamp: Date.now().toString(),
            },
          },
        });
      }
    } catch {
      // Swallow any unexpected errors to keep the loop alive
    } finally {
      monitorActive = true;
    }
  }, INTERVAL_MS);
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
