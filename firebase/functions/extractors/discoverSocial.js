/**
 * Discover a venue's Instagram handle and Facebook page URL.
 *
 * Strategy:
 *   1. If a website URL is given, scrape it via Firecrawl and regex-extract social links.
 *   2. For anything not found on the website, run a Google search via Firecrawl's
 *      `site:instagram.com "Venue Name" "City, State"` query and pick the first URL
 *      that looks like a real profile (not a post, share widget, or search result).
 *
 * Returns { instagramHandle, facebookURL, sources: { instagram, facebook } }
 * where each source is either "website", "google", or null.
 */

const axios = require("axios");

const FIRECRAWL_SCRAPE_ENDPOINT = "https://api.firecrawl.dev/v1/scrape";
const FIRECRAWL_SEARCH_ENDPOINT = "https://api.firecrawl.dev/v1/search";

// URL slugs that aren't real profile pages — skip if the extracted "handle" matches these.
// Expanded to include the surprise culprits: "popular", "reels_popular", topic aggregation
// pages, hashtag pages, "creator" landing pages, etc.
const IG_BLOCKED_SLUGS = new Set([
  "p", "reel", "reels", "reels_popular", "tv", "explore", "stories", "accounts",
  "developer", "about", "directory", "web", "invites", "download",
  "popular", "trending", "topic", "topics", "tags", "hashtag", "hashtags",
  "locations", "direct", "creator", "creators", "challenges", "guides",
  "shop", "shopping", "map", "graphql", "api", "help", "legal", "privacy",
  "terms", "language", "web_appeal", "session", "login", "signup",
  "oauth", "features", "press", "brand",
]);
const FB_BLOCKED_SLUGS = new Set([
  "sharer", "dialog", "share", "events", "watch", "gaming", "marketplace",
  "pages", "groups", "help", "policies", "business", "ads", "profile.php",
  "login", "signup", "recover", "notes", "photo.php", "video.php",
  "search", "settings", "l.php", "reels", "reel", "story.php", "stories",
  "hashtag", "hashtags", "public", "people", "places", "topic", "topics",
  "gaming.php", "download", "media", "photos", "videos", "album",
  "reg", "r.php", "checkpoint", "help.php", "policy.php", "terms.php",
]);

/**
 * Parse a URL and return the profile handle if it's a valid single-segment profile URL.
 * Robust to multi-segment paths (which are almost never profiles).
 *
 * Accepts:  https://www.instagram.com/thelocalatl
 * Accepts:  https://www.instagram.com/thelocalatl/
 * Rejects:  https://www.instagram.com/popular/
 * Rejects:  https://www.instagram.com/p/ABC123/
 * Rejects:  https://www.instagram.com/thelocalatl/reel/xyz/
 * Rejects:  anything not matching instagram.com or facebook.com
 */
function parseProfileHandle(urlString, platform) {
  if (!urlString || typeof urlString !== "string") return null;

  let parsed;
  try {
    parsed = new URL(urlString);
  } catch (_) {
    return null;
  }

  const host = parsed.hostname.toLowerCase().replace(/^www\.|^m\./, "");
  if (platform === "instagram" && host !== "instagram.com") return null;
  if (platform === "facebook"  && host !== "facebook.com")  return null;

  const segments = parsed.pathname.split("/").filter(Boolean);
  if (segments.length !== 1) return null;   // profile URLs are single-segment

  const handle = segments[0];
  const blocklist = platform === "instagram" ? IG_BLOCKED_SLUGS : FB_BLOCKED_SLUGS;
  if (blocklist.has(handle.toLowerCase())) return null;
  if (handle.length < 2 || handle.length > 50) return null;

  // Instagram handles: [A-Za-z0-9._]. Facebook page slugs: [A-Za-z0-9.\-_] (with dashes).
  const validPattern = platform === "instagram"
      ? /^[A-Za-z0-9._]+$/
      : /^[A-Za-z0-9.\-_]+$/;
  if (!validPattern.test(handle)) return null;

  return handle;
}

