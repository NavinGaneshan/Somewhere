/**
 * Extract deals from scraped social posts (Instagram / Facebook).
 *
 * Very different pipeline from website extraction:
 *   - Social posts have a low signal-to-noise ratio; most are brand voice.
 *   - Posts are event-driven (specific date ranges), not weekly recurring.
 *   - Prompt must be *more skeptical* than the website prompt and default to [].
 *
 * Pipeline:
 *   1. Pre-filter posts via regex — skip anything without a price/discount/day/time hint.
 *      Cheap filter, avoids sending vibe-only posts to Claude.
 *   2. Batch the surviving posts into one prompt with per-post separators.
 *   3. Send to Claude with the social-specific system prompt.
 *   4. Return normalized deal candidates tagged with the source post URL.
 */

const axios = require("axios");

const ANTHROPIC_ENDPOINT = "https://api.anthropic.com/v1/messages";
const ANTHROPIC_MODEL = "claude-haiku-4-5-20251001";
const MAX_TEXT_CHARS_PER_POST = 800;
const MAX_POSTS_PER_BATCH = 12;

// System prompt tuned for social posts. Key differences from the website prompt:
//   - Emphasizes "usually not a deal, be skeptical"
//   - Explicitly says to default to []
//   - Interprets relative dates ("tomorrow", "wednesday", "this weekend") against
//     the post date, so one-off event promos become one-day deals not recurring ones
//   - Says posts are dated so use the timestamp for context
const SOCIAL_SYSTEM_PROMPT = `You extract happy hour and specials deals from a bar/restaurant's social media posts. Most posts are brand or vibe content — extract nothing from those. Be skeptical. Return ONLY a JSON object.

INCLUDE a deal ONLY when the post CLEARLY says all of:
• A specific food, drink, or bar-event item
• A specific price ($6, half off, 50% off, 2-for-1, free with X, etc.)
• A specific time window OR day OR date range. If the post says "tonight" or "this weekend", use the post date to infer.

EXCLUDE:
• Vibe / brand posts with no price or specific offer
• "Come check us out", "Great cocktails", "Match day today"
• Menu items shown without discount
• Ongoing brand collaborations without a price

Each post is wrapped in <POST id="X" date="YYYY-MM-DD"> ... </POST>. The id is a stable index — return it as postId with each deal so we know which post produced it. The date is the post date; use it as "today" when interpreting relative references.

# RECURRING vs ONE-DAY EVENT — this is critical

A post that mentions a specific day is USUALLY promoting a one-time event, not
setting up a recurring weekly deal. Assume ONE-DAY unless the language is
explicitly recurring.

ONE-DAY signals (set startDate = endDate = the specific date, leave days: []):
  • "today", "tonight", "this evening"           → postDate
  • "tomorrow", "tomorrow night"                 → postDate + 1
  • A day name ("wednesday", "this friday",      → the next such day on/after
    "friday night", "on saturday")                  postDate
  • "next wednesday"                             → the wednesday one week after
                                                    the next wednesday
  • A specific date ("July 15", "7/15", "the      → that exact date, same year
    15th", "Jul 15")                                as postDate
  • Event references — "for the Braves game",     → the date of that event; if
    "watch party", "trivia night", "opening         event date isn't stated,
    day", concert names, holiday names               use postDate + implied day
  • "this weekend"                                → startDate = next Saturday,
                                                    endDate = next Sunday
  • "through July 15" / "until Aug 1"             → startDate = postDate,
                                                    endDate = that date

RECURRING signals (set days: [...], omit startDate/endDate):
  • "every wednesday", "wednesdays", "weekly"
  • "our monday special", "mondays and tuesdays"
  • "every day", "daily", "seven days a week"
  • "weekdays", "weekends"
  • Generic hours language ("4-7pm every day")

If ambiguous, prefer ONE-DAY (safer — event promos are more common on social).

TITLE: 2–5 words: item + price/discount (e.g. "Wings $6", "House Marg Half Off", "Trivia Night")
CATEGORY: "drinks", "food", or "activity"
DAYS: lowercase day names. Leave empty [] for one-day events (dates carry the timing).
TIMES: 24-hour "HH:MM". Default 16:00–19:00 for happy hour if hours are unclear but window is implied.
CONFIDENCE: 0.0–1.0. Social posts should start at 0.5 max; only reach 0.8+ when price and timing are fully explicit.
STARTDATE / ENDDATE: "YYYY-MM-DD". Required for one-day events. Omit for truly recurring deals.

Examples:

  Post 2026-07-13: "$5 margaritas Tuesday for the Braves game 🌮"
  → title: "Margarita $5", category: "drinks", days: [],
     startDate: "2026-07-15", endDate: "2026-07-15"   (next Tuesday)

  Post 2026-07-13: "Every Wednesday: $5 margs all day"
  → title: "Margarita $5", category: "drinks", days: ["wednesday"],
     (no startDate/endDate — recurring)

  Post 2026-07-13: "Tonight only — half off apps 6-9pm"
  → title: "Apps Half Off", category: "food", days: [],
     startTime: "18:00", endTime: "21:00",
     startDate: "2026-07-13", endDate: "2026-07-13"

  Post 2026-07-13: "Happy hour 4-7 Mon-Fri, come thru"
  → title: "Happy Hour", days: ["monday","tuesday","wednesday","thursday","friday"],
     startTime: "16:00", endTime: "19:00" (no dates — recurring)

Respond with ONLY this JSON, nothing else:
{"deals":[{"postId":"3","title":"...","description":"...","category":"drinks","days":[],"startTime":"16:00","endTime":"19:00","confidence":0.6,"startDate":"2026-07-15","endDate":"2026-07-15"}]}

If nothing qualifies from any post: {"deals":[]}`;

