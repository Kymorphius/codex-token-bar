import {
  cpSync,
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  realpathSync,
  unlinkSync,
} from 'node:fs';
import { dirname, join, relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const [sourceRoot, outputRoot, tracePath] = process.argv.slice(2);
if (!sourceRoot || !outputRoot || !tracePath) {
  throw new Error('usage: node prune_rsshub_runtime.mjs <source> <output> <trace>');
}

const modulePaths = readFileSync(tracePath, 'utf8')
  .split(/\r?\n/)
  .filter((line) => line.startsWith('CODEX_RSSHUB_MODULE:file:'))
  .map((line) => fileURLToPath(line.slice('CODEX_RSSHUB_MODULE:'.length)));

const sourceModules = realpathSync(join(sourceRoot, 'node_modules'));
const packageNames = new Set();
const rsshubFiles = new Set();

for (const modulePath of modulePaths) {
  const local = relative(sourceModules, modulePath);
  if (local.startsWith(`..${sep}`) || local === '..') continue;
  const parts = local.split(sep);
  const packageName = parts[0].startsWith('@') ? `${parts[0]}/${parts[1]}` : parts[0];
  packageNames.add(packageName);
  if (packageName === 'rsshub') rsshubFiles.add(modulePath);
}

if (!packageNames.has('rsshub') || rsshubFiles.size < 10) {
  throw new Error(`RSSHub trace is incomplete: ${packageNames.size} packages, ${rsshubFiles.size} RSSHub files; source=${sourceModules}; traced=${modulePaths.slice(0, 5).join(',')}`);
}

const dependencyQueue = [...packageNames].filter((name) => name !== 'rsshub');
for (let index = 0; index < dependencyQueue.length; index += 1) {
  const packageName = dependencyQueue[index];
  const manifestPath = join(sourceModules, packageName, 'package.json');
  if (!existsSync(manifestPath)) continue;
  const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
  const dependencies = {
    ...(manifest.dependencies ?? {}),
    ...(manifest.optionalDependencies ?? {}),
  };
  for (const dependency of Object.keys(dependencies)) {
    if (packageNames.has(dependency) || !existsSync(join(sourceModules, dependency))) continue;
    packageNames.add(dependency);
    dependencyQueue.push(dependency);
  }
}

mkdirSync(join(outputRoot, 'node_modules'), { recursive: true });
for (const packageName of [...packageNames].sort()) {
  if (packageName === 'rsshub') continue;
  const source = join(sourceModules, packageName);
  if (!existsSync(source)) throw new Error(`traced package is missing: ${packageName}`);
  cpSync(source, join(outputRoot, 'node_modules', packageName), {
    recursive: true,
    verbatimSymlinks: true,
  });
}

const sourceRsshub = join(sourceModules, 'rsshub');
const outputRsshub = join(outputRoot, 'node_modules', 'rsshub');
for (const name of ['package.json', 'LICENSE']) {
  const source = join(sourceRsshub, name);
  if (existsSync(source)) cpSync(source, join(outputRsshub, name), { recursive: true });
}
for (const source of rsshubFiles) {
  const destination = join(outputRsshub, relative(sourceRsshub, source));
  mkdirSync(dirname(destination), { recursive: true });
  cpSync(source, destination);
}

function removeDanglingSymlinks(directory) {
  for (const name of readdirSync(directory)) {
    const path = join(directory, name);
    const metadata = lstatSync(path);
    if (metadata.isSymbolicLink()) {
      try {
        const resolved = realpathSync(path);
        const local = relative(outputRoot, resolved);
        if (local === '..' || local.startsWith(`..${sep}`)) unlinkSync(path);
      } catch {
        unlinkSync(path);
      }
    } else if (metadata.isDirectory()) {
      removeDanglingSymlinks(path);
    }
  }
}

removeDanglingSymlinks(outputRoot);

process.stdout.write(JSON.stringify({
  packages: packageNames.size,
  rsshubFiles: rsshubFiles.size,
}) + '\n');
