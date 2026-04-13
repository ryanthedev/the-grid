#!/usr/bin/env bun
const { McpServer } = require("@modelcontextprotocol/sdk/server/mcp.js");
const { StdioServerTransport } = require("@modelcontextprotocol/sdk/server/stdio.js");
const { z } = require("zod");
const { RPCClient } = require("./rpc-client.js");

const server = new McpServer({ name: "grid", version: "1.0.0" });
const rpcClient = new RPCClient();

// ============================================================================
// Schema Helpers
// ============================================================================

function stringProp(description, enums = null) {
  if (enums) {
    return z.enum(enums).describe(description);
  }
  return z.string().describe(description);
}

function numberProp(description) {
  return z.number().describe(description);
}

function boolProp(description) {
  return z.boolean().optional().describe(description);
}

function intProp(description) {
  return z.number().int().describe(description);
}

// ============================================================================
// Handler Factories
// ============================================================================

function makeRpcHandler(toolName) {
  return async (args) => {
    try {
      const result = await rpcClient.call(toolName, args);
      const jsonString = JSON.stringify(result);
      return {
        content: [{ type: "text", text: jsonString }],
      };
    } catch (error) {
      return {
        isError: true,
        content: [{ type: "text", text: `Error: ${error.message}` }],
      };
    }
  };
}

function makeResizeHandler(toolName) {
  return async (args) => {
    let amount = 0.1;
    if (args && args.amount !== undefined) {
      amount = typeof args.amount === "number" ? args.amount : parseFloat(args.amount);
    }

    const delta = toolName === "grid.resize.shrink" ? -amount : amount;

    try {
      const result = await rpcClient.call("grid.resize.adjust", { delta });
      const jsonString = JSON.stringify(result);
      return {
        content: [{ type: "text", text: jsonString }],
      };
    } catch (error) {
      return {
        isError: true,
        content: [{ type: "text", text: `Error: ${error.message}` }],
      };
    }
  };
}

// ============================================================================
// Grid Tools (25)
// ============================================================================

server.tool(
  "grid.focus",
  "Move focus to an adjacent window in the grid.",
  {
    direction: z.enum(["left", "right", "up", "down"]).describe("Direction to move focus"),
    wrap: boolProp("Wrap around grid edges"),
    extend: boolProp("Extend selection to additional cell"),
  },
  makeRpcHandler("grid.focus")
);

server.tool(
  "grid.focus.cycle",
  "Cycle focus to the next or previous window in the grid.",
  {
    forward: boolProp("true for next, false for previous (default: true)"),
  },
  makeRpcHandler("grid.focus.cycle")
);

server.tool(
  "grid.focus.cell",
  "Focus a specific grid cell by ID.",
  {
    cell: z.string().describe("Cell ID to focus"),
    space: z.string().optional().describe("Space ID (default: active space)"),
  },
  makeRpcHandler("grid.focus.cell")
);

server.tool(
  "grid.layout.apply",
  "Apply a named layout to the active space, arranging all windows into the grid.",
  {
    layout: z.string().describe("Layout ID to apply (e.g. 'tall-wide', 'even-3col')"),
    strategy: z
      .enum(["position", "preserve", "autoflow", "pinned"])
      .optional()
      .describe("Window assignment strategy"),
  },
  makeRpcHandler("grid.layout.apply")
);

server.tool(
  "grid.layout.cycle",
  "Cycle to the next layout in the configured layout list.",
  {},
  makeRpcHandler("grid.layout.cycle")
);

server.tool(
  "grid.layout.list",
  "List all available layout IDs. Use grid.layout.get to see a layout's full definition.",
  {},
  makeRpcHandler("grid.layout.list")
);

server.tool(
  "grid.layout.current",
  "Get the current layout ID and space ID for the active display.",
  {},
  makeRpcHandler("grid.layout.current")
);

server.tool(
  "grid.layout.get",
  "Get the full definition of a layout: grid dimensions, cell positions, padding, and stack modes.",
  {
    layout: z.string().describe("Layout ID"),
  },
  makeRpcHandler("grid.layout.get")
);

server.tool(
  "grid.layout.refresh",
  "Reapply current layouts to all displays, snapping windows back to their grid cells.",
  {
    display: z.string().optional().describe("Display UUID to refresh (default: all displays)"),
  },
  makeRpcHandler("grid.layout.refresh")
);

server.tool(
  "grid.cell.send",
  "Send the focused window to the adjacent cell in the given direction.",
  {
    direction: z.enum(["left", "right", "up", "down"]).describe("Direction to send"),
  },
  makeRpcHandler("grid.cell.send")
);

server.tool(
  "grid.cell.mode",
  "Set or cycle the stack mode of the focused cell. Modes: vertical (split top/bottom), horizontal (split left/right), tabs (tabbed).",
  {
    mode: z
      .enum(["vertical", "horizontal", "tabs"])
      .optional()
      .describe("Target mode, or omit to cycle"),
  },
  makeRpcHandler("grid.cell.mode")
);

