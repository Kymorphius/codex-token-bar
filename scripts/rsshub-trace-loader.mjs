import process from 'node:process';
import { appendFileSync } from 'node:fs';

const tracePath = process.env.CODEX_RSSHUB_TRACE_FILE;

export async function resolve(specifier, context, nextResolve) {
  const resolved = await nextResolve(specifier, context);
  if (resolved.url.startsWith('file:')) {
    const line = `CODEX_RSSHUB_MODULE:${resolved.url}\n`;
    if (tracePath) appendFileSync(tracePath, line);
    else process.stderr.write(line);
  }
  return resolved;
}
