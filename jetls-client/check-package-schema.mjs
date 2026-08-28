import fs from "node:fs";
import { URL } from "node:url";
import Ajv from "ajv";

const packageJsonText = fs.readFileSync(
  new URL("package.json", import.meta.url),
  "utf8",
);
const packageJson = JSON.parse(packageJsonText);
const contributedConfiguration = packageJson.contributes?.configuration;
const configurationEntries = Array.isArray(contributedConfiguration)
  ? contributedConfiguration
  : [contributedConfiguration];
const ajv = new Ajv({ allErrors: true, strict: false });
const errors = [];
const canonicalPackageJson = `${JSON.stringify(packageJson, null, 2)}\n`;

// Windows checkouts may translate line endings (`core.autocrlf`), which git
// undoes on commit, so the round-trip comparison ignores them.
if (packageJsonText.replaceAll("\r\n", "\n") !== canonicalPackageJson) {
  errors.push(
    "package.json is not stable under Node.js JSON round-tripping; " +
      "npm/vsce would rewrite it",
  );
}

for (const configuration of configurationEntries) {
  for (const [name, schema] of Object.entries(
    configuration?.properties ?? {},
  )) {
    if (
      schema === null ||
      typeof schema !== "object" ||
      Array.isArray(schema)
    ) {
      errors.push(`${name}: schema must be an object`);
      continue;
    }
    if (!ajv.validateSchema(schema)) {
      errors.push(
        `${name}:\n${ajv.errorsText(ajv.errors, { separator: "\n" })}`,
      );
    }
  }
}

if (errors.length > 0) {
  throw new Error(`Extension package validation failed:\n${errors.join("\n")}`);
}
