#!/usr/bin/env node
// npx entry point: copies the package to ~/.hidpi-scale and runs install.sh
// there, so the LaunchAgent points at a stable path (the npx cache is not).
const { execSync } = require("child_process");
const fs = require("fs");
const path = require("path");
const os = require("os");

const src = __dirname;
const dest = path.join(os.homedir(), ".hidpi-scale");

if (process.platform !== "darwin") {
  console.error("hidpi-scale only works on macOS.");
  process.exit(1);
}

console.log(`Installing to ${dest} ...`);
fs.mkdirSync(dest, { recursive: true });
fs.cpSync(src, dest, {
  recursive: true,
  filter: (p) => !p.includes("node_modules") && !p.includes(path.sep + ".git"),
});

execSync(`zsh "${path.join(dest, "install.sh")}"`, { stdio: "inherit" });
