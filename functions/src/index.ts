import * as functions from 'firebase-functions';
import * as admin from 'firebase-admin';
import { getFirestore } from 'firebase-admin/firestore';
import { GoogleGenAI } from '@google/genai';

admin.initializeApp();
const db = getFirestore(admin.app(), 'default');

async function writeDebugLog(traceId: string, message: string, detailObj: any = ''): Promise<void> {
    try {
        const detailStr = typeof detailObj === 'string' ? detailObj : JSON.stringify(detailObj, null, 2);
        await db.collection('debug_logs').add({
            traceId,
            timestamp: admin.firestore.FieldValue.serverTimestamp(),
            message,
            detail: detailStr,
        });
    } catch (e: any) {
        functions.logger.error(`[${traceId}] Failed to write debug log to Firestore`, { error: e.message, message });
    }
}

// ユーティリティ: 待機処理（バックオフ用）
const sleep = (ms: number) => new Promise(resolve => setTimeout(resolve, ms));

interface ConfigItem {
    gameName: string;
    url?: string; // スクレイピングはしないが互換性のため残す
}

async function generateContentWithRetry(ai: GoogleGenAI, model: string, contents: string, config: any, traceId: string, maxRetries = 3): Promise<any> {
    let attempt = 0;
    const baseDelay = 5000; // 初期待機時間 (5秒)

    while (attempt < maxRetries) {
        try {
            return await ai.models.generateContent({
                model: model,
                contents: contents,
                config: config
            });
        } catch (err: any) {
            attempt++;
            const isLastAttempt = attempt >= maxRetries;

            functions.logger.warn(`[${traceId}] Gemini API failed (Attempt ${attempt}/${maxRetries}). Error: ${err.message}`);

            if (isLastAttempt || (err.status && err.status !== 503 && err.status !== 429)) {
                // 最終試行、または 503/429 以外（再試行しても無駄なエラー）の場合は諦める
                throw err;
            }

            // 503 または 429 の場合はバックオフで待機
            const exponentialDelay = baseDelay * Math.pow(2, attempt - 1);
            await sleep(exponentialDelay);
        }
    }
}


