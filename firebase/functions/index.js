/**
 * Somewhere - Firebase Cloud Functions
 * Happy Hour Deal Discovery Platform
 */

const functions = require("firebase-functions");
const { defineSecret } = require("firebase-functions/params");
const admin = require("firebase-admin");
const axios = require("axios");
const cheerio = require("cheerio");

admin.initializeApp();
const db = admin.firestore();

// ============================================================
// SECRETS (Google Cloud Secret Manager via firebase-functions/params)
// Set with: firebase functions:secrets:set ANTHROPIC_KEY
//           firebase functions:secrets:set FIRECRAWL_KEY
// ============================================================
const anthropicKey = defineSecret("ANTHROPIC_KEY");
const firecrawlKey = defineSecret("FIRECRAWL_KEY");

// ============================================================
// CONSTANTS
// ============================================================
// PLACES_API_KEY is still on the legacy functions.config() system; migrate later.
const PLACES_API_KEY = functions.config().places?.api_key || process.env.PLACES_API_KEY;
const PLACES_API_BASE = "https://maps.googleapis.com/maps/api/place";
const ANTHROPIC_ENDPOINT = "https://api.anthropic.com/v1/messages";
const FIRECRAWL_SCRAPE_ENDPOINT = "https://api.firecrawl.dev/v1/scrape";
const ANTHROPIC_MODEL = "claude-haiku-4-5-20251001";

// Mirrors the prompt in the (now-removed) iOS AnthropicService.
const ANTHROPIC_SYSTEM_PROMPT = `You extract happy hour and daily specials deals from bar/restaurant text. Return ONLY a JSON object — no markdown fences, no explanation before or after.

INCLUDE a deal when ALL of these are true:
• It names a food or drink item (or a bar event like trivia/karaoke)
• It has a price, discount, or offer (e.g. $6, half off, 50% off, 2-for-1, half-priced, complimentary)
• It is tied to specific days or a time window. If the section is labelled "Happy Hour", "Specials", or a day of the week, use those as context.

EXCLUDE:
• Regular full-price menu items with no discount
• Generic descriptions with no price or offer
• Standard cocktail/drink menus unless they explicitly reference a special, discount, or time offer

TITLE: 2–5 words, item name + price or discount (e.g. "House Margarita $6", "Wings Half Off", "Draft Beer $4", "Trivia Night")
CATEGORY: "drinks", "food", or "activity"
DAYS: lowercase array of day names
TIMES: 24-hour "HH:MM". Default happy hour: startTime "16:00", endTime "19:00"
CONFIDENCE: 0.0–1.0

Respond with ONLY this JSON, nothing else:
{"deals":[{"title":"...","description":"...","category":"drinks","days":["monday"],"startTime":"16:00","endTime":"19:00","confidence":0.85}]}

If nothing qualifies: {"deals":[]}`;

const FIRECRAWL_DEAL_LINK_PATTERN = /(menu|happy.?hour|happyhour|specials?|deals?|cocktails?|drinks?|promotions?|events?)/i;
const CLOSURE_KEYWORDS = [
  "permanently closed", "we are closed", "out of business",
  "closed permanently", "no longer open", "has closed",
  "closing permanently", "we have closed", "restaurant is closed",
  "this location is closed",
];
const MAX_SUBPAGES = 3;
const MAX_TEXT_CHARS = 8000;

// Serialize Anthropic calls to stay under the 50 req/min rate limit.
let _lastAnthropicCall = 0;
const ANTHROPIC_MIN_INTERVAL_MS = 1500;

async function _throttleAnthropic() {
  const elapsed = Date.now() - _lastAnthropicCall;
  if (elapsed < ANTHROPIC_MIN_INTERVAL_MS) {
    await sleep(ANTHROPIC_MIN_INTERVAL_MS - elapsed);
  }
  _lastAnthropicCall = Date.now();
}

/**
 * Sends text to Claude and returns the parsed deals array.
 * Returns [] on any error so callers can fall back gracefully.
 */
