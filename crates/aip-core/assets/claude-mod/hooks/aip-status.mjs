// Names the persona aip launched Claude Code with, in a line above the
// prompt, like aip's Pi extension does in Pi's footer.

const PERSONA = "example"; // aip writes the persona's name here

export function register(on) {
  on("ui.render", { component: "AbovePrompt" }, async ($, e, next) => {
    if (e.props.hasSurvey) {
      return next(e);
    }
    const { Box, Text } = $.ui.resolve(e);
    return Box({ paddingX: 1, children: [Text({ dimColor: true, children: `aip: ${PERSONA}` })] });
  });
}
