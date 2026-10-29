// Explicit CLI extension. Never installed into or written to the user's Pi config.
export default function milkCompanion(pi) {
  let mode = process.env.MILK_AGENT_MODE === "autonomous" ? "autonomous" : "approval";
  const grants = new Set();
  const readOnly = new Set(["read", "grep", "find", "ls"]);
  async function gate(tool, input, ctx) {
    if (mode === "autonomous" || readOnly.has(tool)) return true;
    const key = JSON.stringify([tool, input]);
    if (grants.has(key)) return true;
    if (!ctx.hasUI || ctx.mode !== "rpc") return false;
    const choice = await ctx.ui.select("Milk approval · " + tool + "\n" + JSON.stringify(input), ["Deny", "Allow once", "Allow for session"]);
    if (choice === "Allow for session") grants.add(key);
    return choice === "Allow once" || choice === "Allow for session";
  }
  pi.registerCommand("milk-bridge", {
    description: "Milk bridge protocol 1 readiness handshake",
    handler: async (_, ctx) => { ctx.ui.setStatus("milk.bridge", "ready:1:" + mode); }
  });
  pi.on("tool_call", async (event, ctx) => {
    if (!(await gate(event.toolName, event.input, ctx))) return { block: true, reason: "Denied by Milk approval policy" };
  });
  pi.on("user_bash", async (event, ctx) => {
    if (!(await gate("bash", { command: event.command }, ctx))) throw new Error("Denied by Milk approval policy");
  });
  pi.on("session_shutdown", () => { grants.clear(); });
}
