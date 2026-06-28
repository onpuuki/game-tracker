import * as functions from 'firebase-functions';
import { onDocumentCreated } from "firebase-functions/v2/firestore";
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
    keywords?: string;
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


export const processSyncRequest = onDocumentCreated({
    document: 'sync_requests/{requestId}',
    database: 'default',
    region: 'asia-northeast1',
    memory: '512MiB',
    timeoutSeconds: 540
}, async (event) => {
    const snapshot = event.data;
    if (!snapshot) return;
    const data = snapshot.data();
    // V2では event.params からIDを取得します
    const traceId = data.traceId || `trace-${event.params.requestId}`;

    functions.logger.info(`[${traceId}] Starting processSyncRequest with Grounded Gemini via background trigger`, { traceId });

    try {
        await snapshot.ref.update({ status: 'processing', updatedAt: admin.firestore.FieldValue.serverTimestamp() });
        const configDoc = await db.collection('settings').doc('config').get();
        const configData = configDoc?.data();
        const targetGames: ConfigItem[] = configData?.targets || [];
        const codeUrls: { gameName: string, url: string }[] = configData?.codeUrls || [];
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
    "tag": "\"ゲーム内\", \"ゲーム外\", または \"コード\"",
    "redeemCode": "シリアルコードのアルファベット/数字（ない場合はnull）",
    "startDate": "YYYY-MM-DD (時間がわかる場合は YYYY-MM-DD HH:mm:00。不明な場合はnull)",
    "endDate": "YYYY-MM-DD (時間がわかる場合は YYYY-MM-DD HH:mm:00。不明な場合はnull)",
    "eventUrl": "公式ページや大手メディアの詳細URL",
    "imageUrl": null
  }
]

【重要：期限管理の絶対ルール】本システムは期限管理アプリのデータソースです。イベントの開始日時と終了日時の正確性が命です。
・記事内の「開催期間」「スケジュール」「〜まで」などの記述を必ず探し出し、正確な日時を抽出してください。
・「アップデート後」「次期バージョンまで」等の曖昧な表記がある場合は、必ず検索結果からそのアップデート日・メンテナンス日を特定し、具体的な日付（YYYY/MM/DD）に変換して出力してください。
・時間（hh:mm）がサイトに書かれていない場合は、絶対に null にせず「YYYY-MM-DD」の日付のみを出力してください。
・「7月8日」のように年が省略されている表記は、現在日時を基準に今年の年（YYYY）を補完してください。
・安易な推測や捏造は行わず、どうしても特定できない場合のみ null としてください。

【厳格な除外条件】
終了日のない常設コンテンツ、恒常ガチャ、毎月定期開催されるコンテンツは含めないでください。
【重要】タイトルをキーにして差分更新を行うため、既存のイベントと同じものは表記揺れを起こさず、必ず前回と一言一句同じ「公式のタイトル表記」を出力してください。
URL出力時の絶対ルール：vertexaisearch.cloud.google.com のようなGoogle内部のリダイレクトURLや検索用URLは絶対に使用しないでください。必ず、イベントの公式サイトやメディアの『直接の生のURL（https://...）』を出力してください。元のURLが不明な場合は推測せず null にしてください。
検索結果に実際に存在するURLのみを使用すること。推測や捏造（ハルシネーション）は絶対に行わず、正確なURLが不明な場合は必ず null にすること。`;

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
            const currentDate = new Date().toLocaleString("ja-JP", { timeZone: "Asia/Tokyo" });
            let prompt = `【現在日時】 ${currentDate}\n\n` + promptTemplate.replace(/{{gameName}}/g, game.gameName);
            if (game.keywords && game.keywords.trim() !== '') {
                prompt += '\n\n【必須検索指定】\n以下のキーワードに関連するイベントやガチャ情報は、必ず優先的に検索・調査して出力結果に含めてください：' + game.keywords;
            }

            try {
                // Google Search Groundingを有効化して呼び出し
                const response = await generateContentWithRetry(ai, 'gemini-2.5-flash', prompt, {
                        tools: [{ googleSearch: {} }]
                    }, traceId);

                if (response.text) {
                    debugInfo.push({ stage: 1, type: 'Grounded Gemini Response', game: game.gameName, text: response.text });
                    await writeDebugLog(traceId, `Grounded Gemini Response for ${game.gameName}`, { text: response.text });

                    // パース処理（Markdownの除去およびJSON配列の抽出）
                    let extractedEvents: any[] = [];
                    const firstBracket = response.text.indexOf('[');
                    const lastBracket = response.text.lastIndexOf(']');
                    if (firstBracket !== -1 && lastBracket !== -1 && firstBracket < lastBracket) {
                        const jsonStr = response.text.substring(firstBracket, lastBracket + 1);
                        extractedEvents = JSON.parse(jsonStr);
                    } else {
                        throw new Error("JSON array not found in response.");
                    }

                    // 抽出できた場合はFirestoreへ同期
                    if (Array.isArray(extractedEvents) && extractedEvents.length > 0) {
                        const eventsCollection = db.collection(`games/${game.gameName}/events`);
                        const currentEventsSnapshot = await eventsCollection.get();
                        const currentEventsMap = new Map();
                        currentEventsSnapshot.forEach(doc => currentEventsMap.set(doc.data().title, { docId: doc.id, data: doc.data() }));

                        const newEventTitles = new Set();
                        let batch = db.batch();
                        let batchCount = 0;

                        let addedCount = 0;
                        let updatedCount = 0;
                        let deletedCount = 0;
                        let unchangedCount = 0;

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

                            if (event.tag === 'コード' && event.redeemCode) {
                                const matchingConfig = codeUrls.find(c => c.gameName === game.gameName);
                                if (matchingConfig && matchingConfig.url) {
                                    event.eventUrl = matchingConfig.url.replace('(コード)', event.redeemCode);
                                }
                            }

                            if (currentEventsMap.has(event.title)) {
                                const existing = currentEventsMap.get(event.title);
                                const existingData = existing.data;

                                // Compare specific fields to detect changes
                                const hasChanges = existingData.startDate !== event.startDate ||
                                                   existingData.endDate !== event.endDate ||
                                                   existingData.summary !== event.summary ||
                                                   existingData.eventUrl !== event.eventUrl ||
                                                   existingData.imageUrl !== event.imageUrl ||
                                                   existingData.tag !== event.tag ||
                                                   existingData.redeemCode !== event.redeemCode;

                                if (hasChanges) {
                                    const docRef = eventsCollection.doc(existing.docId);
                                    batch.set(docRef, { ...event, gameName: game.gameName, updatedAt: admin.firestore.FieldValue.serverTimestamp() }, { merge: true });
                                    batchCount++;
                                    updatedCount++;
                                    await commitBatchIfNeeded();
                                } else {
                                    unchangedCount++;
                                }
                            } else {
                                const docRef = eventsCollection.doc();
                                batch.set(docRef, { ...event, gameName: game.gameName, createdAt: admin.firestore.FieldValue.serverTimestamp(), updatedAt: admin.firestore.FieldValue.serverTimestamp() });
                                batchCount++;
                                addedCount++;
                                await commitBatchIfNeeded();
                            }
                        }

                        // 不要になった過去のイベントを削除
                        for (const [title, existing] of currentEventsMap.entries()) {
                            if (!newEventTitles.has(title)) {
                                batch.delete(eventsCollection.doc(existing.docId));
                                batchCount++;
                                deletedCount++;
                                await commitBatchIfNeeded();
                            }
                        }

                        if (batchCount > 0) {
                             await batch.commit();
                        }

                        const debugIndex = debugInfo.findIndex(info => info.stage === 1 && info.game === game.gameName && info.type === 'Grounded Gemini Response');
                        if (debugIndex !== -1) {
                            debugInfo[debugIndex] = {
                                ...debugInfo[debugIndex],
                                added: addedCount,
                                updated: updatedCount,
                                deleted: deletedCount,
                                unchanged: unchangedCount
                            };
                        }

                        functions.logger.info(`[${traceId}] Successfully synced ${extractedEvents.length} events for ${game.gameName} (Added: ${addedCount}, Updated: ${updatedCount}, Deleted: ${deletedCount}, Unchanged: ${unchangedCount})`);
                        await writeDebugLog(traceId, `Successfully synced ${extractedEvents.length} events for ${game.gameName} (Added: ${addedCount}, Updated: ${updatedCount}, Deleted: ${deletedCount}, Unchanged: ${unchangedCount})`);
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
        await snapshot.ref.update({ status: 'completed', updatedAt: admin.firestore.FieldValue.serverTimestamp(), debugInfo });
        await writeDebugLog(traceId, 'processSyncRequest process completed successfully.');
        return { success: true, message: 'Sync completed via Grounded Gemini.', debugInfo };
    } catch (error) {
        const errorMessage = error instanceof Error ? error.message : String(error);
        await snapshot.ref.update({ status: 'error', error: errorMessage, updatedAt: admin.firestore.FieldValue.serverTimestamp() });
        functions.logger.error(`[${traceId}] Unhandled catastrophic error: ${error instanceof Error ? error.stack : String(error)}`);
        throw error;
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
