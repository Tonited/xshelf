// 用 Google 登录拿到的 cookie 验证 X 会话是否真的可用。
// 走本地代理 CONNECT，手工发 HTTP/1.1（免依赖）。
const fs = require('fs');
const http = require('http');
const tls = require('tls');
const path = require('path');

const OUT = path.join(__dirname, '..', 'build', 'auth_probe');
const PROXY = { host: '127.0.0.1', port: Number(process.env.PROXY_PORT || 7897) };
const BEARER =
  'AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA';
const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36';

const cookies = JSON.parse(fs.readFileSync(path.join(OUT, 'cookies.json'), 'utf8'));

function tunnel(host, port = 443) {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: PROXY.host, port: PROXY.port, method: 'CONNECT', path: `${host}:${port}` });
    req.on('connect', (res, socket) => {
      if (res.statusCode !== 200) return reject(new Error('CONNECT ' + res.statusCode));
      const t = tls.connect({ socket, servername: host }, () => resolve(t));
      t.on('error', reject);
    });
    req.on('error', reject);
    req.end();
  });
}

async function request(host, pathAndQuery, headers, body) {
  const socket = await tunnel(host);
  const payload = body ? JSON.stringify(body) : '';
  const lines = [
    `GET ${pathAndQuery} HTTP/1.1`,
    `Host: ${host}`,
    ...Object.entries(headers).map(([k, v]) => `${k}: ${v}`),
    'connection: close',
    'accept-encoding: identity',
  ];
  if (body) lines.push(`content-length: ${Buffer.byteLength(payload)}`);
  socket.write(lines.join('\r\n') + '\r\n\r\n' + payload);

  let raw = '';
  return await new Promise((resolve, reject) => {
    socket.on('data', (d) => (raw += d.toString('utf8')));
    socket.on('end', () => {
      const idx = raw.indexOf('\r\n\r\n');
      const head = raw.slice(0, idx).split('\r\n');
      const status = Number(head[0].split(' ')[1]);
      resolve({ status, headers: head.slice(1), body: raw.slice(idx + 4) });
    });
    socket.on('error', reject);
    setTimeout(() => reject(new Error('timeout')), 25000);
  });
}

const baseHeaders = {
  authorization: 'Bearer ' + BEARER,
  'x-csrf-token': cookies.ct0,
  'x-twitter-auth-type': 'OAuth2Session',
  'x-twitter-active-user': 'yes',
  'x-twitter-client-language': 'en',
  accept: '*/*',
  'accept-language': 'en-US,en;q=0.9',
  referer: 'https://x.com/',
  'user-agent': UA,
  cookie: `auth_token=${cookies.auth_token}; ct0=${cookies.ct0}`,
};