// Regex just to *find candidate URLs* in a text blob; the URL parser above
// then decides whether each candidate is actually a valid profile URL.
const URL_FINDER_REGEX = /https?:\/\/[^\s"'<>()]+/gi;

/**
 * Scan raw text and hyperlinks for Instagram / Facebook profile URLs.
 * Returns first plausible match for each platform.
 */
function extractSocialLinks(markdown, links = []) {
  // Collect explicit links (highest signal) + URLs found inline in markdown.
  const explicitLinks = Array.isArray(links) ? links.filter((l) => typeof l === "string") : [];
  const inlineUrls = markdown ? (markdown.match(URL_FINDER_REGEX) || []) : [];
  const candidates = [...explicitLinks, ...inlineUrls];

  let instagramHandle = null;
  let fbHandle = null;

  for (const url of candidates) {
    if (!instagramHandle) {
      const h = parseProfileHandle(url, "instagram");
      if (h) instagramHandle = h;
    }
    if (!fbHandle) {
      const h = parseProfileHandle(url, "facebook");
      if (h) fbHandle = h;
    }
    if (instagramHandle && fbHandle) break;
  }

  return {
    instagramHandle,
    facebookURL: fbHandle ? `https://www.facebook.com/${fbHandle}` : null,
  };
}

/**
 * Firecrawl-scrape a URL and return { markdown, links }. Throws on hard failure.
 */
async function firecrawlScrape(url, apiKey) {
  const response = await axios.post(FIRECRAWL_SCRAPE_ENDPOINT, {
    url,
    formats: ["markdown", "links"],
    onlyMainContent: false,   // want footer + sidebar for social links
    timeout: 25000,
  }, {
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${apiKey}`,
    },
    timeout: 35000,
    validateStatus: () => true,
  });

  if (response.status < 200 || response.status >= 300) {
    throw new Error(`Firecrawl scrape HTTP ${response.status}`);
  }
  if (!response.data?.success || !response.data?.data) {
    throw new Error("Firecrawl returned no data");
  }
  return {
    markdown: response.data.data.markdown || "",
    links: response.data.data.links || [],
  };
}

/**
 * Query Google via Firecrawl's search endpoint and return the first URL matching
 * a valid profile pattern for the given platform.
 *
 * @param {string} venueName
 * @param {string} location - e.g. "Atlanta, GA"
 * @param {"instagram" | "facebook"} platform
 * @param {string} apiKey - Firecrawl key
 * @returns {Promise<string | null>} profile handle (IG) or slug (FB)
 */
async function findSocialViaGoogle(venueName, location, platform, apiKey) {
  const domain = platform === "instagram" ? "instagram.com" : "facebook.com";

  // Two queries in order:
  //   1. Unquoted `site:` search — Google ranks canonical profile URLs first when it can.
  //   2. Broader search (no site: operator) — profile URLs still surface for well-known venues.
  //
  // Quoted searches for venue name + location were too strict — profile bios rarely contain
  // the exact string "Atlanta, GA", so Google returned only *posts* whose captions did.
  const queries = [
    `site:${domain} ${venueName}${location ? " " + location : ""}`,
    `${venueName}${location ? " " + location : ""} ${platform === "instagram" ? "instagram profile" : "facebook page"}`,
  ];

  for (const query of queries) {
    try {
      const response = await axios.post(FIRECRAWL_SEARCH_ENDPOINT, {
        query,
        limit: 8,
      }, {
        headers: {
          "Content-Type": "application/json",
          "Authorization": `Bearer ${apiKey}`,
        },
        timeout: 30000,
        validateStatus: () => true,
      });

      if (response.status < 200 || response.status >= 300) {
        console.warn(`Firecrawl search HTTP ${response.status} for platform=${platform}: ${JSON.stringify(response.data).substring(0, 200)}`);
        continue;
      }

      const results = response.data?.data || [];
      const urls = results.map((r) => r.url || r.link).filter(Boolean);

      console.log(
          `findSocialViaGoogle[${platform}] query="${query}" got ${results.length} results:`,
          urls.slice(0, 10),
      );

      for (const url of urls) {
        const handle = parseProfileHandle(url, platform);
        if (handle) return handle;
      }
    } catch (err) {
      console.warn(`Firecrawl search error for ${platform} (query="${query}"):`, err.message);
    }
  }
  return null;
}

/**
 * @param {object} params
 * @param {string} [params.websiteUrl]
 * @param {string} [params.venueName]
 * @param {string} [params.city]
 * @param {string} [params.state]
 * @param {string} params.firecrawlApiKey
 * @returns {Promise<{instagramHandle:string|null, facebookURL:string|null, sources:{instagram:string|null, facebook:string|null}}>}
 */
async function discoverSocialLinks({ websiteUrl, venueName, city, state, firecrawlApiKey }) {
  let instagramHandle = null;
  let facebookURL = null;
  let igSource = null;
  let fbSource = null;

  // Step 1 — scrape the venue's website if given.
  if (websiteUrl) {
    const normalizedUrl = websiteUrl.startsWith("http") ? websiteUrl : `https://${websiteUrl}`;
    try {
      const { markdown, links } = await firecrawlScrape(normalizedUrl, firecrawlApiKey);
      const found = extractSocialLinks(markdown, links);
      if (found.instagramHandle) {
        instagramHandle = found.instagramHandle;
        igSource = "website";
      }
      if (found.facebookURL) {
        facebookURL = found.facebookURL;
        fbSource = "website";
      }
    } catch (err) {
      console.warn(`discoverSocialLinks: website scrape failed for ${normalizedUrl}: ${err.message}`);
    }
  }

  // Step 2 — Google fallback for whatever the website didn't yield.
  const location = [city, state].filter(Boolean).join(", ");
  if (!instagramHandle && venueName) {
    const found = await findSocialViaGoogle(venueName, location, "instagram", firecrawlApiKey);
    if (found) {
      instagramHandle = found;
      igSource = "google";
    }
  }
  if (!facebookURL && venueName) {
    const found = await findSocialViaGoogle(venueName, location, "facebook", firecrawlApiKey);
    if (found) {
      facebookURL = `https://www.facebook.com/${found}`;
      fbSource = "google";
    }
  }

  return {
    instagramHandle,
    facebookURL,
    sources: { instagram: igSource, facebook: fbSource },
  };
}

module.exports = { discoverSocialLinks, extractSocialLinks };
