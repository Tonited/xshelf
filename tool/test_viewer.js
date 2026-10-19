// 测试现行 Viewer / Likes 端点（按字节正确解码 chunked）。
const fs = require('fs');
const path = require('path');
const { request } = require('./xhttp');

const OUT = path.join(__dirname, '..', 'build', 'auth_probe');
const BEARER =
  'AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA';
const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36';

const cookies = JSON.parse(fs.readFileSync(path.join(OUT, 'cookies.json'), 'utf8'));
const IDS = JSON.parse(fs.readFileSync(path.join(OUT, 'queryids.json'), 'utf8'));

const H = {
  authorization: 'Bearer ' + BEARER,
  'x-csrf-token': cookies.ct0,
  'x-twitter-auth-type': 'OAuth2Session',
  'x-twitter-active-user': 'yes',
  'x-twitter-client-language': 'en',
  'content-type': 'application/json',
  accept: '*/*',
  'accept-language': 'en-US,en;q=0.9',
  referer: 'https://x.com/',
  'user-agent': UA,
  cookie: `auth_token=${cookies.auth_token}; ct0=${cookies.ct0}`,
};

const FEATURES = {
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

(async () => {
  const twid = decodeURIComponent(cookies.twid || '');
  const uid = (twid.match(/u=(\d+)/) || [])[1];
  console.log('userId from twid:', uid);

  // 1) Viewer
  for (const vars of [{}, { withCommunitiesMemberships: true }]) {
    const qs = new URLSearchParams({
      variables: JSON.stringify(vars),
      features: JSON.stringify(FEATURES),
    });
    const r = await request('x.com', `/i/api/graphql/${IDS.Viewer.qid}/Viewer?${qs}`, H);
    const text = r.body.toString('utf8');
    console.log(`\nViewer vars=${JSON.stringify(vars)} -> ${r.status} (${text.length} bytes)`);
    if (r.status === 200) {
      fs.writeFileSync(path.join(OUT, 'viewer.json'), text);
      const j = JSON.parse(text);
      const v = j?.data?.viewer;
      console.log('  viewer key present:', !!v, '| keys:', v ? Object.keys(v).join(',') : '-');
      const u = v?.user_results?.result;
      if (u) {
        console.log('  screen_name:', u?.core?.screen_name,
          '| name:', u?.core?.name,
          '| id:', u?.rest_id,
          '| avatar:', u?.avatar?.image_url);
        console.log('  followers:', u?.relationship_counts?.followers,
          '| following:', u?.relationship_counts?.following);
      }
      break;
    } else {
      console.log('  body:', text.slice(0, 200));
    }
  }

  // 2) Likes
  if (uid) {
    const vars = {
      userId: uid, count: 5, includePromotedContent: false,
      withClientEventToken: false, withBirdwatchNotes: false, withVoice: false, withV2Timeline: true,
    };
    const qs = new URLSearchParams({
      variables: JSON.stringify(vars),
      features: JSON.stringify(FEATURES),
      fieldToggles: JSON.stringify({ withArticlePlainText: false }),
    });
    const r = await request('x.com', `/i/api/graphql/${IDS.Likes.qid}/Likes?${qs}`, H);
    const text = r.body.toString('utf8');
    console.log(`\nLikes -> ${r.status} (${text.length} bytes)`);
    const j = JSON.parse(text);
    const u = j?.data?.user?.result;
    const inst = u?.timeline?.timeline?.instructions || u?.timeline_v2?.timeline?.instructions || [];
    const add = inst.find((i) => i.type === 'TimelineAddEntries');
    const tweets = (add?.entries || []).filter((e) => (e.entryId || '').startsWith('tweet-'));
    console.log('  timeline present:', inst.length > 0, '| tweets:', tweets.length);
    for (const t of tweets.slice(0, 3)) {
      const res = t.content?.itemContent?.tweet_results?.result;
      const tw = res?.__typename === 'TweetWithVisibilityResults' ? res.tweet : res;
      const text2 = tw?.legacy?.full_text || '';
      const who = tw?.core?.user_results?.result?.core?.screen_name;
      console.log('   -', who, '|', text2.replace(/\s+/g, ' ').slice(0, 50));
    }
  }
})().catch((e) => { console.error('FATAL', e.message); process.exit(1); });
