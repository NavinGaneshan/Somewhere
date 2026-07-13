/**
 * Instagram post scraping via Apify.
 *
 * Uses the `apify/instagram-post-scraper` actor. If you'd rather use a
 * different actor (e.g. `apify/instagram-scraper` for stories + reels + posts),
 * swap ACTOR_ID and adjust the input schema below to match its docs.
 *
 * https://apify.com/apify/instagram-post-scraper
 */

const axios = require("axios");

const ACTOR_ID = "apify~instagram-post-scraper";
const RUN_SYNC_URL = (actor, token) =>
  `https://api.apify.com/v2/acts/${actor}/run-sync-get-dataset-items?token=${token}&clean=1`;

const DEFAULT_MAX_POSTS = 20;
const DEFAULT_TIMEOUT_MS = 90_000;

/**
 * @param {string} handle - Instagram username, with or without leading '@'.
 * @param {object} opts
 * @param {string} opts.apifyToken - Apify API token (from Secret Manager).
 * @param {number} [opts.maxPosts=20]
 * @returns {Promise<{source:string, handle:string, posts:Array, error:string|null}>}
 */
async function scrapeInstagram(handle, { apifyToken, maxPosts = DEFAULT_MAX_POSTS } = {}) {
  if (!handle) {
    return { source: "instagram", handle: null, posts: [], error: null };
  }
  if (!apifyToken) {
    return { source: "instagram", handle, posts: [], error: "APIFY_TOKEN not configured" };
  }

  const cleanHandle = String(handle).replace(/^@/, "").trim();
  if (!cleanHandle) {
    return { source: "instagram", handle, posts: [], error: "invalid handle" };
  }

  const url = RUN_SYNC_URL(ACTOR_ID, apifyToken);
  const body = {
    username: [cleanHandle],
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
        source: "instagram",
        handle: cleanHandle,
        posts: [],
        error: `Apify HTTP ${response.status}: ${preview}`,
      };
    }

    const items = Array.isArray(response.data) ? response.data : [];

    if (items.length > 0) {
      console.log(
          `instagram scraper: ${items.length} raw items, first keys:`,
          Object.keys(items[0]).slice(0, 20),
      );
    }

    const posts = items
        .map(normalizePost)
        .filter((p) => p.text && p.text.trim().length > 0);

    if (items.length > 0 && posts.length === 0) {
      console.warn(
          `instagram scraper: ${items.length} items received but none passed text filter. Sample:`,
          JSON.stringify(items[0]).substring(0, 500),
      );
    }

    return { source: "instagram", handle: cleanHandle, posts, error: null };
  } catch (err) {
    return {
      source: "instagram",
      handle: cleanHandle,
      posts: [],
      error: err.message || "unknown error",
    };
  }
}

/**
 * Normalize a single Apify post record to our common shape.
 * Field names differ slightly between Apify actors — this centralizes the mapping.
 */
function normalizePost(item) {
  return {
    text: item.caption || item.text || "",
    timestamp: item.timestamp || item.taken_at_timestamp || null,
    url: item.url || item.postUrl || null,
    likes: item.likesCount ?? item.likes_count ?? 0,
    comments: item.commentsCount ?? item.comments_count ?? 0,
    type: item.type || null,           // Image | Video | Sidecar
    hashtags: item.hashtags || [],
    mentions: item.mentions || [],
  };
}

module.exports = { scrapeInstagram };