export const syncEvents = functions.runWith({ memory: '512MB', timeoutSeconds: 300 }).https.onCall(async (data, context) => {
    const traceId = data.traceId || `trace-${Date.now()}`;
    functions.logger.info(`[${traceId}] Starting syncEvents with Grounded Gemini`, { traceId });

    try {
        const configDoc = await db.collection('settings').doc('config').get();
        const configData = configDoc?.data();
        const targetGames: ConfigItem[] = configData?.targets || [];
        const geminiApiKey = configData?.geminiApiKey;

        // Firestoreからプロンプトテンプレートを取得（なければデフォルトを使用）
        const defaultPromptTemplate = `あなたは最新のゲーム情報を提供する専門AIです。
Google検索機能を利用して、ゲーム『{{gameName}}』で【現在開催中】および【近日開催予定】の期間限定イベントやガチャ、コラボ情報を最新のウェブ検索結果から調査してください。

【出力要件】
調査結果を以下のJSON配列形式で出力してください。Markdown装飾(\`\`\`json等)は不要です。
[
  {
    "title": "イベントの正式名称",
    "summary": "イベントの概要や報酬内容",
    "period": "開催期間（例: 2024/01/01 ~ 2024/01/15）",
    "endDate": "YYYY-MM-DD形式（不明な場合はnull）",
    "eventUrl": "公式ページや大手メディアの詳細URL",
    "imageUrl": null
  }
]

【厳格な除外条件】
終了日のない常設コンテンツ、恒常ガチャ、毎月定期開催されるコンテンツは含めないでください。`;

        const promptTemplate = configData?.promptTemplate || defaultPromptTemplate;

        if (!geminiApiKey || targetGames.length === 0) {
            await writeDebugLog(traceId, 'Sync failed: Invalid config');
            return { success: false, message: 'Invalid config' };
        }

        const ai = new GoogleGenAI({ apiKey: geminiApiKey.trim() });
        const debugInfo: any[] = [];

        for (const game of targetGames) {
            functions.logger.info(`[${traceId}] Requesting Gemini with Search for: ${game.gameName}`);
            await writeDebugLog(traceId, `Requesting Gemini with Search for: ${game.gameName}`);

            // テンプレートのプレースホルダーを実際のゲーム名に置換
            const prompt = promptTemplate.replace(/{{gameName}}/g, game.gameName);

            try {
                // Google Search Groundingを有効化して呼び出し
                const response = await generateContentWithRetry(ai, 'gemini-2.5-flash', prompt, {
                        tools: [{ googleSearch: {} }]
                    }, traceId);

                if (response.text) {
                    debugInfo.push({ stage: 1, type: 'Grounded Gemini Response', game: game.gameName, text: response.text });
                    await writeDebugLog(traceId, `Grounded Gemini Response for ${game.gameName}`, { text: response.text });

                    // パース処理（Markdownの除去）
                    let cleanedText = response.text.replace(/```json/gi, '').replace(/```/g, '').trim();
                    const extractedEvents = JSON.parse(cleanedText);

                    // 抽出できた場合はFirestoreへ同期
                    if (Array.isArray(extractedEvents) && extractedEvents.length > 0) {
                        const eventsCollection = db.collection(`games/${game.gameName}/events`);
                        const currentEventsSnapshot = await eventsCollection.get();
                        const currentEventsMap = new Map();
                        currentEventsSnapshot.forEach(doc => currentEventsMap.set(doc.data().title, doc.id));

                        const newEventTitles = new Set();
                        let batch = db.batch();
                        let batchCount = 0;

                        const commitBatchIfNeeded = async () => {
                            if (batchCount >= 450) {
                                await batch.commit();
                                batch = db.batch();
                                batchCount = 0;
                            }
                        };


                        for (const event of extractedEvents) {
                            if (!event.title) continue;
                            newEventTitles.add(event.title);

                            if (currentEventsMap.has(event.title)) {
                                const docRef = eventsCollection.doc(currentEventsMap.get(event.title));
                                batch.set(docRef, { ...event, gameName: game.gameName, updatedAt: admin.firestore.FieldValue.serverTimestamp() }, { merge: true });
                            } else {
                                const docRef = eventsCollection.doc();
                                batch.set(docRef, { ...event, gameName: game.gameName, createdAt: admin.firestore.FieldValue.serverTimestamp(), updatedAt: admin.firestore.FieldValue.serverTimestamp() });
                            }
                            batchCount++;
                            await commitBatchIfNeeded();
                        }

                        // 不要になった過去のイベントを削除
                        for (const [title, docId] of currentEventsMap.entries()) {
                            if (!newEventTitles.has(title)) {
                                batch.delete(eventsCollection.doc(docId));
                                batchCount++;
                                await commitBatchIfNeeded();
                            }
                        }
                        if (batchCount > 0) {
                             await batch.commit();
                        }
                        functions.logger.info(`[${traceId}] Successfully synced ${extractedEvents.length} events for ${game.gameName}`);
                        await writeDebugLog(traceId, `Successfully synced ${extractedEvents.length} events for ${game.gameName}`);
                    } else {
                         functions.logger.info(`[${traceId}] No valid events extracted for ${game.gameName}`);
                         await writeDebugLog(traceId, `No valid events extracted for ${game.gameName}`);
                    }
                }
            } catch (err: any) {
                functions.logger.error(`[${traceId}] Gemini API failed for ${game.gameName}`, { error: err instanceof Error ? err.stack : String(err) });
                debugInfo.push({ stage: 'Error', game: game.gameName, error: err instanceof Error ? err.stack : String(err) });
                await writeDebugLog(traceId, `Gemini API failed for ${game.gameName}`, { error: err instanceof Error ? err.stack : String(err) });
            }
        }
        await writeDebugLog(traceId, 'syncEvents process completed successfully.');
        return { success: true, message: 'Sync completed via Grounded Gemini.', debugInfo };
    } catch (error) {
        functions.logger.error(`[${traceId}] Unhandled catastrophic error: ${error instanceof Error ? error.stack : String(error)}`);
        throw new functions.https.HttpsError('internal', 'Internal error occurred.');
    }
});

// イベントの全クリア処理 (バッチ上限対応済み)
export const clearAllEvents = functions.runWith({ memory: '256MB', timeoutSeconds: 300 }).https.onCall(async (data, context) => {
    try {
        const snapshot = await db.collectionGroup('events').get();
        if (snapshot.empty) return { success: true, deletedCount: 0 };

        const batches: Promise<any>[] = [];
        let currentBatch = db.batch();
        let count = 0;

        snapshot.docs.forEach((doc, index) => {
            currentBatch.delete(doc.ref);
            count++;
            // 制限の500に対して安全マージンを取り450でコミットを実行
            if (count === 450 || index === snapshot.docs.length - 1) {
                batches.push(currentBatch.commit());
                currentBatch = db.batch();
                count = 0;
            }
        });

        await Promise.all(batches);
        functions.logger.info(`Successfully deleted ${snapshot.size} events from all games.`);
        return { success: true, deletedCount: snapshot.size };
    } catch (error) {
        functions.logger.error('Error clearing events from Firestore:', error instanceof Error ? error.stack : String(error));
        throw new functions.https.HttpsError('internal', 'Unable to clear events due to internal error', error);
    }
});