async function extractDealsViaAnthropic(text, sourceURL, apiKey) {
  if (!apiKey) {
    console.warn("Anthropic key not configured; skipping LLM extraction");
    return [];
  }
  const trimmed = (text || "").substring(0, MAX_TEXT_CHARS).trim();
  if (!trimmed) return [];

  await _throttleAnthropic();

  let userContent = "Extract happy hour deals from this text";
  if (sourceURL) userContent += ` (source: ${sourceURL})`;
  userContent += `:\n\n${trimmed}`;

  const body = {
    model: ANTHROPIC_MODEL,
    max_tokens: 1024,
    system: ANTHROPIC_SYSTEM_PROMPT,
    messages: [{ role: "user", content: userContent }],
  };

  for (let attempt = 1; attempt <= 2; attempt++) {
    try {
      const response = await axios.post(ANTHROPIC_ENDPOINT, body, {
        headers: {
          "Content-Type": "application/json",
          "x-api-key": apiKey,
          "anthropic-version": "2023-06-01",
        },
        timeout: 30000,
        validateStatus: () => true,
      });

      if (response.status === 429 && attempt === 1) {
        console.warn("Anthropic 429; retrying after 5s");
        await sleep(5000);
        _lastAnthropicCall = Date.now();
        continue;
      }
      if (response.status !== 200) {
        console.error("Anthropic HTTP", response.status, JSON.stringify(response.data).substring(0, 300));
        return [];
      }

      const rawText = response.data?.content?.[0]?.text || "";
      const start = rawText.indexOf("{");
      const end = rawText.lastIndexOf("}");
      if (start === -1 || end === -1) {
        console.error("Anthropic: no JSON object in response:", rawText.substring(0, 200));
        return [];
      }
      try {
        const parsed = JSON.parse(rawText.substring(start, end + 1));
        return Array.isArray(parsed.deals) ? parsed.deals : [];
      } catch (parseErr) {
        console.error("Anthropic JSON parse failed:", parseErr.message, rawText.substring(0, 200));
        return [];
      }
    } catch (err) {
      console.error("Anthropic request error:", err.message);
      return [];
    }
  }
  return [];
}

/**
 * Scrape one URL via Firecrawl. Throws on hard failure so callers can decide
 * whether to swallow (subpages) or surface (main page) the error.
 */
