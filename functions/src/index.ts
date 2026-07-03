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

            // エラーオブジェクト内のどこに429/503が含まれていても検知できるように文字列化して判定
            const errStr = String(err?.message || '') + JSON.stringify(err);
            const isRetryable = errStr.includes('429') || errStr.includes('503') || errStr.includes('RESOURCE_EXHAUSTED');

            functions.logger.warn(`[${traceId}] Gemini API failed (Attempt ${attempt}/${maxRetries}). isRetryable: ${isRetryable}, Error: ${err.message}`);

            if (isLastAttempt || !isRetryable) {
                throw err; // 再試行不可、または最終試行の場合はスロー
            }

            // 429エラー時はAPIから40秒以上の待機を要求されるため、確実に60秒待機する
            await sleep(60000);
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
        const defaultScraperPrompt = `あなたはゲームの公式最新情報を正確に調査する専門のスクレイパーAIです。非公式リークや架空のデータは絶対に除外してください。
Google検索機能を利用して、ゲーム『{{gameName}}』で【現在開催中】および【近日開催予定】の期間限定イベントやガチャ、コラボ情報を最新のウェブ検索結果から広く調査してください。
既存のイベントタイトル（{{existingEventTitles}}）も参考にし、新しい情報や既存情報の更新がないか確認してください。
結果は、調査したイベント名、概要、開始・終了日時（わかる範囲で正確に）、関連URL、ギフトコード等をテキストで詳細に箇条書きで出力してください。`;

        const defaultAuditorPrompt = `あなたは提供された調査結果と既存のデータベースを比較・精査し、最終的なJSONデータを構築する厳格なオーディターAIです。
対象ゲーム: 『{{gameName}}』
スクレイパーの調査結果:
{{scraperResult}}

現在のデータベース状況（既存イベント）:
{{existingEventsDb}}

【追加禁止イベント】以下のイベント（類似する日課・週課等のコンテンツ含む）はシステムで独自管理しているため、絶対に出力結果に含めず、新規追加しないでください：
[ {{forbiddenEvents}} ]

【出力要件】
調査結果と既存DBを比較し、最終的に維持・更新・追加すべきイベント情報を以下のJSON配列形式のみで出力してください。Markdown装飾(\`\`\`json等)は不要です。
[
  {
    "existingId": "既存イベントと一致する場合はそのidを文字列で入力。完全に新規の場合はnull",
    "title": "イベントの正式名称（既存イベントと一致する場合は一言一句同じタイトルを使用）",
    "summary": "イベントの概要や報酬内容",
    "tag": "\"ゲーム内\", \"ゲーム外\", または \"コード\"",
    "redeemCode": "シリアルコードのアルファベット/数字（ない場合はnull）",
    "startDate": "YYYY-MM-DD (時間がわかる場合は YYYY-MM-DD HH:mm:00。不明な場合はnull)",
    "endDate": "YYYY-MM-DD (時間がわかる場合は YYYY-MM-DD HH:mm:00。不明な場合はnull)",
    "eventUrl": "公式ページや大手メディアの詳細URL（完全に新規の場合は必須。不明またはexistingIdがある場合はnull可。内部リダイレクトURLは禁止）",
    "imageUrl": null
  }
]

【重要ルール】
・期限管理が命です。「アップデート後」などの曖昧な表記は具体的な日付（YYYY/MM/DD）に変換してください。時間不明ならYYYY-MM-DDのみ。年省略時は今年を補完。
・常設コンテンツ、恒常ガチャ、毎月定期開催されるものは除外してください。
・既存DBの内容と比較し、実質的に同じイベントは必ず既存の \`id\` を \`existingId\` に指定して名寄せしてください。
・ハルシネーション（推測・捏造）は絶対に禁止です。不明なURLや日時は無理に補完せずnullとしてください。`;

        const scraperPromptTemplate = configData?.scraperPrompt || defaultScraperPrompt;
        const auditorPromptTemplate = configData?.auditorPrompt || defaultAuditorPrompt;

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

            const existingEventsForPrompt: any[] = [];
            const cycleEventTitles: string[] = [];
            const existingEventTitles: string[] = [];

            currentEventsSnapshot.docs.forEach(doc => {
                const data = doc.data();
                if (data.isCycleEvent === true || data.isCreationLocked === true || data.isDeleted === true) {
                    cycleEventTitles.push(data.title);
                }

                if (data.isCycleEvent !== true) {
                    existingEventTitles.push(data.title);
                    existingEventsForPrompt.push({
                        id: doc.id,
                        title: data.title,
                        endDate: data.endDate
                    });
                }
            });

            const currentDate = new Date().toLocaleString("ja-JP", { timeZone: "Asia/Tokyo" });

            // フェーズ1: スクレイパー
            let scraperPromptText = `【現在日時】 ${currentDate}\n\n` + scraperPromptTemplate
                .replace(/{{gameName}}/g, game.gameName)
                .replace(/{{existingEventTitles}}/g, existingEventTitles.join(', '));

            if (game.keywords && game.keywords.trim() !== '') {
                scraperPromptText += '\n\n【必須検索指定】\n以下のキーワードに関連するイベントやガチャ情報は、必ず優先的に検索・調査して出力結果に含めてください：' + game.keywords;
            }

            let scraperResult = '';

            try {
                functions.logger.info(`[${traceId}] Running Phase 1 (Scraper) for: ${game.gameName}`);
                const scraperResponse = await generateContentWithRetry(ai, 'gemini-2.5-flash', scraperPromptText, {
                    tools: [{ googleSearch: {} }]
                }, traceId);

                if (scraperResponse.usageMetadata?.totalTokenCount) {
                    totalTokens += scraperResponse.usageMetadata.totalTokenCount;
                }

                if (scraperResponse.text) {
                    scraperResult = scraperResponse.text;
                    debugInfo.push({ stage: 'Phase 1 (Scraper)', type: 'Response', game: game.gameName, text: scraperResult });
                    await writeDebugLog(traceId, `Scraper Response for ${game.gameName}`, { text: scraperResult });
                } else {
                    throw new Error("Scraper response text was empty.");
                }

                // 制限回避のため待機
                await sleep(10000);

                // フェーズ2: オーディター (TODO in next step)
                // For now, to keep the structure intact, we will set up the try block here but the actual
                // phase 2 will be in the next step. Let's just do the whole thing here since they are tight together.

                functions.logger.info(`[${traceId}] Running Phase 2 (Auditor) for: ${game.gameName}`);
                const existingEventsJsonStr = JSON.stringify(existingEventsForPrompt, null, 2);
                let auditorPromptText = auditorPromptTemplate
                    .replace(/{{gameName}}/g, game.gameName)
                    .replace(/{{scraperResult}}/g, scraperResult)
                    .replace(/{{existingEventsDb}}/g, existingEventsJsonStr)
                    .replace(/{{forbiddenEvents}}/g, cycleEventTitles.join(', '));

                const auditorResponse = await generateContentWithRetry(ai, 'gemini-2.5-flash', auditorPromptText, {}, traceId);

                if (auditorResponse.usageMetadata?.totalTokenCount) {
                    totalTokens += auditorResponse.usageMetadata.totalTokenCount;
                }

                if (auditorResponse.text) {
                    debugInfo.push({ stage: 'Phase 2 (Auditor)', type: 'Response', game: game.gameName, text: auditorResponse.text });
                    await writeDebugLog(traceId, `Auditor Response for ${game.gameName}`, { text: auditorResponse.text });

                    // パース処理（Markdownの除去およびJSON配列の抽出）
                    let extractedEvents: any[] = [];
                    const firstBracket = auditorResponse.text.indexOf('[');
                    const lastBracket = auditorResponse.text.lastIndexOf(']');
                    if (firstBracket !== -1 && lastBracket !== -1 && firstBracket < lastBracket) {
                        const jsonStr = auditorResponse.text.substring(firstBracket, lastBracket + 1);
                        extractedEvents = JSON.parse(jsonStr);
                    } else {
                        throw new Error("JSON array not found in Auditor response.");
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

                                    if (existingData.isLocked === true || existingData.isUpdateLocked === true) {
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

                        const debugIndex = debugInfo.findIndex(info => info.stage === 'Phase 2 (Auditor)' && info.game === game.gameName && info.type === 'Response');
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

            // レート制限（RPM: 15）を回避するため、次のゲームの処理に移る前に20秒待機する
            await sleep(20000);
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

export const resetCycleEvents = functions.region('asia-northeast1').pubsub.schedule('0 * * * *').timeZone('Asia/Tokyo').onRun(async (context) => {
    const traceId = 'cycle-reset-' + Date.now();
    functions.logger.info(`[${traceId}] Starting resetCycleEvents job`);

    try {
        const eventsSnapshot = await db.collectionGroup('events').where('isCycleEvent', '==', true).get();
        if (eventsSnapshot.empty) {
            functions.logger.info(`[${traceId}] No cycle events found`);
            return null;
        }

        const now = new Date(); // Native UTC date

        const batches: Promise<any>[] = [];
        let currentBatch = db.batch();
        let updateCount = 0;
        let totalUpdated = 0;

        for (const doc of eventsSnapshot.docs) {
            const data = doc.data();
            const endDateStr = data.endDate;
            if (!endDateStr) continue;

            // e.g. '2024-07-08 23:59:00' -> '2024-07-08T23:59:00+09:00'
            const endDateUTC = new Date(endDateStr.replace(' ', 'T') + '+09:00');
            if (isNaN(endDateUTC.getTime())) continue;

            if (endDateUTC <= now) {
                // The cycle event has expired, recalculate next deadline based on Tokyo time.
                const cycleType = data.cycleType;
                const cycleSettings = data.cycleSettings || {};

                // Get current Tokyo time components directly from 'now'
                const tokyoFormatter = new Intl.DateTimeFormat('en-US', {
                    timeZone: 'Asia/Tokyo',
                    year: 'numeric', month: '2-digit', day: '2-digit',
                    hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false
                });

                const tokyoParts = tokyoFormatter.formatToParts(now);
                const getPart = (type: string) => parseInt(tokyoParts.find(p => p.type === type)?.value || '0', 10);

                const tYear = getPart('year');
                const tMonth = getPart('month') - 1; // 0-indexed
                const tDay = getPart('day');

                // We construct a mock Date object to easily manipulate days/months in Tokyo context,
                // but note that new Date(year, month, day) in Cloud Functions creates a UTC/local date.
                // However, since we just need the string logic, we'll format it back properly.
                let nextEndDateTokyoObj = new Date(tYear, tMonth, tDay, cycleSettings.hour || 0, cycleSettings.minute || 0);
                const mockNowTokyoObj = new Date(tYear, tMonth, tDay, getPart('hour'), getPart('minute'), getPart('second'));

                if (cycleType === 'daily') {
                    if (nextEndDateTokyoObj <= mockNowTokyoObj) {
                        nextEndDateTokyoObj.setDate(nextEndDateTokyoObj.getDate() + 1);
                    }
                } else if (cycleType === 'weekly') {
                    const targetDay = cycleSettings.dayOfWeek || 1; // 1: Mon .. 7: Sun
                    while (nextEndDateTokyoObj.getDay() !== (targetDay === 7 ? 0 : targetDay) || nextEndDateTokyoObj <= mockNowTokyoObj) {
                        nextEndDateTokyoObj.setDate(nextEndDateTokyoObj.getDate() + 1);
                    }
                } else if (cycleType === 'biweekly') {
                    // Biweekly is relative to its original start date.
                    // Instead of starting from today, jump 14 days from its previous end date until it's > now

                    // Reconstruct the original Tokyo date exactly
                    const originalTYear = parseInt(endDateStr.substring(0, 4), 10);
                    const originalTMonth = parseInt(endDateStr.substring(5, 7), 10) - 1;
                    const originalTDay = parseInt(endDateStr.substring(8, 10), 10);
                    const originalTHour = parseInt(endDateStr.substring(11, 13), 10);
                    const originalTMinute = parseInt(endDateStr.substring(14, 16), 10);

                    nextEndDateTokyoObj = new Date(originalTYear, originalTMonth, originalTDay, originalTHour, originalTMinute);

                    while (nextEndDateTokyoObj <= mockNowTokyoObj) {
                        nextEndDateTokyoObj.setDate(nextEndDateTokyoObj.getDate() + 14);
                    }
                } else if (cycleType === 'monthly') {
                    const dayOfMonth = cycleSettings.dayOfMonth || 1;
                    nextEndDateTokyoObj = new Date(tYear, tMonth, dayOfMonth, cycleSettings.hour || 0, cycleSettings.minute || 0);
                    if (nextEndDateTokyoObj <= mockNowTokyoObj) {
                        nextEndDateTokyoObj = new Date(tYear, tMonth + 1, dayOfMonth, cycleSettings.hour || 0, cycleSettings.minute || 0);
                    }
                }

                const nextEndDateStr = `${nextEndDateTokyoObj.getFullYear()}-${(nextEndDateTokyoObj.getMonth() + 1).toString().padStart(2, '0')}-${nextEndDateTokyoObj.getDate().toString().padStart(2, '0')} ${nextEndDateTokyoObj.getHours().toString().padStart(2, '0')}:${nextEndDateTokyoObj.getMinutes().toString().padStart(2, '0')}:00`;

                // Reset tasks
                const tasks = data.tasks || [];
                const updatedTasks = tasks.map((task: any) => ({ ...task, isCompleted: false }));

                currentBatch.update(doc.ref, {
                    endDate: nextEndDateStr,
                    tasks: updatedTasks,
                    isCompleted: false,
                    updatedAt: admin.firestore.FieldValue.serverTimestamp()
                });

                updateCount++;
                totalUpdated++;

                if (updateCount === 450) {
                    batches.push(currentBatch.commit());
                    currentBatch = db.batch();
                    updateCount = 0;
                }
            }
        }

        if (updateCount > 0) {
            batches.push(currentBatch.commit());
        }

        await Promise.all(batches);
        functions.logger.info(`[${traceId}] Successfully reset ${totalUpdated} cycle events.`);
        if (totalUpdated > 0) {
            await writeDebugLog(traceId, `Successfully reset ${totalUpdated} cycle events.`);
        }

    } catch (error: any) {
        functions.logger.error(`[${traceId}] Error in resetCycleEvents: ${error.message}`, { stack: error instanceof Error ? error.stack : String(error) });
        await writeDebugLog(traceId, 'Error in resetCycleEvents', error instanceof Error ? error.stack : String(error));
    }
    return null;
});
