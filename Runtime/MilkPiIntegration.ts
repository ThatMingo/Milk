/** Milk's supported integration extension. Vanilla Pi is unmodified.
 * Only Pi's documented extension hooks and RPC UI subprotocol are used.
 */
import { readFileSync, watchFile, unwatchFile } from "node:fs";
import { Type } from "@earendil-works/pi-ai";

export default function (pi: any) {
  // Milk owns this transport, never extension-supplied JS. Native UI remains SwiftUI/AppKit.
  const catalogPath = process.env.MILK_NATIVE_CATALOG;
  let nativeCatalog: any = { tools: [], prompts: {} };
  const nativeDefinitions = new Map<string, any>();
  async function nativeRequest(ctx: any, payload: any) {
    const reply = await ctx.ui.input(JSON.stringify({ milkNativeBridge: 1, ...payload }));
    if (!reply) throw new Error("Milk native request cancelled");
    const result = JSON.parse(reply);
    if (result.error) throw new Error(result.error);
    return { content: [{ type: "text", text: result.result }], details: undefined };
  }
  function refreshNative() {
    if (!catalogPath) return;
    try {
      const next = JSON.parse(readFileSync(catalogPath, "utf8"));
      const active = new Set<string>(["milk_native_prompt_resource"]);
      for (const tool of next.tools ?? []) {
        active.add(tool.name);
        const previous = nativeDefinitions.get(tool.name);
        if (previous?.description === tool.description && JSON.stringify(previous?.parameters) === JSON.stringify(tool.parameters) && previous?.exposure === "direct") continue;
        const definition = {
          name: tool.name, label: tool.name, description: tool.description,
          parameters: Type.Unsafe(tool.parameters), exposure: "direct",
          execute: async (_id: any, args: any, _signal: any, _update: any, ctx: any) =>
            nativeRequest(ctx, { contribution: tool.id, arguments: args })
        };
        pi.registerTool(definition); nativeDefinitions.set(tool.name, definition);
      }
      // Pi documents hidden exposure as its withdrawal mechanism; old handlers cannot run.
      for (const [name, definition] of nativeDefinitions) {
        if (!active.has(name) && definition.exposure !== "hidden") {
          const hidden = { ...definition, exposure: "hidden" };
          pi.registerTool(hidden); nativeDefinitions.set(name, hidden);
        }
      }
      nativeCatalog = next;
      const resourceName = "milk_native_prompt_resource";
      const resource = {
        name: resourceName, label: "Milk extension prompt resource",
        description: "Read an active native Milk Extension prompt resource. IDs: " + Object.keys(next.prompts ?? {}).join(", "),
        parameters: Type.Object({ id: Type.String() }),
        exposure: Object.keys(next.prompts ?? {}).length ? "direct" : "hidden",
        execute: async (_id: any, args: any, _signal: any, _update: any, ctx: any) => nativeRequest(ctx, { prompt: args.id })
      };
      if (JSON.stringify(nativeDefinitions.get(resourceName)?.description) !== JSON.stringify(resource.description) || nativeDefinitions.get(resourceName)?.exposure !== resource.exposure) { pi.registerTool(resource); nativeDefinitions.set(resourceName, resource); }
    } catch (error) {
      // Fail closed on an unreadable catalog: no stale native tools remain callable.
      for (const [name, definition] of nativeDefinitions) {
        const hidden = { ...definition, exposure: "hidden" };
        pi.registerTool(hidden); nativeDefinitions.set(name, hidden);
      }
      nativeCatalog = { tools: [], prompts: {} };
    }
  }
  if (catalogPath) { refreshNative(); watchFile(catalogPath, { interval: 200, persistent: false }, refreshNative); }
  pi.on("session_shutdown", async () => { if (catalogPath) unwatchFile(catalogPath, refreshNative); });

  let permission = process.env.MILK_PERMISSION_MODE === "autonomous" ? "autonomous" : "approval";
  const allowances = new Set<string>();
  const config = process.env.MILK_OMLX_CONFIG;
  if (config) {
    const value = JSON.parse(config);
    pi.registerProvider("omlx", {
      name: "oMLX", api: "openai-completions", baseUrl: value.baseUrl,
      apiKey: "$MILK_OMLX_TOKEN",
      models: value.models.map((m: any) => ({
        id: m.id, name: m.id, reasoning: m.reasoning, input: m.image ? ["text", "image"] : ["text"],
        contextWindow: value.contextWindow, maxTokens: value.maxTokens,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }
      }))
    });
  }
  pi.on("session_start", async (_event: any, ctx: any) => {
    allowances.clear();
    ctx.ui.setStatus("milk-integration-ready", "1");
    ctx.ui.setStatus("milk-session-dir", ctx.sessionManager.getSessionDir());
  });
  pi.registerCommand("milk-permission", {
    description: "Set Milk tool approval policy for this runtime",
    handler: async (args: string, ctx: any) => {
      const mode = args.trim();
      if (mode !== "approval" && mode !== "autonomous") throw new Error("Invalid Milk permission mode");
      permission = mode;
      ctx.ui.setStatus("milk-permission", mode);
    }
  });
  pi.on("tool_call", async (event: any, ctx: any) => {
    if (catalogPath) refreshNative();
    if (nativeDefinitions.has(event.toolName) && event.toolName !== "milk_native_prompt_resource" && !nativeCatalog.tools.some((tool: any) => tool.name === event.toolName)) {
      return { block: true, reason: "Native Milk Extension contribution is inactive" };
    }
    // Preview discovery is read-only even in Autonomous mode. Startup is owned by Swift.
    if (process.env.MILK_PREVIEW_DISCOVERY === "1" && !["read", "grep", "find", "ls"].includes(event.toolName)) {
      return { block: true, reason: "Preview discovery may only inspect project files. It cannot execute commands or modify files." };
    }
    if (permission === "autonomous") return;
    // Known read-only built-ins do not need an approval. Unknown tools do.
    if (["read", "grep", "find", "ls"].includes(event.toolName)) return;
    const key = JSON.stringify([event.toolName, event.input]);
    if (allowances.has(key)) return;
    if (!ctx.hasUI) return { block: true, reason: "Milk approval UI is unavailable" };
    const detail = {
      milkApproval: 1, activityID: event.toolCallId, tool: event.toolName, cwd: ctx.cwd,
      action: event.input.command ?? event.input.path ?? JSON.stringify(event.input),
      reason: "Pi requested this tool while Ask for approval is selected.",
      effect: event.toolName === "bash" ? "Execute this command with your user permissions." : "Allow this tool to act on the displayed arguments.",
      input: event.input
    };
    const choices = ["Deny", "Allow Once", "Allow for Session"];
    if (event.toolName === "bash") choices.splice(1, 0, "Edit Command");
    const choice = await ctx.ui.select(JSON.stringify(detail), choices);
    if (choice === "Allow for Session") { allowances.add(key); return; }
    if (choice === "Allow Once") return;
    if (choice === "Edit Command" && event.toolName === "bash") {
      const edited = await ctx.ui.editor("Edit command to allow once", event.input.command);
      if (edited?.trim()) {
        event.input.command = edited;
        ctx.ui.setStatus("milk-command-edit", JSON.stringify({ activityID: event.toolCallId, command: edited }));
        return;
      }
    }
    return { block: true, reason: "Denied or cancelled in Milk" };
  });
}
