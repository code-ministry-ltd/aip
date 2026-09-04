import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { createJiti } from "jiti";

const here = path.dirname(fileURLToPath(import.meta.url));
const extensionPath = path.join(here, "../../extensions/aip-status.ts");
const handlers = new Map();
const jiti = createJiti(import.meta.url);

const extension = await jiti.import(extensionPath, { default: true });
assert.equal(typeof extension, "function", "extension exports a factory");

extension({
  on(event, handler) {
    handlers.set(event, handler);
  },
});

assert.deepEqual([...handlers.keys()], ["session_start"]);

const statuses = [];
process.env.AIP_ACTIVE_PROFILE = "work";
await handlers.get("session_start")({}, {
  ui: {
    setStatus(key, text) {
      statuses.push([key, text]);
    },
  },
});

assert.deepEqual(statuses, [["aip-profile", "aip: work"]]);
console.log("extension smoke: 1 passed");
