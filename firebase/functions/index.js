/**
 * Somewhere - Firebase Cloud Functions
 * Happy Hour Deal Discovery Platform
 */

const functions = require("firebase-functions");
const admin = require("firebase-admin");
const axios = require("axios");
const cheerio = require("cheerio");

admin.initializeApp();
const db = admin.firestore();

// ============================================================
// CONSTANTS
// ============================================================
const PLACES_API_KEY = functions.config().places?.api_key || process.env.PLACES_API_KEY;
const OPENAI_API_KEY = functions.config().openai?.api_key || process.env.OPENAI_API_KEY;
const PLACES_API_BASE = "https://maps.googleapis.com/maps/api/place";

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
 * Called by the mobile app when a user provides a URL.
 */
exports.scanWebsite = functions
    .runWith({ timeoutSeconds: 60, memory: "256MB" })
    .https.onCall(async (data, context) => {
      if (!context.auth) {
        throw new functions.https.HttpsError("unauthenticated", "Must be authenticated.");
      }

      const { url, venueId, venueName } = data;
      if (!url) {
        throw new functions.https.HttpsError("invalid-argument", "URL required.");
      }

      try {
        const result = await scrapeWebsiteForDeals(url, venueName || "");
        return result;
      } catch (err) {
        console.error("Website scan error:", err);
        throw new functions.https.HttpsError("internal", `Failed to scan website: ${err.message}`);
      }
    });

async function scrapeWebsiteForDeals(url, venueName) {
  const normalizedUrl = url.startsWith("http") ? url : `https://${url}`;

  const response = await axios.get(normalizedUrl, {
    timeout: 20000,
    headers: {
      "User-Agent": "Mozilla/5.0 (compatible; SomewhereBot/1.0; +https://hhsomewhere.com/bot)",
    },
    maxRedirects: 5,
  });

  const html = response.data;
  const $ = cheerio.load(html);

  // Remove non-content elements
  $("script, style, nav, footer, header, iframe").remove();

  // Get text content
  const text = $("body").text().replace(/\s+/g, " ").trim();

  // Use OpenAI if available for better extraction
  if (OPENAI_API_KEY) {
    return await extractDealsWithAI(text, venueName, url);
  }

  // Fallback: regex-based extraction
  return extractDealsWithRegex(text, url);
}

async function extractDealsWithAI(text, venueName, sourceUrl) {
  const { OpenAI } = require("openai");
  const openai = new OpenAI({ apiKey: OPENAI_API_KEY });

  const prompt = `You are extracting happy hour deals from restaurant/bar website text.

Venue: ${venueName || "Unknown"}
Website text (truncated to 3000 chars):
${text.substring(0, 3000)}

Extract all happy hour deals. For each deal return JSON with:
- title: short deal name
- description: full description
- category: "drinks" | "food" | "activity"
- days: array of "monday"|"tuesday"|"wednesday"|"thursday"|"friday"|"saturday"|"sunday"
- startTime: "HH:mm" 24-hour format
- endTime: "HH:mm" 24-hour format

Return JSON array. Return [] if no happy hour deals found.`;

  try {
    const completion = await openai.chat.completions.create({
      model: "gpt-3.5-turbo",
      messages: [{ role: "user", content: prompt }],
      response_format: { type: "json_object" },
      temperature: 0.1,
    });

    const content = completion.choices[0].message.content;
    const parsed = JSON.parse(content);
    const deals = parsed.deals || parsed || [];

    return {
      success: true,
      url: sourceUrl,
      extractedDeals: Array.isArray(deals) ? deals : [],
      extractionMethod: "ai",
    };
  } catch (err) {
    console.error("OpenAI extraction error:", err);
    return extractDealsWithRegex(text, sourceUrl);
  }
}

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
