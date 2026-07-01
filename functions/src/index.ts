import * as functions from 'firebase-functions';
import { onDocumentCreated, onDocumentWritten } from "firebase-functions/v2/firestore";
import * as admin from 'firebase-admin';
import { getFirestore } from 'firebase-admin/firestore';
import { CloudSchedulerClient } from '@google-cloud/scheduler';

import { GoogleGenAI } from '@google/genai';
import * as crypto from 'crypto';
import { google } from 'googleapis';

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
    const baseDelay = 30000; // APIの長いRetryInfo（約40秒）をカバーするため

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
        const defaultPromptTemplate = `あなたはゲームの公式最新情報を正確に抽出する専門AIです。非公式リークや架空のデータは絶対に除外してください。
Google検索機能を利用して、ゲーム『{{gameName}}』で【現在開催中】および【近日開催予定】の期間限定イベントやガチャ、コラボ情報を最新のウェブ検索結果から調査してください。

【出力要件】
調査結果を以下のJSON配列形式で出力してください。Markdown装飾(\`\`\`json等)は不要です。
[
  {
    "existingId": "提供された既存イベントと一致する場合はそのidを文字列で入力。完全に新規の場合はnull",
    "title": "イベントの正式名称",
    "summary": "イベントの概要や報酬内容",
    "tag": "\"ゲーム内\", \"ゲーム外\", または \"コード\"",
    "redeemCode": "シリアルコードのアルファベット/数字（ない場合はnull）",
    "startDate": "YYYY-MM-DD (時間がわかる場合は YYYY-MM-DD HH:mm:00。不明な場合はnull)",
    "endDate": "YYYY-MM-DD (時間がわかる場合は YYYY-MM-DD HH:mm:00。不明な場合はnull)",
    "eventUrl": "公式ページや大手メディアの詳細URL（完全に新規のイベントの場合は必須。不明またはexistingIdがある場合はnull可）",
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
【重要：名寄せの絶対ルール】
検索して見つけたイベントが、提供された『現在のデータベース状況（既存イベント）』にあるイベントと実質的に同じ（参照先URLが違うだけなど）である場合、必ずその既存イベントの \`id\` (ドキュメントID) を \`existingId\` フィールドに入れて返してください。既存イベントと同じものは表記揺れを起こさず、必ず前回と一言一句同じ「公式のタイトル表記」を出力してください。完全に新しいイベントの場合は \`existingId\` を空（null）にし、必ず情報のソース元の \`eventUrl\` を含めてください。
URL出力時の絶対ルール：vertexaisearch.cloud.google.com のようなGoogle内部のリダイレクトURLや検索用URLは絶対に使用しないでください。必ず、イベントの公式サイトやメディアの『直接の生のURL（https://...）』を出力してください。元のURLが不明な場合は推測せず null にしてください。
検索結果に実際に存在するURLのみを使用すること。推測や捏造（ハルシネーション）は絶対に行わず、正確なURLが不明な場合は必ず null にすること。`;

        const promptTemplate = configData?.promptTemplate || defaultPromptTemplate;

        if (!geminiApiKey || targetGames.length === 0) {
            await writeDebugLog(traceId, 'Sync failed: Invalid config');
            return { success: false, message: 'Invalid config' };
        }

        const ai = new GoogleGenAI({ apiKey: geminiApiKey.trim() });
        const debugInfo: any[] = [];
        let totalTokens = 0;

        for (const game of targetGames) {
            functions.logger.info(`[${traceId}] Requesting Gemini with Search for: ${game.gameName}`);
            await writeDebugLog(traceId, `Requesting Gemini with Search for: ${game.gameName}`);

            // Fetch existing events from Firestore
            const eventsCollection = db.collection(`games/${game.gameName}/events`);
            const currentEventsSnapshot = await eventsCollection.get();
            const existingEventsForPrompt = currentEventsSnapshot.docs.map(doc => {
                const data = doc.data();
                return {
                    id: doc.id,
                    title: data.title,
                    endDate: data.endDate
                };
            });
            const existingEventsJsonStr = JSON.stringify(existingEventsForPrompt, null, 2);

            // テンプレートのプレースホルダーを実際のゲーム名に置換
            const currentDate = new Date().toLocaleString("ja-JP", { timeZone: "Asia/Tokyo" });
            let prompt = `【現在日時】 ${currentDate}\n\n` + promptTemplate.replace(/{{gameName}}/g, game.gameName);
            prompt += `\n\n【現在のデータベース状況（既存イベント）】\n${existingEventsJsonStr}\n`;

            if (game.keywords && game.keywords.trim() !== '') {
                prompt += '\n\n【必須検索指定】\n以下のキーワードに関連するイベントやガチャ情報は、必ず優先的に検索・調査して出力結果に含めてください：' + game.keywords;
            }

            try {
                // Google Search Groundingを有効化して呼び出し
                const response = await generateContentWithRetry(ai, 'gemini-2.5-flash', prompt, {
                        tools: [{ googleSearch: {} }]
                    }, traceId);

                if (response.usageMetadata?.totalTokenCount) {
                    totalTokens += response.usageMetadata.totalTokenCount;
                }

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
                        // eventsCollection と currentEventsSnapshot は上で定義済みのため再利用
                        const currentEventsMap = new Map();
                        currentEventsSnapshot.forEach(doc => currentEventsMap.set(doc.data().title, { docId: doc.id, data: doc.data() }));
                        const currentEventsList = Array.from(currentEventsMap.values());
                        const matchedDocIds = new Set<string>();

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

                            if (event.tag === 'コード' && event.redeemCode) {
                                // ギフトコードのバリデーション: 英数字とハイフン、アンダースコアのみ許可
                                if (!/^[a-zA-Z0-9_-]+$/.test(event.redeemCode)) {
                                    functions.logger.warn(`[${traceId}] Invalid redeemCode detected and skipped: ${event.redeemCode}`);
                                    continue;
                                }

                                const matchingConfig = codeUrls.find(c => c.gameName === game.gameName);
                                if (matchingConfig && matchingConfig.url) {
                                    event.eventUrl = matchingConfig.url.replace('(コード)', event.redeemCode);
                                }
                            }

                            if (event.existingId) {
                                // 既存イベントの場合
                                const existingEvent = currentEventsList.find(e => e.docId === event.existingId);
                                if (existingEvent) {
                                    matchedDocIds.add(existingEvent.docId);
                                    const existingData = existingEvent.data;

                                    if (existingData.isLocked === true) {
                                        unchangedCount++;
                                        continue;
                                    }

                                    const hasChanges = existingData.endDate !== event.endDate ||
                                                       existingData.redeemCode !== event.redeemCode ||
                                                       existingData.summary !== event.summary;

                                    if (hasChanges) {
                                        const docRef = eventsCollection.doc(existingEvent.docId);
                                        const eventDataToSave = { ...event };
                                        delete eventDataToSave.existingId; // Firestoreには保存しない
                                        batch.set(docRef, { ...eventDataToSave, gameName: game.gameName, updatedAt: admin.firestore.FieldValue.serverTimestamp() }, { merge: true });
                                        batchCount++;
                                        updatedCount++;
                                        await commitBatchIfNeeded();
                                    } else {
                                        unchangedCount++;
                                    }
                                } else {
                                    functions.logger.warn(`[${traceId}] existingId ${event.existingId} provided but not found in DB.`);
                                }
                            } else {
                                // 新規イベントの場合
                                let docId;
                                if (event.tag === 'コード' && event.redeemCode) {
                                    const normalizedCode = event.redeemCode.replace(/\s+/g, '').toUpperCase();
                                    docId = `code_${normalizedCode}`;
                                } else if (event.eventUrl) {
                                    // URLをハッシュ化してIDを固定
                                    docId = crypto.createHash('md5').update(event.eventUrl).digest('hex');
                                }

                                if (docId) {
                                    const docRef = eventsCollection.doc(docId);
                                    const eventDataToSave = { ...event };
                                    delete eventDataToSave.existingId; // Firestoreには保存しない
                                    batch.set(docRef, { ...eventDataToSave, gameName: game.gameName, createdAt: admin.firestore.FieldValue.serverTimestamp(), updatedAt: admin.firestore.FieldValue.serverTimestamp() }, { merge: true });
                                    batchCount++;
                                    addedCount++;
                                    await commitBatchIfNeeded();
                                } else {
                                    functions.logger.warn(`[${traceId}] New event skipped due to missing eventUrl: ${event.title}`);
                                }
                            }
                        }

                        // 不要になった過去のイベントを削除（期限切れのもののみ削除）
                        const now = new Date();
                        for (const existing of currentEventsList) {
                            let isExpired = false;
                            if (existing.data.endDate && existing.data.endDate !== 'TBD') {
                                const endDateStr = existing.data.endDate.includes(' ')
                                    ? existing.data.endDate.replace(' ', 'T') + '+09:00'
                                    : existing.data.endDate + 'T23:59:59+09:00';
                                const endDate = new Date(endDateStr);
                                if (!isNaN(endDate.getTime()) && endDate < now) {
                                    isExpired = true;
                                }
                            }

                            if (isExpired) {
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

            // レート制限（RPM）回避のため、次のゲーム処理に移る前に15秒待機する
            await sleep(15000);
        }
        await snapshot.ref.update({ status: 'completed', updatedAt: admin.firestore.FieldValue.serverTimestamp(), debugInfo, totalTokens });
        await writeDebugLog(traceId, 'processSyncRequest process completed successfully.');
        return { success: true, message: 'Sync completed via Grounded Gemini.', debugInfo };
    } catch (error) {
        const errorMessage = error instanceof Error ? error.message : String(error);
        await snapshot.ref.update({ status: 'error', error: errorMessage, updatedAt: admin.firestore.FieldValue.serverTimestamp() });
        functions.logger.error(`[${traceId}] Unhandled catastrophic error: ${error instanceof Error ? error.stack : String(error)}`);
        throw error;
    }
});