/**
 * Cheap regex pre-filter — returns true if the post text mentions any deal signal.
 * Anything else is almost certainly not a deal.
 */
function looksLikeDealPost(text) {
  if (!text || text.length < 10) return false;

  const dealSignals = [
    /\$\s*\d/,                                    // "$6", "$ 12"
    /\b\d+\s*(?:for|\/)\s*\$\s*\d+\b/i,           // "3 for $10"
    /\b\d{1,3}\s*%\s*off\b/i,                     // "50% off"
    /\bhalf[-\s]?(?:off|price)\b/i,               // "half off"
    /\bbogo\b/i,                                  // BOGO
    /\bbuy\s+one[\s\w]{0,10}\bget\s+one\b/i,      // "buy one get one"
    /\b2[\s-]?for[\s-]?1\b/i,                     // "2 for 1"
    /\bhappy[\s-]?hour\b/i,                       // "happy hour"
    /\bspecials?\b/i,                             // "specials", "special"
    /\btrivia\b|\bkaraoke\b|\bbingo\b/i,          // named bar events
    /\b(?:free|complimentary)\s+\w+/i,            // "free shot", "free apps"
    /\b\d{1,2}(?::\d{2})?\s*(?:am|pm)\b/i,        // "5pm", "10:30 PM"
  ];

  return dealSignals.some((rx) => rx.test(text));
}

/**
 * @param {Array<{text:string, url:string|null, timestamp:string|null}>} posts
 * @returns {Array<{index:number, text:string, url:string|null, dateISO:string|null}>}
 */
function preparePostBatch(posts) {
  return posts
      .filter((p) => p && p.text && looksLikeDealPost(p.text))
      .slice(0, MAX_POSTS_PER_BATCH)
      .map((p, i) => ({
        index: i,
        text: p.text.substring(0, MAX_TEXT_CHARS_PER_POST),
        url: p.url || null,
        dateISO: dateToISO(p.timestamp),
      }));
}

function dateToISO(ts) {
  if (!ts) return null;
  try {
    const d = new Date(ts);
    if (isNaN(d.getTime())) return null;
    return d.toISOString().split("T")[0];
  } catch (_) {
    return null;
  }
}

function buildUserPrompt(batch, source) {
  const wrapped = batch
      .map((p) => `<POST id="${p.index}" date="${p.dateISO || "unknown"}">\n${p.text}\n</POST>`)
      .join("\n\n");
  return `Extract deals from these ${source} posts. Follow the rules exactly. Be skeptical.\n\n${wrapped}`;
}

let _lastCall = 0;
const MIN_INTERVAL_MS = 1500;

async function _throttle() {
  const elapsed = Date.now() - _lastCall;
  if (elapsed < MIN_INTERVAL_MS) {
    await new Promise((r) => setTimeout(r, MIN_INTERVAL_MS - elapsed));
  }
  _lastCall = Date.now();
}

