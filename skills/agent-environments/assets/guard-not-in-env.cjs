#!/usr/bin/env node
// Refuse the main dev command inside an agent environment. The main dev command
// is pinned to the main checkout's ports, so running it from an env worktree
// collides with the main checkout's dev server. `provision` writes
// .agent-env.json into every env, so its presence in cwd is the signal.
// Cross-platform (Node) because dev must run on macOS and Windows.
//
// Wire it as the first step of the dev script, e.g. in package.json:
//   "dev": "node scripts/guard-not-in-env.cjs && <your real dev command>"
//
// ADAPT: the command names in the message below to match this project.
const fs = require("fs");

if (fs.existsSync(".agent-env.json")) {
  process.stderr.write(
    "\n\x1b[31m✖ `npm run dev` is disabled inside an agent environment.\x1b[0m\n" +
      "  It is pinned to the main checkout's ports and would collide with its dev server.\n\n" +
      "  Use instead:\n" +
      "    ./scripts/agent-env.sh serve <name>   # live server on this env's own ports\n" +
      "    npm test  /  npm run build            # most tasks need only these\n\n"
  );
  process.exit(1);
}
