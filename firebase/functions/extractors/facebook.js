/**
 * Facebook page post scraping via Apify.
 *
 * IMPORTANT: use `apify/facebook-posts-scraper` (returns posts). Do NOT use
 * `apify/facebook-pages-scraper` — that one returns page *metadata* (likes,
 * category, address) with no post text.
 *
 * https://apify.com/apify/facebook-posts-scraper
 */

const axios = require("axios");

const ACTOR_ID = "apify~facebook-posts-scraper";
const RUN_SYNC_URL = (actor, token) =>
  `https://api.apify.com/v2/acts/${actor}/run-sync-get-dataset-items?token=${token}&clean=1`;

const DEFAULT_MAX_POSTS = 20;
const DEFAULT_TIMEOUT_MS = 120_000;   // FB scrapers are typically slower than IG

/**
 * @param {string} pageUrl - Full Facebook page URL, e.g. "https://www.facebook.com/thelocalatl"
 *                          or just "facebook.com/thelocalatl". Vanity URLs and numeric IDs both work.
 * @param {object} opts
 * @param {string} opts.apifyToken
 * @param {number} [opts.maxPosts=20]
 * @returns {Promise<{source:string, pageUrl:string, posts:Array, error:string|null}>}
 */
async function scrapeFacebook(pageUrl, { apifyToken, maxPosts = DEFAULT_MAX_POSTS } = {}) {
  if (!pageUrl) {
    return { source: "facebook", pageUrl: null, posts: [], error: null };
  }
  if (!apifyToken) {
    return { source: "facebook", pageUrl, posts: [], error: "APIFY_TOKEN not configured" };
  }

  const normalized = normalizeFacebookUrl(pageUrl);
  if (!normalized) {
    return { source: "facebook", pageUrl, posts: [], error: "invalid Facebook URL" };
  }

  const url = RUN_SYNC_URL(ACTOR_ID, apifyToken);
  const body = {
    startUrls: [{ url: normalized }],
    resultsLimit: maxPosts,
  };

  try {
    const response = await axios.post(url, body, {
      timeout: DEFAULT_TIMEOUT_MS,
      validateStatus: () => true,
      headers: { "Content-Type": "application/json" },
    });

    if (response.status !== 200 && response.status !== 201) {
      const preview = typeof response.data === "string"
          ? response.data.slice(0, 200)
          : JSON.stringify(response.data).slice(0, 200);
      return {
        source: "facebook",
        pageUrl: normalized,
        posts: [],
        error: `Apify HTTP ${response.status}: ${preview}`,
      };
    }

    const items = Array.isArray(response.data) ? response.data : [];

    // Debug: log shape of first item so we can tune field mapping when Apify's schema drifts.
    if (items.length > 0) {
      const first = items[0];
      console.log(
          `facebook scraper: ${items.length} raw items, first keys:`,
          Object.keys(first).slice(0, 20),
      );
    } else if (typeof response.data === "object" && response.data !== null && !Array.isArray(response.data)) {
      // Apify sometimes wraps in { items: [...] } or returns error info as an object.
      console.warn(
          "facebook scraper: response was object (not array), keys:",
          Object.keys(response.data).slice(0, 10),
      );
    }

    const posts = items
        .map(normalizePost)
        .filter((p) => p.text && p.text.trim().length > 0);

    if (items.length > 0 && posts.length === 0) {
      console.warn(
          `facebook scraper: ${items.length} items received but none passed text filter.` +
          " Field mapping may be wrong. Sample item:",
          JSON.stringify(items[0]).substring(0, 500),
      );
    }

    return { source: "facebook", pageUrl: normalized, posts, error: null };
  } catch (err) {
    return {
      source: "facebook",
      pageUrl: normalized,
      posts: [],
      error: err.message || "unknown error",
    };
  }
}

function normalizeFacebookUrl(input) {
  const raw = String(input).trim();
  if (!raw) return null;

  // Already a full URL
  if (raw.startsWith("http://") || raw.startsWith("https://")) {
    return raw;
  }
  // "facebook.com/foo" or "fb.com/foo"
  if (raw.startsWith("facebook.com") || raw.startsWith("www.facebook.com") || raw.startsWith("fb.com")) {
    return `https://${raw}`;
  }
  // Just a page slug — assume Facebook
  if (/^[A-Za-z0-9.\-_]+$/.test(raw)) {
    return `https://www.facebook.com/${raw}`;
  }
  return null;
}

/**
 * Normalize a single Apify post record to our common shape.
 * Facebook actor field names vary; we accept the most common variants.
 */
function normalizePost(item) {
  return {
    text: item.text || item.postText || item.message || "",
    timestamp: item.time || item.timestamp || item.date || null,
    url: item.url || item.postUrl || item.postId || null,
    reactions: item.reactionsCount ?? item.reactions ?? 0,
    comments: item.commentsCount ?? item.comments ?? 0,
    shares: item.sharesCount ?? item.shares ?? 0,
    postType: item.postType || item.type || null,
  };
}

module.exports = { scrapeFacebook };
