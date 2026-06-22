import * as functions from 'firebase-functions';
import * as admin from 'firebase-admin';
import puppeteer from 'puppeteer';
import { GoogleGenAI, Type, Schema } from '@google/genai';

admin.initializeApp();

const db = admin.firestore();

// Initialize Gemini API Client
// Note: Requires GEMINI_API_KEY environment variable set in Cloud Functions
const ai = new GoogleGenAI({});

interface ConfigItem {
  gameName: string;
  url: string;
}

export const syncEvents = functions.runWith({ memory: '1GB' }).https.onCall(async (data, context) => {
  const traceId = data.traceId || 'unknown-trace-id';

  functions.logger.info(`[${traceId}] Starting syncEvents`, { traceId });

  try {
    // 1. Fetch Configuration
    const configDoc = await db.collection('settings').doc('config').get();
    if (!configDoc.exists) {
        functions.logger.warn(`[${traceId}] Configuration settings/config not found.`, { traceId });
        return { success: false, message: 'Configuration not found.' };
    }

    const configData = configDoc.data();
    const targetGames: ConfigItem[] = configData?.targets || [];

    if (targetGames.length === 0) {
        functions.logger.info(`[${traceId}] No games configured.`, { traceId });
        return { success: true, message: 'No games configured to sync.' };
    }

    // 2. Launch Puppeteer
    functions.logger.info(`[${traceId}] Launching Puppeteer`, { traceId });
    const browser = await puppeteer.launch({
      headless: true,
      args: ['--no-sandbox', '--disable-setuid-sandbox'],
    });

    try {
        for (const game of targetGames) {
          functions.logger.info(`[${traceId}] Processing game: ${game.gameName} - ${game.url}`, { traceId });

          let htmlContent = '';
          try {
            const page = await browser.newPage();
            await page.goto(game.url, { waitUntil: 'networkidle2', timeout: 30000 });
            htmlContent = await page.content();
            await page.close();
          } catch (err) {
            functions.logger.error(`[${traceId}] Failed to scrape HTML for ${game.gameName}`, { error: err, traceId });
            continue;
          }

          // 3. Extract via Gemini
          functions.logger.info(`[${traceId}] Requesting Gemini API for ${game.gameName}`, { traceId });

          let extractedEvents: any[] = [];
          try {
              const prompt = `
              このHTMLは『${game.gameName}』のサイトです。
              HTML内からイベント情報を抽出し、JSONの配列形式で返してください。
              各イベントは以下のプロパティを持つオブジェクトとしてください。
              - title: イベントのタイトル
              - period: イベントの期間
              - imageUrl: イベントの画像URL (取得できなければnull)

              HTML:
              ${htmlContent.substring(0, 30000)} // Truncate to avoid exceeding token limits
              `;

              const response = await ai.models.generateContent({
                  model: 'gemini-1.5-pro',
                  contents: prompt,
                  config: {
                      responseMimeType: 'application/json',
                      responseSchema: {
                          type: Type.ARRAY,
                          items: {
                              type: Type.OBJECT,
                              properties: {
                                  title: { type: Type.STRING },
                                  period: { type: Type.STRING },
                                  imageUrl: { type: Type.STRING, nullable: true },
                              },
                              required: ['title', 'period']
                          }
                      } as Schema
                  }
              });

              if (response.text) {
                  extractedEvents = JSON.parse(response.text);
                  functions.logger.info(`[${traceId}] Extracted ${extractedEvents.length} events for ${game.gameName}`, { traceId });
              } else {
                 functions.logger.warn(`[${traceId}] No text returned from Gemini for ${game.gameName}`, { traceId });
              }
          } catch (err) {
              functions.logger.error(`[${traceId}] Failed to extract data from Gemini for ${game.gameName}`, { error: err, traceId });
              continue;
          }

          // 4. Sync to Firestore (Mirroring)
          try {
              const eventsCollection = db.collection(`games/${game.gameName}/events`);

              // Get current events
              const currentEventsSnapshot = await eventsCollection.get();
              const currentEventsMap = new Map();
              currentEventsSnapshot.forEach(doc => {
                  // We'll use the title as the key for simplicity, or ideally a hash of the content
                  currentEventsMap.set(doc.data().title, doc.id);
              });

              const newEventTitles = new Set();

              // Add or Update new events
              const batch = db.batch();
              let batchCount = 0;
              for (const event of extractedEvents) {
                  newEventTitles.add(event.title);

                  if (currentEventsMap.has(event.title)) {
                      // Update existing
                      const docRef = eventsCollection.doc(currentEventsMap.get(event.title));
                      batch.set(docRef, { ...event, updatedAt: admin.firestore.FieldValue.serverTimestamp() }, { merge: true });
                  } else {
                      // Add new
                      const docRef = eventsCollection.doc();
                      batch.set(docRef, { ...event, createdAt: admin.firestore.FieldValue.serverTimestamp(), updatedAt: admin.firestore.FieldValue.serverTimestamp() });
                  }
                  batchCount++;
              }

              // Delete obsolete events
              for (const [title, docId] of currentEventsMap.entries()) {
                  if (!newEventTitles.has(title)) {
                       functions.logger.info(`[${traceId}] Deleting obsolete event: ${title}`, { traceId });
                       const docRef = eventsCollection.doc(docId);
                       batch.delete(docRef);
                       batchCount++;
                  }
              }

              if (batchCount > 0) {
                 await batch.commit();
                 functions.logger.info(`[${traceId}] Successfully synced events for ${game.gameName}`, { traceId });
              }

          } catch (err) {
              functions.logger.error(`[${traceId}] Failed to sync to Firestore for ${game.gameName}`, { error: err, traceId });
          }

        }
    } finally {
        await browser.close();
    }

    functions.logger.info(`[${traceId}] syncEvents completed successfully`, { traceId });
    return { success: true, message: 'Sync completed.' };

  } catch (error) {
    functions.logger.error(`[${traceId}] Unhandled error in syncEvents`, { error, traceId });
    throw new functions.https.HttpsError('internal', 'Internal error occurred during sync.');
  }
});
