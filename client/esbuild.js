const esbuild = require('esbuild');
const watch = process.argv.includes('--watch');
const minify = process.argv.includes('--minify');
const opts = {
  entryPoints: ['src/extension.ts'],
  bundle: true,
  outfile: 'out/extension.js',
  external: ['vscode'],
  format: 'cjs',
  platform: 'node',
  sourcemap: true,
  minify,
};
if (watch) {
  esbuild.context(opts).then(ctx => ctx.watch()).catch(() => process.exit(1));
} else {
  esbuild.build(opts).catch(() => process.exit(1));
}
