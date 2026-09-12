'use strict';

// Supplies browser globals and forwards CLI arguments to a dart2js benchmark.
const path = require('node:path');
const benchmarkPath = process.argv[2];
if (!benchmarkPath) {
  process.stderr.write('Usage: node tool/benchmark_node.cjs compiled.js [benchmark options]\n');
  process.exit(64);
}
globalThis.self = globalThis;
globalThis.dartMainRunner = (main) => main(process.argv.slice(3));
require(path.resolve(benchmarkPath));
