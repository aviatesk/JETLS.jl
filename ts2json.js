import { createSourceFile, ScriptTarget } from 'typescript';
import { readFileSync, writeFileSync } from 'fs';

// Function to safely serialize AST to JSON
function serializeAST(node) {
    const cache = new Set();
    const replacer = (key, value) => {
        if (typeof value === 'object' && value !== null) {
            if (cache.has(value)) {
                // Circular reference found, discard key
                return;
            }
            // Store value in the cache
            cache.add(value);
        }
        // Remove 'parent' property to avoid circular references
        if (key === 'parent') {
            return;
        }
        return value;
    };
    return JSON.stringify(node, replacer, 2);
}

// Function to parse a TypeScript file and convert its AST to JSON
function parseTypeScriptFile(filePath) {
    // Read the TypeScript file
    const sourceCode = readFileSync(filePath, 'utf8');

    // Create a SourceFile (AST root node)
    const sourceFile = createSourceFile(
        filePath,
        sourceCode,
        ScriptTarget.Latest, // Set the script target (ESNext, etc.)
        true // Set to true to include syntax tree parent references
    );

    // Serialize AST to JSON while handling circular references
    return serializeAST(sourceFile);
}

// Example usage
const inputPath = './LSP.ts'; // Replace with your TypeScript file
const outputPath = './LSP.json';
const astJson = parseTypeScriptFile(inputPath);

// Write the AST JSON to a file
writeFileSync(outputPath, astJson);
console.log(`AST has been written to ${outputPath}`);