(async () => {
  console.log('=== verify_credentials ===');
  const v = await request(
    'x.com',
    '/i/api/1.1/account/verify_credentials.json?skip_status=true&include_entities=false',
    baseHeaders,
  );
  console.log('status:', v.status);
  let me = null;
  try { me = JSON.parse(v.body); } catch (_) {}
  if (me && me.screen_name) {
    console.log('screen_name:', me.screen_name, '| name:', me.name, '| id:', me.id_str);
    console.log('followers:', me.followers_count, '| likes_received:', me.favourites_count);
  } else {
    console.log('body:', v.body.slice(0, 400));
  }
  fs.writeFileSync(path.join(OUT, 'verify.json'), v.body);

  if (!me || !me.screen_name) return;

  // 找 Likes 的 queryId：抓 x.com 首页里的 client-web JS
  console.log('\n=== discover Likes queryId ===');
  const home = await request('x.com', '/', { 'user-agent': UA, 'accept-language': 'en-US,en;q=0.9' });
  const scripts = [...new Set((home.body.match(/https:\/\/abs\.twimg\.com\/responsive-web\/client-web[^"'\s]+\.js/g) || []))];
  console.log('scripts found:', scripts.length);

  let qid = null;
  for (const url of scripts.slice(0, 14)) {
    const u = new URL(url);
    try {
      const js = await request(u.host, u.pathname + u.search, { 'user-agent': UA });
      if (js.status !== 200) continue;
      const m =
        js.body.match(/queryId:"([A-Za-z0-9_-]{10,})"[^}]{0,400}?operationName:"Likes"/) ||
        js.body.match(/operationName:"Likes"[^}]{0,400}?queryId:"([A-Za-z0-9_-]{10,})"/);
      if (m) { qid = m[1]; console.log('Likes queryId:', qid, 'from', u.pathname.slice(0, 40)); break; }
    } catch (e) { /* ignore */ }
  }
  if (!qid) { console.log('queryId NOT FOUND (app 自己会重试发现)'); return; }

  console.log('\n=== Likes 第一页 ===');
  const variables = {
    userId: me.id_str, count: 20, includePromotedContent: false,
    withClientEventToken: false, withBirdwatchNotes: false, withVoice: false, withV2Timeline: true,
  };
  const features = {
    rweb_video_screen_enabled: false, payments_enabled: false,
    profile_label_improvements_pcf_label_in_post_enabled: true,
    rweb_tipjar_consumption_enabled: true, verified_phone_label_enabled: false,
    creator_subscriptions_tweet_preview_api_enabled: true,
    responsive_web_graphql_timeline_navigation_enabled: true,
    responsive_web_graphql_skip_user_profile_image_extensions_enabled: false,
    premium_content_api_read_enabled: false,
    communities_web_enable_tweet_community_results_fetch: true,
    c9s_tweet_anatomy_moderator_badge_enabled: true, articles_preview_enabled: true,
    responsive_web_edit_tweet_api_enabled: true,
    graphql_is_translatable_rweb_tweet_is_translatable_enabled: true,
    view_counts_everywhere_api_enabled: true, longform_notetweets_consumption_enabled: true,
    responsive_web_twitter_article_tweet_consumption_enabled: true,
    tweet_awards_web_tipping_enabled: false, creator_subscriptions_quote_tweet_preview_enabled: false,
    freedom_of_speech_not_reach_fetch_enabled: true, standardized_nudges_misinfo: true,
    tweet_with_visibility_results_prefer_gql_limited_actions_policy_enabled: true,
    longform_notetweets_rich_text_read_enabled: true, longform_notetweets_inline_media_enabled: true,
    responsive_web_enhance_cards_enabled: false,
  };
  const qs = new URLSearchParams({
    variables: JSON.stringify(variables),
    features: JSON.stringify(features),
    fieldToggles: JSON.stringify({ withArticlePlainText: false }),
  });
  const likes = await request('x.com', `/i/api/graphql/${qid}/Likes?${qs}`, baseHeaders);
  console.log('status:', likes.status);
  fs.writeFileSync(path.join(OUT, 'likes.json'), likes.body);
  let lj = null;
  try { lj = JSON.parse(likes.body); } catch (_) {}
  if (lj) {
    const entries = lj?.data?.user?.result?.timeline_v2?.timeline?.instructions || [];
    const add = entries.find((i) => i.type === 'TimelineAddEntries');
    const tweets = (add?.entries || []).filter((e) => e.entryId?.startsWith('tweet-'));
    console.log('timeline entries:', (add?.entries || []).length, '| tweets:', tweets.length);
    for (const t of tweets.slice(0, 3)) {
      const r = t.content?.itemContent?.tweet_results?.result;
      const legacy = r?.legacy || r?.tweet?.legacy;
      console.log(' -', t.entryId, '|', (legacy?.full_text || '').replace(/\n/g, ' ').slice(0, 70));
    }
    if (lj.errors) console.log('errors:', JSON.stringify(lj.errors).slice(0, 300));
  } else {
    console.log('body:', likes.body.slice(0, 400));
  }
})().catch((e) => { console.error('FATAL', e.message); process.exit(1); });
