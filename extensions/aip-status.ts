import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function aipStatus(pi: ExtensionAPI): void {
  pi.on("session_start", async (_event, ctx) => {
    const profile = process.env.AIP_ACTIVE_PROFILE;
    ctx.ui.setStatus("aip-profile", profile ? `aip: ${profile}` : undefined);
  });
}