export const triggerScheduledSync = functions.region('asia-northeast1').https.onRequest(async (req, res) => {
    // Generate traceId here if we cannot use uuidv4 easily or we can just use a simple random string for now if uuidv4 isn't at the top level
    const traceId = 'sched-' + Date.now() + '-' + Math.floor(Math.random() * 10000);
    functions.logger.info(`[${traceId}] triggerScheduledSync triggered by Cloud Scheduler`, { traceId });

    try {
        await db.collection('sync_requests').add({
            status: 'pending',
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
            debugInfo: [
                {
                    timestamp: new Date().toISOString(),
                    message: 'Sync requested via scheduled background job'
                }
            ]
        });
        await writeDebugLog(traceId, 'Scheduled sync request added successfully.');
        res.status(200).send('Scheduled sync triggered');
    } catch (error: any) {
        functions.logger.error(`[${traceId}] Failed to trigger scheduled sync`, { error: error.message, stack: error instanceof Error ? error.stack : String(error) });
        await writeDebugLog(traceId, 'Failed to trigger scheduled sync', error instanceof Error ? error.stack : String(error));
        res.status(500).send('Internal Server Error');
    }
});

export const updateSyncSchedule = onDocumentWritten({ document: 'settings/sync_config', database: 'default', region: 'asia-northeast1' }, async (event) => {
    const traceId = 'sched-upd-' + Date.now();
    functions.logger.info(`[${traceId}] updateSyncSchedule triggered`, { traceId });

    const afterData = event.data?.after?.data();

    const projectId = process.env.GCLOUD_PROJECT || process.env.GOOGLE_CLOUD_PROJECT || 'game-tracker-444b2'; // Fallback to project ID
    const locationId = 'asia-northeast1';
    const client = new CloudSchedulerClient();
    const parent = client.locationPath(projectId, locationId);

    // Get the Cloud Function URL dynamically or construct it
    const functionUrl = `https://${locationId}-${projectId}.cloudfunctions.net/triggerScheduledSync`;

    try {
        // Fetch existing jobs to delete old ones
        let existingJobs: any[] = [];
        try {
            const [jobs] = await client.listJobs({ parent });
            existingJobs = jobs.filter(job => job.name?.includes('/jobs/sync-job-') || job.name?.endsWith('/jobs/sync-job'));
        } catch (listError: any) {
            functions.logger.warn(`[${traceId}] Could not list jobs (might not exist yet): ${listError.message}`);
        }

        const isPaused = afterData?.is_paused === true;

        let scanTimes: string[] = [];
        if (afterData?.scan_times && Array.isArray(afterData.scan_times)) {
            scanTimes = afterData.scan_times;
        } else if (afterData?.cron_schedule) {
            // Fallback for old single schedule format temporarily
            const parts = (afterData.cron_schedule as string).split(' ');
            if (parts.length >= 2) {
                 const minute = parts[0].padStart(2, '0');
                 const hour = parts[1].padStart(2, '0');
                 scanTimes.push(`${hour}:${minute}`);
            }
        }

        if (isPaused || scanTimes.length === 0) {
            // Delete all jobs
            for (const job of existingJobs) {
                if (job.name) {
                    await client.deleteJob({ name: job.name });
                    functions.logger.info(`[${traceId}] Cloud Scheduler job deleted: ${job.name}`);
                }
            }
            await writeDebugLog(traceId, isPaused ? 'All Cloud Scheduler jobs deleted (Paused).' : 'All Cloud Scheduler jobs deleted (No times set).');
            return;
        }

        const activeJobNames = new Set<string>();

        // Create or update required jobs
        for (const timeStr of scanTimes) {
            const parts = timeStr.split(':');
            if (parts.length !== 2) continue;

            const hour = parts[0];
            const minute = parts[1];

            const cronSchedule = `${parseInt(minute)} ${parseInt(hour)} * * *`;
            const jobId = `sync-job-${hour}-${minute}`;
            const name = client.jobPath(projectId, locationId, jobId);
            activeJobNames.add(name);

            const job = {
                name,
                schedule: cronSchedule,
                timeZone: 'Asia/Tokyo',
                httpTarget: {
                    uri: functionUrl,
                    httpMethod: 'POST' as const,
                },
            };

            let jobExists = existingJobs.some(existing => existing.name === name);

            if (jobExists) {
                // Update
                await client.updateJob({
                    job,
                    updateMask: { paths: ['schedule', 'http_target.uri'] }
                });
                functions.logger.info(`[${traceId}] Cloud Scheduler job updated: ${name} with schedule: ${cronSchedule}`);
            } else {
                // Create
                try {
                    await client.createJob({
                        parent,
                        job
                    });
                    functions.logger.info(`[${traceId}] Cloud Scheduler job created: ${name} with schedule: ${cronSchedule}`);
                } catch (createErr: any) {
                    if (createErr.code === 6) { // ALREADY_EXISTS
                        await client.updateJob({
                            job,
                            updateMask: { paths: ['schedule', 'http_target.uri'] }
                        });
                        functions.logger.info(`[${traceId}] Cloud Scheduler job already exists, updated: ${name} with schedule: ${cronSchedule}`);
                    } else {
                        throw createErr;
                    }
                }
            }
        }

        // Delete jobs that are no longer needed
        for (const job of existingJobs) {
            if (job.name && !activeJobNames.has(job.name)) {
                await client.deleteJob({ name: job.name });
                functions.logger.info(`[${traceId}] Cloud Scheduler job deleted (removed from schedule): ${job.name}`);
            }
        }

        await writeDebugLog(traceId, `Cloud Scheduler jobs synchronized. Active times: ${scanTimes.join(', ')}`);

    } catch (error: any) {
        functions.logger.error(`[${traceId}] Error updating Cloud Scheduler jobs: ${error.message}`, { stack: error instanceof Error ? error.stack : String(error) });
        await writeDebugLog(traceId, 'Error updating Cloud Scheduler jobs', error instanceof Error ? error.stack : String(error));
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

// Google Driveへのエクスポート処理
export const exportToDrive = functions.region('asia-northeast1').runWith({ memory: '512MB', timeoutSeconds: 300 }).https.onCall(async (data, context) => {
    const traceId = 'export-' + Date.now() + '-' + Math.floor(Math.random() * 10000);
    const folderId = data.folderId;

    if (!folderId) {
        throw new functions.https.HttpsError('invalid-argument', 'folderId is required');
    }

    functions.logger.info(`[${traceId}] Starting exportToDrive to folder: ${folderId}`);
    await writeDebugLog(traceId, `Starting export to Google Drive. Folder ID: ${folderId}`);

    try {
        // FirestoreのcollectionGroup('events')から全データを取得
        const eventsSnapshot = await db.collectionGroup('events').get();
        const events = eventsSnapshot.docs.map(doc => {
            const data = doc.data();
            // AIに調査・補完してほしい項目は、欠落していても明示的に null として出力する
            // トークンを消費する createdAt, updatedAt, imageUrl は含めない
            return {
                id: doc.id,
                gameName: data.gameName ?? null,
                title: data.title ?? null,
                summary: data.summary ?? null,
                tag: data.tag ?? null,
                subTag: data.subTag ?? null,
                startDate: data.startDate ?? null,
                endDate: data.endDate ?? null,
                eventUrl: data.eventUrl ?? null,
                redeemCode: data.redeemCode ?? null,
                isLocked: data.isLocked ?? false
            };
        });

        const jsonString = JSON.stringify(events, null, 2);
        const fileName = 'events_export.json';

        // GoogleAuthでデフォルト認証を取得 (ADC)
        const auth = new google.auth.GoogleAuth({
            scopes: ['https://www.googleapis.com/auth/drive']
        });
        const drive = google.drive({ version: 'v3', auth });

        // 指定されたfolderId配下のすべてのファイルを取得（名前で絞り込まない）
        const query = `'${folderId}' in parents and trashed=false`;
        const res = await drive.files.list({
            q: query,
            spaces: 'drive',
            fields: 'files(id, name, mimeType)',
            includeItemsFromAllDrives: true,
            supportsAllDrives: true
        });

        const allFiles = res.data.files || [];
        await writeDebugLog(traceId, `Drive API recognized files in folder:`, allFiles);

        const existingFile = allFiles.find(f => f.name === fileName);

        const media = {
            mimeType: 'application/json',
            body: jsonString
        };

        let driveFile;
        if (existingFile) {
            // 上書き更新
            const fileId = existingFile.id!;
            functions.logger.info(`[${traceId}] Updating existing file: ${fileId}`);
            const updateRes = await drive.files.update({
                fileId: fileId,
                media: media
            });
            driveFile = updateRes.data;
            await writeDebugLog(traceId, `Updated existing file in Drive. File ID: ${fileId}`);
        } else {
            // Quotaエラーを防ぐため、新規作成せずにエラーで終了する
            const errorMsg = `Target file '${fileName}' not found. Recognized files: ${JSON.stringify(allFiles)}`;
            functions.logger.error(`[${traceId}] ${errorMsg}`);
            await writeDebugLog(traceId, errorMsg);
            throw new functions.https.HttpsError('not-found', `ダミーファイルが見つかりません。ログを確認してください。認識されたファイル数: ${allFiles.length}`);
        }

        functions.logger.info(`[${traceId}] Export completed successfully. File ID: ${driveFile.id}`);
        return {
            success: true,
            message: 'Export successful',
            fileId: driveFile.id,
            exportedCount: events.length
        };

    } catch (error: any) {
         functions.logger.error(`[${traceId}] Export failed: ${error.message}`, { stack: error instanceof Error ? error.stack : String(error) });
         await writeDebugLog(traceId, 'Export failed', error instanceof Error ? error.stack : String(error));
         throw new functions.https.HttpsError('internal', 'Failed to export to Google Drive', error.message);
    }
});
