import { pathToFileURL } from 'node:url';

const [modulePath, ...routes] = process.argv.slice(2);
if (!modulePath || routes.length === 0) {
  process.stdout.write('CODEX_RSSHUB_RESULT:{"error":{"message":"本机 RSSHub 参数不完整"}}\n');
  process.exit(2);
}

let input = '';
for await (const chunk of process.stdin) input += chunk;

try {
  const payload = input.trim().replace(/^\uFEFF/, '');
  let authToken;
  if (payload.startsWith('TOKEN_BASE64:')) {
    authToken = Buffer.from(payload.slice('TOKEN_BASE64:'.length), 'base64').toString('utf8');
  } else {
    // Keep accepting the old JSON format for build tools and existing runtimes.
    authToken = JSON.parse(payload).authToken;
  }
  if (!authToken) throw new Error('X 登录凭据为空');
  process.env.LOGGER_LEVEL = 'error';
  process.env.NO_LOGFILES = 'true';
  process.env.CACHE_TYPE = 'memory';
  process.env.REQUEST_TIMEOUT = '15000';
  const rsshub = await import(pathToFileURL(modulePath).href);
  await rsshub.init({
    TWITTER_AUTH_TOKEN: authToken,
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
