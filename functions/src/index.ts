import * as functions from 'firebase-functions';
import * as admin from 'firebase-admin';
import { getFirestore } from 'firebase-admin/firestore';
import { GoogleGenAI } from '@google/genai';
import axios from 'axios';
import * as cheerio from 'cheerio';

admin.initializeApp();

const db = getFirestore(admin.app(), 'default');

interface ConfigItem {
  gameName: string;
  url: string;
}

export const syncEvents = functions.runWith({ memory: '1GB', timeoutSeconds: 300 }).https.onCall(async (data, context) => {
  const traceId = data.traceId || 'unknown-trace-id';

  functions.logger.info(`[${traceId}] Starting syncEvents`, { traceId });

  try {
    // 1. Fetch Configuration
    functions.logger.info(`[${traceId}] Before fetching config`, { traceId });
    const configDoc = await db.collection('settings').doc('config').get();
    functions.logger.info(`[${traceId}] After fetching config`, { traceId });
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

    const geminiApiKey = configData?.geminiApiKey;
    if (!geminiApiKey) {
        functions.logger.error(`[${traceId}] Gemini API Key not found in configuration.`, { traceId });
        return { success: false, message: 'Gemini API Key missing.' };
    }
    functions.logger.info(`[${traceId}] Before instantiating GoogleGenAI`, { traceId });
    const ai = new GoogleGenAI({ apiKey: geminiApiKey.trim() });
    functions.logger.info(`[${traceId}] After instantiating GoogleGenAI`, { traceId });

    const debugInfo: any[] = [];

    for (const game of targetGames) {
      functions.logger.info(`[${traceId}] Starting for loop over games`, { traceId });
      functions.logger.info(`[${traceId}] Processing game: ${game.gameName} - ${game.url}`, { traceId });

      let htmlContent = '';
      try {
        functions.logger.info(`[${traceId}] Before fetch call for ${game.gameName}`, { traceId });

        const response = await axios.get(game.url, {
          headers: {
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
          },
          timeout: 10000 // 10秒タイムアウト
        });

        functions.logger.info(`[${traceId}] After fetch call for ${game.gameName}`, { traceId });
        htmlContent = response.data;
        debugInfo.push({
          game: game.gameName,
          length: htmlContent.length,
          snippet: htmlContent.substring(0, 200)
        });
      } catch (err) {
        functions.logger.error(`[${traceId}] Failed to fetch HTML for ${game.gameName}`, { error: err, traceId });
        continue;
      }

      // 3. Extract via Gemini
          functions.logger.info(`[${traceId}] Requesting Gemini API for ${game.gameName}`, { traceId });

          let extractedEvents: any[] = [];
          try {
              // HTMLから不要な要素を除去し、テキストのみを抽出
              // 1. HTMLを読み込み
              const $ = cheerio.load(htmlContent);

              // 1.5 <a>タグからリンクを抽出してテキストに埋め込む
              $('a').each((_, element) => {
                  const href = $(element).attr('href');
                  if (href && !href.startsWith('javascript:') && !href.startsWith('#')) {
                      try {
                          const absoluteUrl = new URL(href, game.url).href;
                          const currentText = $(element).text();
                          if (currentText.trim()) {
                              $(element).append(` [詳細URL: ${absoluteUrl}] `);
                          }
                      } catch (e) {
                          // Ignore invalid URLs
                      }
                  }
              });

              // 2. 露骨な不要エリア（サイドバー、メニュー、ヘッダー等）を根こそぎ削除
              $('script, style, noscript, iframe, header, footer, nav, aside, .sidebar, .menu, #side').remove();

              // 3. GameWith等のメインコンテンツ領域を優先して取得
              $('br').replaceWith('\n');
              $('td, th, div, p, li, h1, h2, h3, h4').append('\n');
              let mainContentText = $('article').text();
              if (!mainContentText) mainContentText = $('main').text();
              if (!mainContentText) mainContentText = $('.kw-article').text();
              if (!mainContentText) mainContentText = $('body').text();

              const cleanText = mainContentText.replace(/[ \t]+/g, ' ').replace(/\n+/g, '\n').trim();

              const prompt = `
このテキストは『${game.gameName}』の攻略サイトのメインコンテンツです。
テキスト内から現在開催中のイベント情報を抽出し、必ずJSONの配列形式のみを出力してください。
各イベントは以下のプロパティを持つオブジェクトとしてください。
- title: イベントのタイトル
- period: 開催期間（例: "2024/01/01 ~ 2024/01/15", "x月x日メンテ後〜" など、テキストの記載通りに抽出）
- endDate: イベントの終了日（YYYY-MM-DD形式。テキストに「月日」しか書かれていない場合は、2026年の出来事として年を補完してください。終了日が不明な場合はnull）
- imageUrl: イベントの画像URL (取得できなければnull)
- eventUrl: テキスト内に付与された [詳細URL: https://...] の情報からURLを確実に抽出してください。見つからない場合はnull。

【抽出除外の厳格な条件】
以下のいずれかに該当するイベント・コンテンツは、抽出対象から絶対に除外してください。
1. 終了日が設定されていない常設コンテンツ
2. 常時開催のイベント
3. 毎月1日〜月末など、毎月定期的に開催されるイベント

【重要な追加条件】
これから開催される『開催予定（未来）』のイベントは絶対に除外せず、必ず抽出対象に含めてください。

テキスト:
${cleanText.substring(0, 20000)}
`;

              const response = await ai.models.generateContent({
                  model: 'gemini-2.5-flash',
                  contents: prompt,
                  config: {
                      responseMimeType: 'application/json'
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
                      batch.set(docRef, { ...event, gameName: game.gameName, updatedAt: admin.firestore.FieldValue.serverTimestamp() }, { merge: true });
                  } else {
                      // Add new
                      const docRef = eventsCollection.doc();
                      batch.set(docRef, { ...event, gameName: game.gameName, createdAt: admin.firestore.FieldValue.serverTimestamp(), updatedAt: admin.firestore.FieldValue.serverTimestamp() });
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

    functions.logger.info(`[${traceId}] syncEvents completed successfully`, { traceId });
    return { success: true, message: 'Sync completed.', debugInfo };

  } catch (error) {
    functions.logger.error(`[${traceId}] Unhandled error in syncEvents: ${error instanceof Error ? error.stack : String(error)}`, { traceId });
    throw new functions.https.HttpsError('internal', 'Internal error occurred during sync.');
  }
});

export const clearAllEvents = functions.runWith({ memory: '256MB', timeoutSeconds: 300 }).https.onCall(async (data, context) => {
    try {
        const snapshot = await db.collectionGroup('events').get();
        if (snapshot.empty) {
            return { success: true, deletedCount: 0 };
        }

        const batches: Promise<any>[] = [];
        let currentBatch = db.batch();
        let count = 0;

        snapshot.docs.forEach((doc, index) => {
            currentBatch.delete(doc.ref);
            count++;
            if (count === 500 || index === snapshot.docs.length - 1) {
                batches.push(currentBatch.commit());
                currentBatch = db.batch();
                count = 0;
            }
        });

        await Promise.all(batches);
        functions.logger.info(`Successfully deleted ${snapshot.size} events.`);
        return { success: true, deletedCount: snapshot.size };
    } catch (error) {
        functions.logger.error('Error clearing events:', error instanceof Error ? error.stack : String(error));
        throw new functions.https.HttpsError('internal', 'Unable to clear events', error);
    }
});
// force cold start
