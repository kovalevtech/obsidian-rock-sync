import esbuild from 'esbuild';
import { copyFileSync, existsSync, mkdirSync, watch, writeFileSync } from 'node:fs';
import { basename, dirname } from 'node:path';

const production = process.argv[2] === 'production';

// The plugin's folder: dist/ to ship, in dev the test vault's (.env)
let out = 'dist';
if (!production) {
  for (const file of ['.env.local', '.env']) if (existsSync(file)) process.loadEnvFile(file); // the first one wins
  const vault = process.env.DEV_VAULT;
  if (!existsSync(`${vault}/.obsidian`)) {
    console.error(`DEV_VAULT '${vault}' is not a vault`);
    process.exit(1);
  }
  out = `${vault}/.obsidian/plugins/rock-sync`;
}

// Nothing imports these two, so esbuild doesn't see them change
const COPIED = ['../manifest.json', 'styles.css'];
const copy = (file) => copyFileSync(file, `${out}/${basename(file)}`);

const context = await esbuild.context({
  entryPoints: ['src/main.js'],
  outfile: `${out}/main.js`,
  bundle: true,
  format: 'cjs',
  target: 'es2020',
  // Provided by Obsidian at runtime; bundling a second copy of CM breaks its instanceof/facet checks
  external: [
    'obsidian',
    'electron',
    '@codemirror/autocomplete',
    '@codemirror/collab',
    '@codemirror/commands',
    '@codemirror/language',
    '@codemirror/lint',
    '@codemirror/search',
    '@codemirror/state',
    '@codemirror/view',
    '@lezer/common',
    '@lezer/highlight',
    '@lezer/lr',
  ],
  sourcemap: production ? false : 'inline',
  minify: production,
  logLevel: 'info',
});

mkdirSync(out, { recursive: true });
COPIED.forEach(copy);

if (production) {
  await context.rebuild();
  await context.dispose();
} else {
  writeFileSync(`${out}/.hotreload`, ''); // the Hot Reload plugin's marker
  // The folder, not the files: an editor saving by rename would end a watch on the file
  for (const file of COPIED) {
    watch(dirname(file), (_, name) => {
      if (name === basename(file) && existsSync(file)) copy(file);
    });
  }
  await context.watch(); // Hot Reload picks up every rewrite of main.js
}
