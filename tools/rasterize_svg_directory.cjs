"use strict";

const fs = require("fs");
const path = require("path");

let sharp;
try {
  sharp = require("sharp");
} catch (error) {
  throw new Error(
    'The SVG fallback rasterizer requires the "sharp" Node.js package. ' +
      "Install it or run the script with the bundled Codex Node runtime.",
    { cause: error },
  );
}

async function main() {
  const inputDir = process.argv[2];
  const outputDir = process.argv[3] || inputDir;
  const density = Number(process.argv[4] || 300);
  if (!inputDir) {
    throw new Error("usage: node rasterize_svg_directory.cjs INPUT_DIR [OUTPUT_DIR] [DENSITY]");
  }
  if (!Number.isFinite(density) || density <= 0) {
    throw new Error("DENSITY must be a positive number");
  }
  fs.mkdirSync(outputDir, { recursive: true });
  const files = fs.readdirSync(inputDir).filter((name) => name.toLowerCase().endsWith(".svg"));
  for (const name of files) {
    const input = path.join(inputDir, name);
    const output = path.join(outputDir, name.replace(/\.svg$/i, ".png"));
    await sharp(input, { density }).png().toFile(output);
  }
  process.stdout.write(`rasterized ${files.length} SVG files\n`);
}

main().catch((error) => {
  process.stderr.write(`${error.stack || error}\n`);
  process.exit(1);
});
