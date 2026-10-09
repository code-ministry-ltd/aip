// Names the persona aip launched Pi with in Pi's footer, like the Claude Code
// mod in assets/claude-mod does above Claude's prompt.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const PERSONA = "example"; // aip writes the persona's name here

export default function aipStatus(pi: ExtensionAPI): void {
  pi.on("session_start", async (_event, ctx) => {
    ctx.ui.setStatus("aip-persona", `aip: ${PERSONA}`);
  });
}
