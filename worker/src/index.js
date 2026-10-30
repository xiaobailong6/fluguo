const repository = 'Xanerix/guoapp';

const json = (body, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method === 'GET' && url.pathname === '/v1/latest') {
      const latest = await env.DB.prepare(
        "SELECT value FROM meta WHERE key = 'latest'",
      ).first('value');
      return json(latest ? JSON.parse(latest) : {});
    }
    return new Response('Not Found', { status: 404 });
  },

  async scheduled(_, env) {
    const response = await fetch(
      `https://api.github.com/repos/${repository}/releases/latest`,
      {
        headers: {
          Accept: 'application/vnd.github+json',
          'User-Agent': 'guoapp-update',
        },
      },
    );
    if (!response.ok) return;
    const release = await response.json();
    const match = /^app-v(\d+\.\d+\.\d+)-(\d+)$/.exec(release.tag_name ?? '');
    if (!match) return;
    const latest = { version: `${match[1]}+${match[2]}`, url: release.html_url };
    await env.DB.prepare(
      "INSERT INTO meta (key, value) VALUES ('latest', ?1) ON CONFLICT (key) DO UPDATE SET value = excluded.value",
    )
      .bind(JSON.stringify(latest))
      .run();
  },
};
