import fs from 'node:fs';
import { URL } from 'node:url';
import Ajv from 'ajv';

const packageJson = JSON.parse(
    fs.readFileSync(new URL('package.json', import.meta.url), 'utf8'));
const contributedConfiguration = packageJson.contributes?.configuration;
const configurationEntries = Array.isArray(contributedConfiguration)
    ? contributedConfiguration
    : [contributedConfiguration];
const ajv = new Ajv({ allErrors: true, strict: false });
const errors = [];

for (const configuration of configurationEntries) {
    for (const [name, schema] of Object.entries(configuration?.properties ?? {})) {
        if (schema === null || typeof schema !== 'object' || Array.isArray(schema)) {
            errors.push(`${name}: schema must be an object`);
            continue;
        }
        if (!ajv.validateSchema(schema)) {
            errors.push(`${name}:\n${ajv.errorsText(ajv.errors, { separator: '\n' })}`);
        }
    }
}

if (errors.length > 0) {
    throw new Error(`Invalid VS Code configuration schemas:\n${errors.join('\n')}`);
}