server.tool(
  "grid.window.move",
  "Move the focused window to the adjacent cell. With extend, the window spans both cells.",
  {
    direction: z.enum(["left", "right", "up", "down"]).describe("Direction to move"),
    wrap: boolProp("Wrap around grid edges"),
    extend: boolProp("Extend window to span both source and target cells"),
  },
  makeRpcHandler("grid.window.move")
);

server.tool(
  "grid.window.swap",
  "Swap the focused window with the window in the adjacent cell.",
  {
    direction: z.enum(["left", "right", "up", "down"]).describe("Direction of cell to swap with"),
  },
  makeRpcHandler("grid.window.swap")
);

server.tool(
  "grid.resize.grow",
  "Grow the focused window's split ratio.",
  {
    amount: z.number().optional().describe("Amount to grow as fraction (default: 0.1, range 0.0-1.0)"),
  },
  makeResizeHandler("grid.resize.grow")
);

server.tool(
  "grid.resize.shrink",
  "Shrink the focused window's split ratio.",
  {
    amount: z.number().optional().describe("Amount to shrink as fraction (default: 0.1, range 0.0-1.0)"),
  },
  makeResizeHandler("grid.resize.shrink")
);

server.tool(
  "grid.resize.cell",
  "Adjust a cell boundary in the given direction.",
  {
    direction: z.enum(["left", "right", "up", "down"]).describe("Direction of boundary to adjust"),
    amount: z.number().optional().describe("Amount to adjust as fraction (default: 0.05)"),
  },
  makeRpcHandler("grid.resize.cell")
);

server.tool(
  "grid.resize.reset",
  "Reset split ratios to equal sizes.",
  {
    all: boolProp("Reset all cells, not just the focused one"),
    cell: boolProp("Reset cell ratios instead of window splits"),
  },
  makeRpcHandler("grid.resize.reset")
);

server.tool(
  "grid.screenshot",
  "Capture a screenshot and return it as an inline image Claude can view. Targets: 'full' (entire screen), 'window' (specific window by ID), 'cell' (grid cell by ID — captures the focused window in that cell).",
  {
    target: z
      .enum(["full", "window", "cell"])
      .optional()
      .describe("What to capture: 'full', 'window', or 'cell' (default: full)"),
    id: z.string().optional().describe("Window ID for target=window, or cell ID for target=cell"),
    cursor: boolProp("Include cursor (full screen only)"),
    display: z.number().int().optional().describe("Display index, 0-based (full screen only, default: main display)"),
    quality: z
      .enum(["low", "high"])
      .optional()
      .describe("Quality preset: 'low' (default, <=1024px JPEG), 'high' (full-res PNG)"),
  },
  async () => {
    return {
      content: [{ type: "text", text: "Screenshot not yet implemented — coming in Phase 3" }],
    };
  }
);

server.tool(
  "grid.record.start",
  "Start a screen recording of a cell, window, display, or all screens.",
  {
    target: z
      .enum(["cell", "window", "screen", "all"])
      .optional()
      .describe("What to record"),
    id: z.string().optional().describe("Target ID (cell ID, window ID, or screen index)"),
    output: z.string().optional().describe("Output file path"),
    format: z.enum(["gif", "mp4", "mov"]).optional().describe("Output format"),
    fps: z.number().int().optional().describe("Frames per second"),
    quality: z.enum(["low", "medium", "high"]).optional().describe("Quality preset"),
    duration: z.number().int().optional().describe("Auto-stop after N seconds"),
    cursor: boolProp("Include cursor in recording"),
    width: z.number().int().optional().describe("Output width in pixels"),
  },
  makeRpcHandler("grid.record.start")
);

server.tool(
  "grid.record.stop",
  "Stop the active recording and return the output file path.",
  {},
  makeRpcHandler("grid.record.stop")
);

server.tool(
  "grid.record.toggle",
  "Toggle recording: start if idle, stop if recording. Returns recording result on stop.",
  {
    target: z
      .enum(["cell", "window", "screen", "all"])
      .optional()
      .describe("What to record"),
    format: z.enum(["gif", "mp4", "mov"]).optional().describe("Output format"),
  },
  makeRpcHandler("grid.record.toggle")
);

server.tool(
  "grid.config.show",
  "Export the grid configuration summary: layouts, spacing, settings.",
  {},
  makeRpcHandler("grid.config.show")
);

server.tool(
  "grid.state.show",
  "Export the full grid state: cell assignments, current layouts, focus tracking per space.",
  {},
  makeRpcHandler("grid.state.show")
);

server.tool(
  "grid.state.reset",
  "Clear all grid state for the active space (cell assignments, layout, focus tracking).",
  {},
  makeRpcHandler("grid.state.reset")
);

server.tool(
  "grid.terminal",
  "Toggle the grid terminal overlay.",
  {},
  makeRpcHandler("grid.terminal")
);

// ============================================================================
// Window Tools (14)
// ============================================================================

server.tool(
  "window.find",
  "Find a window by app name, title substring, or process ID. Returns the first visible match with its window ID.",
  {
    appName: z.string().optional().describe("Exact application name (e.g. 'Safari', 'Terminal')"),
    title: z.string().optional().describe("Window title substring to match"),
    pid: z.number().int().optional().describe("Process ID (walks ancestor chain to find owning window)"),
  },
  makeRpcHandler("window.find")
);

