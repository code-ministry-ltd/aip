import { describe, expect, test } from "claude-code/testing";

describe("aip-status", () => {
  test("names the persona above the prompt", async ($) => {
    const ui = await $.ui.mount({
      plugin: "aip-example",
      surface: "terminal",
      component: "AbovePrompt",
      props: { hasSurvey: false, isWorking: false, maxRows: 10, bodyColumns: 120 },
    } as any);
    expect(await ui.find({ type: "Text", text: "aip: example" })).toBeDefined();
    await ui.unmount();
  });

  test("leaves the line to a survey", async ($, on) => {
    // Stands in for what Claude Code draws there itself.
    on("ui.render", ($, e) => {
      const { Text } = $.ui.resolve(e);
      return Text({ children: "survey" });
    });
    const ui = await $.ui.mount({
      plugin: "aip-example",
      surface: "terminal",
      component: "AbovePrompt",
      props: { hasSurvey: true, isWorking: false, maxRows: 10, bodyColumns: 120 },
    } as any);
    expect(await ui.find({ type: "Text", text: "survey" })).toBeDefined();
    expect(await ui.find({ type: "Text", text: /aip:/ })).toBeUndefined();
    await ui.unmount();
  });
});