/**
 * @param {Array} posts - raw posts from Apify (must have .text, .url, .timestamp)
 * @param {string} source - "instagram" or "facebook" (for logging/context)
 * @param {string} anthropicApiKey
 * @returns {Promise<{extractedDeals: Array, postsFilteredIn: number, postsFilteredOut: number}>}
 */
async function extractDealsFromSocialPosts(posts, source, anthropicApiKey) {
  const totalPosts = Array.isArray(posts) ? posts.length : 0;
  const batch = preparePostBatch(posts || []);
  const filteredIn = batch.length;
  const filteredOut = totalPosts - filteredIn;

  if (filteredIn === 0) {
    return { extractedDeals: [], postsFilteredIn: 0, postsFilteredOut: totalPosts };
  }
  if (!anthropicApiKey) {
    console.warn("Anthropic key not configured; skipping social LLM extraction");
    return { extractedDeals: [], postsFilteredIn: filteredIn, postsFilteredOut: filteredOut };
  }

  await _throttle();

  const userContent = buildUserPrompt(batch, source);

  const body = {
    model: ANTHROPIC_MODEL,
    max_tokens: 1500,
    system: SOCIAL_SYSTEM_PROMPT,
    messages: [{ role: "user", content: userContent }],
  };

  let raw = "";
  try {
    const response = await axios.post(ANTHROPIC_ENDPOINT, body, {
      headers: {
        "Content-Type": "application/json",
        "x-api-key": anthropicApiKey,
        "anthropic-version": "2023-06-01",
      },
      timeout: 30000,
      validateStatus: () => true,
    });

    if (response.status !== 200) {
      console.error("Anthropic HTTP", response.status, JSON.stringify(response.data).substring(0, 300));
      return { extractedDeals: [], postsFilteredIn: filteredIn, postsFilteredOut: filteredOut };
    }

    raw = response.data?.content?.[0]?.text || "";
  } catch (err) {
    console.error("extractDealsFromSocialPosts request error:", err.message);
    return { extractedDeals: [], postsFilteredIn: filteredIn, postsFilteredOut: filteredOut };
  }

  const jsonStart = raw.indexOf("{");
  const jsonEnd = raw.lastIndexOf("}");
  if (jsonStart === -1 || jsonEnd === -1) {
    console.warn("extractDealsFromSocialPosts: no JSON object in response");
    return { extractedDeals: [], postsFilteredIn: filteredIn, postsFilteredOut: filteredOut };
  }

  let parsed;
  try {
    parsed = JSON.parse(raw.substring(jsonStart, jsonEnd + 1));
  } catch (err) {
    console.warn("extractDealsFromSocialPosts JSON parse failed:", err.message);
    return { extractedDeals: [], postsFilteredIn: filteredIn, postsFilteredOut: filteredOut };
  }

  const rawDeals = Array.isArray(parsed.deals) ? parsed.deals : [];
  // Attach sourceURL from the post index → post URL map, and mark source platform.
  const mapped = rawDeals.map((d) => {
    const idx = Number(d.postId);
    const post = Number.isFinite(idx) ? batch[idx] : null;
    return {
      title: d.title || "",
      description: d.description || d.title || "",
      category: d.category || "drinks",
      days: Array.isArray(d.days) ? d.days : [],
      startTime: d.startTime || "16:00",
      endTime: d.endTime || "19:00",
      confidence: typeof d.confidence === "number" ? d.confidence : 0.5,
      startDate: d.startDate || null,   // ISO YYYY-MM-DD
      endDate:   d.endDate   || null,
      sourceURL: post?.url || null,
      sourcePlatform: source,
    };
  });

  // Drop deals whose endDate has already passed. This is where "$5 margs Tuesday
  // for the Braves game" from last week gets filtered out — the prompt tells
  // Claude to encode single-day events as startDate=endDate, so an expired one-
  // day event naturally has an endDate strictly before today.
  const todayISO = new Date().toISOString().split("T")[0];
  const withoutExpired = mapped.filter((d) => !d.endDate || d.endDate >= todayISO);
  const expiredCount = mapped.length - withoutExpired.length;

  const extractedDeals = withoutExpired.filter((d) => d.title && d.title.length >= 2);

  return {
    extractedDeals,
    postsFilteredIn: filteredIn,
    postsFilteredOut: filteredOut,
    expiredCount,
  };
}

module.exports = {
  extractDealsFromSocialPosts,
  looksLikeDealPost,
  preparePostBatch,
};