server.tool(
  "window.focus",
  "Focus a specific window by ID: raise it to front and activate its application.",
  {
    windowId: z.string().describe("Window ID to focus"),
  },
  makeRpcHandler("window.focus")
);

server.tool(
  "window.close",
  "Close a window by pressing its close button via accessibility.",
  {
    windowId: z.string().describe("Window ID to close"),
  },
  makeRpcHandler("window.close")
);

server.tool(
  "window.minimize",
  "Minimize a window to the dock.",
  {
    windowId: z.string().describe("Window ID to minimize"),
  },
  makeRpcHandler("window.minimize")
);

server.tool(
  "window.unminimize",
  "Restore a minimized window from the dock.",
  {
    windowId: z.string().describe("Window ID to restore"),
  },
  makeRpcHandler("window.unminimize")
);

server.tool(
  "window.raise",
  "Raise a window to front without changing keyboard focus.",
  {
    windowId: z.string().describe("Window ID to raise"),
  },
  makeRpcHandler("window.raise")
);

server.tool(
  "window.show",
  "Show a hidden window: unhide its application and bring the window to front.",
  {
    windowId: z.string().describe("Window ID to show"),
  },
  makeRpcHandler("window.show")
);

server.tool(
  "window.hide",
  "Hide a window (order it out or hide its application).",
  {
    windowId: z.string().describe("Window ID to hide"),
  },
  makeRpcHandler("window.hide")
);

server.tool(
  "window.setOpacity",
  "Set window transparency. 0.0 = fully transparent, 1.0 = fully opaque.",
  {
    windowId: z.string().describe("Window ID"),
    opacity: z.number().describe("Opacity value from 0.0 to 1.0"),
  },
  makeRpcHandler("window.setOpacity")
);

server.tool(
  "window.getOpacity",
  "Get the current opacity of a window.",
  {
    windowId: z.string().describe("Window ID"),
  },
  makeRpcHandler("window.getOpacity")
);

server.tool(
  "window.setLayer",
  "Set window stacking layer: 'above' stays on top, 'below' stays behind, 'normal' is default.",
  {
    windowId: z.string().describe("Window ID"),
    layer: z.enum(["below", "normal", "above"]).describe("Window layer"),
  },
  makeRpcHandler("window.setLayer")
);

server.tool(
  "window.getLayer",
  "Get the current stacking layer of a window.",
  {
    windowId: z.string().describe("Window ID"),
  },
  makeRpcHandler("window.getLayer")
);

server.tool(
  "window.setSticky",
  "Make a window appear on all macOS spaces (sticky) or only its current space.",
  {
    windowId: z.string().describe("Window ID"),
    sticky: z.boolean().describe("true = show on all spaces, false = current space only"),
  },
  makeRpcHandler("window.setSticky")
);

server.tool(
  "window.isSticky",
  "Check if a window appears on all macOS spaces.",
  {
    windowId: z.string().describe("Window ID"),
  },
  makeRpcHandler("window.isSticky")
);

// ============================================================================
// Query Tools (9)
// ============================================================================

server.tool(
  "ping",
  "Test connectivity to the grid server. Returns server version and timestamp.",
  {},
  makeRpcHandler("ping")
);

server.tool(
  "getServerInfo",
  "Get grid server name, version, commit hash, and capabilities.",
  {},
  makeRpcHandler("getServerInfo")
);

server.tool(
  "metadata.get",
  "Get cached window manager metadata: focused window ID, active display UUID, active space ID, last update time.",
  {},
  makeRpcHandler("metadata.get")
);

server.tool(
  "display.list",
  "List all connected displays with their UUID, name, frame, visible frame, scale factor, and current space.",
  {},
  makeRpcHandler("display.list")
);

server.tool(
  "display.get",
  "Get a single display by UUID, or the currently active display.",
  {
    uuid: z.string().optional().describe("Display UUID"),
    active: z.boolean().optional().describe("Set true to get the currently active display"),
  },
  makeRpcHandler("display.get")
);

server.tool(
  "dump",
  "Get the complete window manager state: all windows (with frame, app, title, spaces), all displays, all apps. Large response.",
  {},
  makeRpcHandler("dump")
);

server.tool(
  "space.focus",
  "Switch to a specific macOS space by its numeric ID.",
  {
    spaceId: z.string().describe("Space ID to switch to"),
  },
  makeRpcHandler("space.focus")
);

server.tool(
  "mouse.warp",
  "Warp the mouse cursor to the center of a window.",
  {
    windowId: z.string().describe("Window ID to warp cursor to"),
  },
  makeRpcHandler("mouse.warp")
);

server.tool(
  "pick.show",
  "Show the app/action picker overlay and return the user's selection.",
  {},
  makeRpcHandler("pick.show")
);

// ============================================================================
// Server Setup
// ============================================================================

async function main() {
  try {
    const transport = new StdioServerTransport();
    await server.connect(transport);
  } catch (error) {
    console.error("MCP server failed:", error);
    process.exit(1);
  }
}

main();
