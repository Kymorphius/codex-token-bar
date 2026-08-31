import { pathToFileURL } from 'node:url';

const [modulePath, ...routes] = process.argv.slice(2);
if (!modulePath || routes.length === 0) {
  process.stdout.write('CODEX_RSSHUB_RESULT:{"error":{"message":"本机 RSSHub 参数不完整"}}\n');
  process.exit(2);
}

let input = '';
for await (const chunk of process.stdin) input += chunk;

try {
  const credentials = JSON.parse(input);
  const rsshub = await import(pathToFileURL(modulePath).href);
  await rsshub.init({
    TWITTER_AUTH_TOKEN: credentials.authToken,
    LOGGER_LEVEL: 'error',
    NO_LOGFILES: 'true',
    CACHE_TYPE: 'memory',
    REQUEST_TIMEOUT: '15000',
  });
  const feeds = [];
  for (const route of routes) {
    try {
      feeds.push({ route, data: await rsshub.request(route) });
    } catch (error) {
      feeds.push({
        route,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }
  process.stdout.write(`CODEX_RSSHUB_RESULT:${JSON.stringify({ feeds })}\n`);
} catch (error) {
  const message = error instanceof Error ? error.message : String(error);
  process.stdout.write(`CODEX_RSSHUB_RESULT:${JSON.stringify({ error: { message } })}\n`);
  process.exitCode = 1;
}
