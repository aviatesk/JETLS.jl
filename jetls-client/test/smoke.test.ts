import * as assert from "node:assert/strict";
import { test } from "node:test";

test("bundles and runs TypeScript tests", () => {
  const result = { value: 42 } satisfies { value: number };
  assert.equal(result.value, 42);
});
