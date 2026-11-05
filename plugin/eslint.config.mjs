// The community directory's scanner, run locally (`make lint`): eslint-plugin-obsidianmd's recommended config with the
// scanner's adjustments for a plugin submitted now (its docs/configuration.md, "Community plugin scanner configuration").
// Like the scanner on this repo: no jsconfig.json, so no type information — the type-aware rules (no-unsupported-api
// among them) are off there too. Every rule warns, but those the scanner fails a submission on
import { defineConfig, globalIgnores } from 'eslint/config';
import obsidianmd from 'eslint-plugin-obsidianmd';

// Errors in the scanner (as set by the recommended config, options kept); the type-aware ones among them can't run here
const ERRORS = new Set([
  // Security: errors for every plugin (no-new-func runs inside obsidianmd/rule-custom-message)
  'no-eval', 'no-implied-eval', 'no-unsanitized/method', 'no-unsanitized/property', 'obsidianmd/regex-lookbehind',
  'obsidianmd/no-forbidden-elements', 'obsidianmd/rule-custom-message',
  // Disable comments, for a plugin submitted now
  'eslint-comments/no-unlimited-disable', 'eslint-comments/require-description', 'eslint-comments/disable-enable-pair',
  'eslint-comments/no-restricted-disable',
  // The newest layer's
  'obsidianmd/settings-tab/no-manual-html-headings', 'obsidianmd/settings-tab/no-problematic-settings-headings',
  'obsidianmd/sample-names', 'obsidianmd/no-sample-code', 'obsidianmd/platform', 'obsidianmd/no-plugin-as-component',
  'obsidianmd/detach-leaves', 'obsidianmd/no-static-styles-assignment', 'obsidianmd/no-view-references-in-plugin',
  'obsidianmd/no-unsupported-api',
]);

// The scanner skips these: handled elsewhere, or too noisy
const OFF = ['no-undef', '@typescript-eslint/restrict-template-expressions', '@typescript-eslint/no-base-to-string',
  'import/no-unresolved'];

const severity = (value) => (Array.isArray(value) ? value[0] : value);
const warn = (value) => (Array.isArray(value) ? ['warn', ...value.slice(1)] : 'warn');

// Every rule set to error but ERRORS → warn, options kept
const warnings = (config) => !config.rules ? config : {
  ...config,
  rules: Object.fromEntries(Object.entries(config.rules).map(([name, value]) => [name,
    [2, 'error'].includes(severity(value)) && !ERRORS.has(name) ? warn(value) : value])),
};

export default defineConfig([
  // Build output, build scripts, tests: the scanner skips them too
  globalIgnores(['node_modules', 'dist', '**/*.mjs', 'test']),
  ...obsidianmd.configs.recommended.map(warnings),
  {
    files: ['**/*.js'],
    rules: {
      ...Object.fromEntries(OFF.map((name) => [name, 'off'])),
      // Core rules, not in the recommended config at error
      'no-eval': 'error',
      'no-implied-eval': 'error',
    },
  },
  // The scanner honours disable comments but doesn't report unused ones
  { linterOptions: { reportUnusedDisableDirectives: 'off', reportUnusedInlineConfigs: 'off' } },
]);
