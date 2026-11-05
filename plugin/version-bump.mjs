// `npm version` lifecycle: package.json is already bumped; carry the version into manifest.json
// and record its minAppVersion in versions.json (both at the repo root: Obsidian reads them there)
import { readFileSync, writeFileSync } from 'node:fs';

const version = process.env.npm_package_version;
const read = (file) => JSON.parse(readFileSync(file, 'utf8'));
const write = (file, data) => writeFileSync(file, JSON.stringify(data, null, 2) + '\n');

const manifest = read('../manifest.json');
manifest.version = version;
write('../manifest.json', manifest);

const versions = read('../versions.json');
versions[version] = manifest.minAppVersion;
write('../versions.json', versions);