async function firecrawlScrape(url, apiKey) {
  if (!apiKey) {
    throw new functions.https.HttpsError("failed-precondition", "Firecrawl API key not configured");
  }
  const response = await axios.post(FIRECRAWL_SCRAPE_ENDPOINT, {
    url,
    formats: ["markdown", "links"],
    onlyMainContent: true,
    timeout: 25000,
  }, {
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${apiKey}`,
    },
    timeout: 35000,
    validateStatus: () => true,
  });

  if (response.status === 402 || response.status === 429) {
    throw new functions.https.HttpsError("resource-exhausted", "Firecrawl quota exceeded");
  }
  if (response.status < 200 || response.status >= 300) {
    console.error("Firecrawl HTTP", response.status, "for", url);
    throw new functions.https.HttpsError("internal", `Firecrawl HTTP ${response.status}`);
  }
  if (!response.data?.success || !response.data?.data) {
    throw new functions.https.HttpsError("internal", "Firecrawl returned no data");
  }
  return {
    markdown: response.data.data.markdown || "",
    links: response.data.data.links || [],
  };
}

// ============================================================
// PVA - PROGRESSIVE VENUE ADDITION
// ============================================================

/**
 * Called when a user performs a search.
 * Triggers PVA to find and process new venues in the area.
 */
exports.triggerPVA = functions
    .runWith({ timeoutSeconds: 300, memory: "512MB" })
    .https.onCall(async (data, context) => {
      if (!context.auth) {
        throw new functions.https.HttpsError("unauthenticated", "Must be authenticated.");
      }

      const { latitude, longitude, radiusMiles = 1.0 } = data;
      if (!latitude || !longitude) {
        throw new functions.https.HttpsError("invalid-argument", "latitude and longitude required.");
      }

      try {
        const result = await processPVA(latitude, longitude, radiusMiles, context.auth.uid);
        return result;
      } catch (err) {
        console.error("PVA error:", err);
        throw new functions.https.HttpsError("internal", err.message);
      }
    });

/**
 * Core PVA processing logic
 */
async function processPVA(latitude, longitude, radiusMiles, userId) {
  const config = await getPVAConfig();
  if (!config.pvaModeEnabled) return { skipped: true, reason: "PVA disabled" };

  // Check API quota
  if (config.dailyApiCallCount >= config.maxPlacesApiCallsPerDay) {
    return { skipped: true, reason: "API quota reached" };
  }

  const cellIds = getGridCellIds(latitude, longitude, radiusMiles);
  const result = { newVenues: 0, existingVenues: 0, closedVenues: 0, apiCalls: 0, cells: [] };

  // Get existing venue place IDs in area
  const bounds = getBoundingBox(latitude, longitude, radiusMiles);
  const existingVenuesSnap = await db.collection("venues")
      .where("latitude", ">=", bounds.minLat)
      .where("latitude", "<=", bounds.maxLat)
      .get();

  const existingPlaceIds = new Set(
      existingVenuesSnap.docs
          .filter((d) => {
            const lng = d.data().longitude;
            return lng >= bounds.minLng && lng <= bounds.maxLng;
          })
          .map((d) => d.data().placeId)
  );

  for (const cellId of cellIds) {
    const cellRef = db.collection("pvaCells").doc(cellId);
    const cell = await cellRef.get();

    // Skip if recently searched
    if (cell.exists) {
      const lastSearched = cell.data().lastSearchedAt?.toDate();
      const ageDays = lastSearched ? (Date.now() - lastSearched.getTime()) / 86400000 : Infinity;
      if (ageDays < config.cellStaleDays) continue;
    }

    const cellCenter = getCellCenter(cellId);
    const radiusMeters = Math.round(config.cellSizeMiles * 1609.34 * 1.5);

    // Search Google Places
    const venues = await searchNearbyVenues(cellCenter.lat, cellCenter.lng, radiusMeters);
    result.apiCalls++;

    let cellNewCount = 0;
    for (const venue of venues) {
      if (venue.isPermanentlyClosed) {
        // Mark existing venue as closed
        const existingSnap = await db.collection("venues")
            .where("placeId", "==", venue.placeId)
            .limit(1)
            .get();
        if (!existingSnap.empty) {
          await existingSnap.docs[0].ref.update({
            isPermanentlyClosed: true,
            updatedAt: admin.firestore.Timestamp.now(),
          });
          result.closedVenues++;
        }
        continue;
      }

      if (existingPlaceIds.has(venue.placeId)) {
        result.existingVenues++;
        continue;
      }

      // New venue - add to database
      if (cellNewCount < config.maxNewVenuesPerSearch) {
        await addVenueToDB(venue, cellIds);
        existingPlaceIds.add(venue.placeId);
        result.newVenues++;
        cellNewCount++;

        // Schedule website scan if enabled
        if (config.autoScanWebsites && venue.website) {
          await scheduleWebsiteScan(venue);
        }
      }
    }

    // Update cell record
    await cellRef.set({
      id: cellId,
      centerLatitude: cellCenter.lat,
      centerLongitude: cellCenter.lng,
      lastSearchedAt: admin.firestore.Timestamp.now(),
      venueCount: (cell.data()?.venueCount || 0) + cellNewCount,
      searchCount: (cell.data()?.searchCount || 0) + 1,
      isStale: false,
      createdAt: cell.data()?.createdAt || admin.firestore.Timestamp.now(),
    }, { merge: true });

    result.cells.push(cellId);

    // Update API counter
    await db.collection("config").doc("pva").update({
      dailyApiCallCount: admin.firestore.FieldValue.increment(1),
    });

    if (result.newVenues >= config.maxNewVenuesPerSearch) break;
  }

  // Log search
  await db.collection("searchLogs").add({
    userId,
    latitude,
    longitude,
    radius: radiusMiles,
    newVenuesFound: result.newVenues,
    apiCallsMade: result.apiCalls,
    timestamp: admin.firestore.Timestamp.now(),
    cellsSearched: result.cells,
  });

  return result;
}

// ============================================================
// WEBSITE SCANNING
// ============================================================

/**
 * Scan a venue website to extract happy hour deals.
 * Pipeline: Firecrawl scrape (main + dealish subpages) → Claude extraction.
 * Called by the mobile app when a user provides a URL.
 */
exports.scanWebsite = functions
    .runWith({
      timeoutSeconds: 120,
      memory: "512MB",
      secrets: [anthropicKey, firecrawlKey],
    })
    .https.onCall(async (data, context) => {
      if (!context.auth) {
        throw new functions.https.HttpsError("unauthenticated", "Must be authenticated.");
      }

      const { url } = data || {};
      if (!url || typeof url !== "string") {
        throw new functions.https.HttpsError("invalid-argument", "URL required.");
      }

      const ANTHROPIC = anthropicKey.value();
      const FIRECRAWL = firecrawlKey.value();
      const normalizedUrl = url.startsWith("http") ? url : `https://${url}`;

      try {
        // 1. Scrape main page (hard failure if this errors)
        const main = await firecrawlScrape(normalizedUrl, FIRECRAWL);

        // 2. Closure detection — if the homepage announces closure, skip extraction
        const lowerMd = main.markdown.toLowerCase();
        if (CLOSURE_KEYWORDS.some((k) => lowerMd.includes(k))) {
          console.log("scanWebsite: closure detected at", normalizedUrl);
          return {
            url: normalizedUrl,
            extractedDeals: [],
            isPermanentlyClosed: true,
            extractionMethod: "firecrawl+claude",
          };
        }

        // 3. Find deal-relevant subpages on the same host
        let rootHost;
        try {
          rootHost = new URL(normalizedUrl).host;
        } catch (_) {
          rootHost = null;
        }
        const subLinks = main.links
            .filter((l) => typeof l === "string" && FIRECRAWL_DEAL_LINK_PATTERN.test(l))
            .filter((l) => {
              try {
                return rootHost && new URL(l).host === rootHost;
              } catch (_) {
                return false;
              }
            })
            .filter((l) => l !== normalizedUrl)
            .slice(0, MAX_SUBPAGES);

        // 4. Scrape subpages (swallow errors — main page already succeeded)
        let combined = main.markdown;
        for (const link of subLinks) {
          try {
            const sub = await firecrawlScrape(link, FIRECRAWL);
            if (sub.markdown) {
              combined += "\n\n---\n\n" + sub.markdown;
              console.log(`scanWebsite: scraped subpage ${link} (${sub.markdown.length} chars)`);
            }
          } catch (subErr) {
            console.warn(`scanWebsite: subpage ${link} failed:`, subErr.message);
          }
        }

        console.log(`scanWebsite: total markdown ${combined.length} chars for ${normalizedUrl}`);

        // 5. Claude extraction
        const deals = await extractDealsViaAnthropic(combined, normalizedUrl, ANTHROPIC);
        return {
          url: normalizedUrl,
          extractedDeals: deals,
          isPermanentlyClosed: false,
          extractionMethod: "firecrawl+claude",
        };
      } catch (err) {
        if (err instanceof functions.https.HttpsError) throw err;
        console.error("scanWebsite error:", err.message);
        throw new functions.https.HttpsError("internal", `Failed to scan website: ${err.message}`);
      }
    });

/**
 * Extract deals from arbitrary text (e.g. OCR output from a menu photo).
 * Called by PhotoScanService after on-device Vision OCR.
 */
exports.extractDealsFromText = functions
    .runWith({
      timeoutSeconds: 60,
      memory: "256MB",
      secrets: [anthropicKey],
    })
    .https.onCall(async (data, context) => {
      if (!context.auth) {
        throw new functions.https.HttpsError("unauthenticated", "Must be authenticated.");
      }
      const { text, sourceURL } = data || {};
      if (!text || typeof text !== "string" || !text.trim()) {
        return { extractedDeals: [] };
      }
      try {
        const ANTHROPIC = anthropicKey.value();
        const deals = await extractDealsViaAnthropic(text, sourceURL || null, ANTHROPIC);
        return { extractedDeals: deals };
      } catch (err) {
        console.error("extractDealsFromText error:", err.message);
        throw new functions.https.HttpsError("internal", `Extraction failed: ${err.message}`);
      }
    });

function extractDealsWithRegex(text, sourceUrl) {
  const lower = text.toLowerCase();
  const deals = [];

  // Find happy hour section
  const hhIndex = lower.indexOf("happy hour");
  if (hhIndex === -1) {
    return { success: true, url: sourceUrl, extractedDeals: [], extractionMethod: "regex" };
  }

  // Extract surrounding text
  const section = text.substring(Math.max(0, hhIndex - 100), Math.min(text.length, hhIndex + 2000));

  // Extract time patterns
  const timePattern = /(\d{1,2}(?::\d{2})?\s*(?:am|pm)?)\s*(?:-|to|–|until)\s*(\d{1,2}(?::\d{2})?\s*(?:am|pm))/gi;
  const timeMatches = [...section.matchAll(timePattern)];

  // Extract day patterns
  const days = extractDays(lower.substring(hhIndex, hhIndex + 500));

  if (timeMatches.length > 0) {
    deals.push({
      title: "Happy Hour Special",
      description: section.substring(0, 300).trim(),
      category: "drinks",
      days: days.length > 0 ? days : ["monday", "tuesday", "wednesday", "thursday", "friday"],
      startTime: parseTime(timeMatches[0][1]) || "16:00",
      endTime: parseTime(timeMatches[0][2]) || "19:00",
    });
  }

  return { success: true, url: sourceUrl, extractedDeals: deals, extractionMethod: "regex" };
}

function extractDays(text) {
  const dayMap = {
    "monday|mon\\b": "monday",
    "tuesday|tue\\b|tues\\b": "tuesday",
    "wednesday|wed\\b": "wednesday",
    "thursday|thu\\b|thurs\\b": "thursday",
    "friday|fri\\b": "friday",
    "saturday|sat\\b": "saturday",
    "sunday|sun\\b": "sunday",
  };

  if (/every day|daily|7 days/i.test(text)) {
    return Object.values(dayMap);
  }
  if (/weekday|mon.{0,5}fri/i.test(text)) {
    return ["monday", "tuesday", "wednesday", "thursday", "friday"];
  }
  if (/weekend/i.test(text)) {
    return ["saturday", "sunday"];
  }

  const found = [];
  for (const [pattern, day] of Object.entries(dayMap)) {
    if (new RegExp(pattern, "i").test(text)) found.push(day);
  }
  return found;
}

function parseTime(timeStr) {
  if (!timeStr) return null;
  const clean = timeStr.trim().toLowerCase();
  const isPM = clean.includes("pm");
  const isAM = clean.includes("am");
  const numbers = clean.replace(/[^0-9:]/g, "");
  const parts = numbers.split(":").map(Number);
  if (!parts[0] && parts[0] !== 0) return null;

  let hour = parts[0];
  const minute = parts[1] || 0;

  if (isPM && hour < 12) hour += 12;
  if (isAM && hour === 12) hour = 0;
  if (!isPM && !isAM && hour < 7) hour += 12;

  return `${String(hour).padStart(2, "0")}:${String(minute).padStart(2, "0")}`;
}

// ============================================================
// SCHEDULED FUNCTIONS
// ============================================================

/**
 * Reset daily API call counter at midnight UTC
 */
exports.resetDailyApiCounter = functions.pubsub
    .schedule("0 0 * * *")
    .timeZone("UTC")
    .onRun(async () => {
      await db.collection("config").doc("pva").update({
        dailyApiCallCount: 0,
        apiCallsResetAt: admin.firestore.Timestamp.now(),
      });
      console.log("Daily API counter reset.");
    });

/**
 * Daily venue reverification - checks if venues are still open
 */
exports.reverifyVenues = functions.pubsub
    .schedule("0 3 * * *")  // 3 AM UTC daily
    .timeZone("UTC")
    .onRun(async () => {
      const config = await getPVAConfig();
      const cutoff = new Date();
      cutoff.setDate(cutoff.getDate() - config.venueReverifyDays);

      const snap = await db.collection("venues")
          .where("isPermanentlyClosed", "==", false)
          .where("lastVerified", "<", admin.firestore.Timestamp.fromDate(cutoff))
          .limit(20)
          .get();

      let verified = 0;
      let closed = 0;

      for (const doc of snap.docs) {
        const venue = doc.data();
        if (!venue.placeId) continue;

        try {
          const details = await getPlaceDetails(venue.placeId);
          if (details?.businessStatus === "CLOSED_PERMANENTLY") {
            await doc.ref.update({
              isPermanentlyClosed: true,
              updatedAt: admin.firestore.Timestamp.now(),
            });
            closed++;
          } else {
            await doc.ref.update({
              lastVerified: admin.firestore.Timestamp.now(),
              updatedAt: admin.firestore.Timestamp.now(),
            });
            verified++;
          }
          await sleep(500);
        } catch (err) {
          console.error(`Error reverifying venue ${venue.name}:`, err.message);
        }
      }

      console.log(`Venue reverification: ${verified} verified, ${closed} marked closed.`);
    });

/**
 * Clean up expired deals
 */
exports.cleanupExpiredDeals = functions.pubsub
    .schedule("0 4 * * *")
    .timeZone("UTC")
    .onRun(async () => {
      const now = admin.firestore.Timestamp.now();
      const snap = await db.collection("deals")
          .where("expiresAt", "<", now)
          .where("status", "==", "active")
          .limit(100)
          .get();

      const batch = db.batch();
      snap.docs.forEach((doc) => {
        batch.update(doc.ref, {
          status: "expired",
          updatedAt: admin.firestore.Timestamp.now(),
        });
      });
      await batch.commit();
      console.log(`Marked ${snap.size} deals as expired.`);
    });

// ============================================================
// HELPER FUNCTIONS
// ============================================================

async function searchNearbyVenues(lat, lng, radiusMeters) {
  const url = `${PLACES_API_BASE}/nearbysearch/json?location=${lat},${lng}&radius=${radiusMeters}&type=bar|restaurant|night_club&key=${PLACES_API_KEY}`;

  try {
    const response = await axios.get(url, { timeout: 10000 });
    if (!["OK", "ZERO_RESULTS"].includes(response.data.status)) {
      throw new Error(`Places API error: ${response.data.status}`);
    }

    return response.data.results.map((r) => ({
      placeId: r.place_id,
      name: r.name,
      address: r.vicinity || r.formatted_address || "",
      latitude: r.geometry.location.lat,
      longitude: r.geometry.location.lng,
      types: r.types || [],
      rating: r.rating,
      priceLevel: r.price_level,
      photoReference: r.photos?.[0]?.photo_reference,
      isPermanentlyClosed: r.business_status === "CLOSED_PERMANENTLY" || r.permanently_closed === true,
      website: null,
    }));
  } catch (err) {
    console.error("Places API error:", err.message);
    return [];
  }
}

async function getPlaceDetails(placeId) {
  const url = `${PLACES_API_BASE}/details/json?place_id=${placeId}&fields=business_status,website,formatted_phone_number&key=${PLACES_API_KEY}`;
  try {
    const response = await axios.get(url, { timeout: 10000 });
    return response.data.result;
  } catch (err) {
    return null;
  }
}

async function addVenueToDB(venue, cellIds) {
  const venueId = db.collection("venues").doc().id;
  const category = inferCategory(venue.types || []);

  await db.collection("venues").doc(venueId).set({
    id: venueId,
    placeId: venue.placeId,
    name: venue.name,
    address: venue.address,
    city: "",
    state: "",
    zipCode: "",
    latitude: venue.latitude,
    longitude: venue.longitude,
    phone: venue.phone || null,
    website: venue.website || null,
    category,
    isPermanentlyClosed: false,
    scanStatus: "pending",
    dealCount: 0,
    rating: venue.rating || null,
    priceLevel: venue.priceLevel || null,
    photoReference: venue.photoReference || null,
    searchCellIds: cellIds,
    createdAt: admin.firestore.Timestamp.now(),
    updatedAt: admin.firestore.Timestamp.now(),
  });

  return venueId;
}

async function scheduleWebsiteScan(venue) {
  await db.collection("websiteScanQueue").add({
    venueId: venue.placeId,
    url: venue.website,
    status: "queued",
    createdAt: admin.firestore.Timestamp.now(),
  });
}

function inferCategory(types) {
  if (types.includes("bar") || types.includes("night_club")) return "bar";
  if (types.includes("brewery")) return "brewery";
  if (types.includes("winery")) return "winery";
  if (types.includes("restaurant") || types.includes("food")) return "restaurant";
  return "other";
}

async function getPVAConfig() {
  const doc = await db.collection("config").doc("pva").get();
  if (!doc.exists) return getDefaultPVAConfig();
  return { ...getDefaultPVAConfig(), ...doc.data() };
}

function getDefaultPVAConfig() {
  return {
    pvaModeEnabled: true,
    cellSizeMiles: 0.5,
    cellStaleDays: 30,
    venueReverifyDays: 90,
    maxNewVenuesPerSearch: 50,
    maxPlacesApiCallsPerDay: 500,
    dailyApiCallCount: 0,
    autoScanWebsites: true,
    scanDelaySeconds: 1.0,
  };
}

// Grid helpers
const CELL_SIZE_DEGREES = 0.007246; // ~0.5 miles

function getGridCellIds(lat, lng, radiusMiles) {
  const radiusDeg = radiusMiles / 69.0;
  const cells = new Set();
  const steps = Math.ceil(radiusDeg * 2 / CELL_SIZE_DEGREES) + 1;

  for (let i = 0; i <= steps; i++) {
    for (let j = 0; j <= steps; j++) {
      const cellLat = lat - radiusDeg + i * CELL_SIZE_DEGREES;
      const cellLng = lng - radiusDeg + j * CELL_SIZE_DEGREES;
      const dist = Math.sqrt(Math.pow(cellLat - lat, 2) + Math.pow(cellLng - lng, 2)) * 69;
      if (dist <= radiusMiles) {
        cells.add(getCellId(cellLat, cellLng));
      }
    }
  }
  return [...cells];
}

function getCellId(lat, lng) {
  const latIdx = Math.floor(lat / CELL_SIZE_DEGREES);
  const lngIdx = Math.floor(lng / CELL_SIZE_DEGREES);
  return `cell_${latIdx}_${lngIdx}`;
}

function getCellCenter(cellId) {
  const parts = cellId.split("_");
  return {
    lat: (parseFloat(parts[1]) + 0.5) * CELL_SIZE_DEGREES,
    lng: (parseFloat(parts[2]) + 0.5) * CELL_SIZE_DEGREES,
  };
}

function getBoundingBox(lat, lng, radiusMiles) {
  const latDelta = radiusMiles / 69.0;
  const lngDelta = radiusMiles / (69.0 * Math.cos(lat * Math.PI / 180));
  return {
    minLat: lat - latDelta,
    maxLat: lat + latDelta,
    minLng: lng - lngDelta,
    maxLng: lng + lngDelta,
  };
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
