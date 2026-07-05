import * as functions from 'firebase-functions';
import { onDocumentCreated, onDocumentWritten } from "firebase-functions/v2/firestore";
import { onTaskDispatched } from "firebase-functions/v2/tasks";
import { getFunctions } from "firebase-admin/functions";
import * as admin from 'firebase-admin';
import { getFirestore } from 'firebase-admin/firestore';
import { CloudSchedulerClient } from '@google-cloud/scheduler';

import { GoogleGenAI } from '@google/genai';
import * as crypto from 'crypto';
import { google } from 'googleapis';
import dayjs from 'dayjs';
import utc from 'dayjs/plugin/utc';
import timezone from 'dayjs/plugin/timezone';
import isSameOrBefore from 'dayjs/plugin/isSameOrBefore';

dayjs.extend(utc);
dayjs.extend(timezone);
dayjs.extend(isSameOrBefore);
dayjs.tz.setDefault("Asia/Tokyo");

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

function getSafeDateObj(val: any): Date | null {
    if (!val) return null;
    if (val.toDate && typeof val.toDate === 'function') return val.toDate();
    if (typeof val === 'string') {
        const str = val.includes(' ') ? val.replace(' ', 'T') + '+09:00' : val + 'T23:59:59+09:00';
        const d = new Date(str);
        return isNaN(d.getTime()) ? null : d;
    }
    return null;
}

function calculateSimilarity(s1: string, s2: string): number {
    let longer = s1.toLowerCase().replace(/[\s　]+/g, '');
    let shorter = s2.toLowerCase().replace(/[\s　]+/g, '');
    if (longer.length < shorter.length) {
        const temp = longer; longer = shorter; shorter = temp;
    }
    const longerLength = longer.length;
    if (longerLength === 0) return 1.0;

    const costs: number[] = [];
    for (let i = 0; i <= longer.length; i++) {
        let lastValue = i;
        for (let j = 0; j <= shorter.length; j++) {
            if (i === 0) costs[j] = j;
            else if (j > 0) {
                let newValue = costs[j - 1];
                if (longer.charAt(i - 1) !== shorter.charAt(j - 1)) {
                    newValue = Math.min(Math.min(newValue, lastValue), costs[j]) + 1;
                }
                costs[j - 1] = lastValue;
                lastValue = newValue;
            }
        }
        if (i > 0) costs[shorter.length] = lastValue;
    }
    return (longerLength - costs[shorter.length]) / parseFloat(longerLength.toString());
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

            let waitTime = 60000;
            const delayMatch = errStr.match(/(\d+)(?:\.\d+)?s/);
            if (delayMatch && delayMatch[1]) {
                const parsedDelay = parseInt(delayMatch[1], 10) * 1000;
                waitTime = parsedDelay > 0 ? parsedDelay + 5000 : 60000; // 5秒のバッファを追加
                functions.logger.warn(`[${traceId}] Parsed retryDelay from error: ${parsedDelay}ms, waiting for ${waitTime}ms before retry.`);
            } else {
                functions.logger.warn(`[${traceId}] No explicit retryDelay found, waiting for default 60000ms before retry.`);
            }

            await sleep(waitTime);
        }
    }
}


export const processSyncRequest = onDocumentCreated({
    document: 'sync_requests/{requestId}',
    database: 'default',
    region: 'asia-northeast1',
    memory: '256MiB',
    timeoutSeconds: 60
}, async (event) => {
    const snapshot = event.data;
    if (!snapshot) return;
    const data = snapshot.data();
    const traceId = data.traceId || `trace-${event.params.requestId}`;
    const requestId = event.params.requestId;

    functions.logger.info(`[${traceId}] Starting processSyncRequest dispatcher`, { traceId });

    try {
        await snapshot.ref.update({ status: 'processing', updatedAt: admin.firestore.FieldValue.serverTimestamp() });
        const configDoc = await db.collection('settings').doc('config').get();
        const configData = configDoc?.data();
        const targetGames: ConfigItem[] = configData?.targets || [];

        if (targetGames.length === 0) {
            await writeDebugLog(traceId, 'Sync failed: Invalid config or no target games');
            await snapshot.ref.update({ status: 'error', error: 'No target games', updatedAt: admin.firestore.FieldValue.serverTimestamp() });
            return;
        }

        const queue = getFunctions().taskQueue('locations/asia-northeast1/functions/syncSingleGameTask');

        const debugInfo: any[] = [];

        for (const game of targetGames) {
            await queue.enqueue({
                gameName: game.gameName,
                keywords: game.keywords,
                requestId,
                traceId
            });
            debugInfo.push({ stage: 'Dispatch', game: game.gameName, message: 'Task enqueued' });
            functions.logger.info(`[${traceId}] Enqueued task for ${game.gameName}`);
        }

        await writeDebugLog(traceId, 'All tasks dispatched successfully.');
        await snapshot.ref.update({
            status: 'dispatched',
            debugInfo,
            totalTasks: targetGames.length,
            completedTasks: 0,
            updatedAt: admin.firestore.FieldValue.serverTimestamp()
        });

        return { success: true, message: 'Tasks dispatched' };
    } catch (error) {
        const errorMessage = error instanceof Error ? error.message : String(error);
        await snapshot.ref.update({ status: 'error', error: errorMessage, updatedAt: admin.firestore.FieldValue.serverTimestamp() });
        functions.logger.error(`[${traceId}] Unhandled dispatcher error: ${error instanceof Error ? error.stack : String(error)}`);
        throw error;
    }
});


export const syncSingleGameTask = onTaskDispatched({
    retryConfig: { maxAttempts: 3, minBackoffSeconds: 60 },
    rateLimits: { maxConcurrentDispatches: 1, maxDispatchesPerSecond: 0.1 },
    timeoutSeconds: 300,
    region: 'asia-northeast1',
    memory: '512MiB'
}, async (request) => {
    const { gameName, keywords, requestId, traceId } = request.data;

    functions.logger.info(`[${traceId}] Starting worker for ${gameName}`, { traceId, gameName });

    try {
        const configDoc = await db.collection('settings').doc('config').get();
        const configData = configDoc?.data();
        const codeUrls: { gameName: string, url: string }[] = configData?.codeUrls || [];
        const geminiApiKey = configData?.geminiApiKey;

        if (!geminiApiKey) {
            throw new Error('Gemini API key is missing');
        }

        const ai = new GoogleGenAI({ apiKey: geminiApiKey.trim() });

        const eventsCollection = db.collection(`games/${gameName}/events`);
        const currentEventsSnapshot = await eventsCollection.get();

        const currentEventsMap = new Map();
        currentEventsSnapshot.forEach(doc => currentEventsMap.set(doc.data().title, { docId: doc.id, data: doc.data() }));
        const currentEventsList = Array.from(currentEventsMap.values());

        const existingMiniList = currentEventsList.map(e => {
            const d = e.data;
            let endStr = '未定';
            if (d.endDate && typeof d.endDate.toDate === 'function') {
                endStr = d.endDate.toDate().toLocaleDateString('ja-JP');
            } else if (typeof d.endDate === 'string') {
                endStr = d.endDate;
            }
            return `[ID: ${e.docId}] ${d.title} (期限: ${endStr})`;
        }).join('\n');

        const cycleEventTitles: string[] = [];

        const now = new Date();

        currentEventsSnapshot.docs.forEach(doc => {
            const data = doc.data();
            if (data.isCycleEvent === true || data.isCreationLocked === true || data.isDeleted === true) {
                cycleEventTitles.push(data.title);
            }
        });

        const currentDate = dayjs().tz("Asia/Tokyo").format("YYYY/MM/DD HH:mm:ss");

        const promptText = `あなたはゲーム『${gameName}』の公式最新情報を正確に調査し、最終的なJSONデータを出力する専門AIです。指定されたゲームの【現在開催中】および【近日開催予定】のイベント・キャンペーン・コードをGoogle検索で網羅的に抽出しなさい。
【既存のイベント一覧（参考）】
${existingMiniList || 'なし'}

【現在日時】 ${currentDate}

【厳格な指示（Strict mandates）】
1. Google検索機能を最大限に活用し、【現在開催中】および【近日開催予定】の期間限定イベント、ガチャ、コラボ情報、ギフトコードを最新のウェブ検索結果から広く調査してください。
2. 一つの検索結果で妥協せず、内部で複数の検索クエリを発行して深掘りしてください。
3. 些細なログインボーナスやキャンペーン、コードであっても、独自の判断で省略・要約せず必ずすべて列挙してください。
4. 常設コンテンツ、恒常ガチャ、毎月定期開催されるものは除外してください。
5. ハルシネーション（推測・捏造）は絶対に禁止です。不明なURLや日時は無理に補完せずnullとしてください。
6. 期限管理が命です。「アップデート後」などの曖昧な表記は具体的な日付に変換してください。時間不明ならYYYY-MM-DDのみ。年省略時は今年を補完。
7. 現在日時（${currentDate}）を基準とし、すでに終了した過去のイベント（前年などの古いデータ）は絶対に除外してください。出力するイベントは必ず終了日が本日の日付以降、または未定（null）のもののみにすること。

${keywords ? `【必須検索指定】以下のキーワードに関連するイベントやガチャ情報は、必ず優先的に検索・調査して出力結果に含めてください：${keywords}` : ''}

【追加禁止イベント】以下のイベント（類似する日課・週課等のコンテンツ含む）はシステムで独自管理しているため、絶対に出力結果に含めず、新規追加しないでください：
[ ${cycleEventTitles.join(', ')} ]

【出力要件】
（マークダウン使用禁止。純粋なJSON配列のみ）
配列内の各オブジェクトは、必ず以下のプロパティキーを厳格な順序で使用すること：
- "date_extraction_reasoning": (文字列) ※最重要※ 検索結果のテキストから、イベントの開始・終了日時を特定・推測するための論理的な思考プロセスや計算式（例:「開始日は〇日で期間が2週間だから終了日は〇日」）を必ずここに記載すること。
- "existing_id": (文字列) 既存のイベント一覧と同一（または実質的に同じ）イベントと判断した場合、一覧にある [ID: xxx] の xxx の文字列を必ず出力すること。完全に新規の場合は null。
- "title": (文字列) 既存IDを出力した場合は、一覧と「一言一句同じ」タイトルを使用すること。
- "summary": (文字列) イベント概要
- "startDate": (文字列) 開始日時(YYYY-MM-DD HH:mm:00) または 'UNKNOWN'
- "endDate": (文字列) 既存IDを出力し、かつ検索結果から終了日が判明しない場合は、絶対にnullにせず一覧にある（期限: xxx）の日付を引き継ぐこと。判明した場合は (YYYY-MM-DD HH:mm:00) または 'UNKNOWN'。
- "redeemCode": (文字列) ギフトコード または null
- "tag": (文字列) "ゲーム内", "ゲーム外", "コード" のいずれか
- "eventUrl": (文字列) URL または null`;

        const generationConfig = {
            temperature: 0.0,
            tools: [{ googleSearch: {} }]
        };

        functions.logger.info(`[${traceId}] Calling Gemini API for ${gameName}`);

        const response = await generateContentWithRetry(ai, 'gemini-2.5-flash-lite', promptText, generationConfig, traceId);

        let extractedEvents: any[] = [];
        if (response.text) {
            let cleanText = response.text.replace(/```json/gi, '').replace(/```/gi, '').trim();
            const startIndex = cleanText.indexOf('[');
            if (startIndex !== -1) {
                let parsed = false;
                // 後ろから ']' を探して、正しいJSONになるまで試行する
                for (let i = cleanText.lastIndexOf(']'); i >= startIndex; i--) {
                    if (cleanText[i] === ']') {
                        try {
                            extractedEvents = JSON.parse(cleanText.substring(startIndex, i + 1));
                            parsed = true;
                            break;
                        } catch (e) {
                            // JSONとして不正な場合は次の ']' を探す
                        }
                    }
                }
                if (!parsed) throw new Error("Failed to parse JSON array from response.");
            } else {
                throw new Error("No JSON array found in response.");
            }
            await writeDebugLog(traceId, `Gemini Response for ${gameName}`, { text: response.text });
        } else {
            throw new Error("Gemini response text was empty.");
        }

        let totalTokens = response.usageMetadata?.totalTokenCount || 0;

        if (Array.isArray(extractedEvents) && extractedEvents.length > 0) {
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

            const nowMs = new Date().getTime();

            // 1. AIレスポンス内の自己重複を排除する（より情報が多い方を優先してマージ）
            const uniqueExtractedEvents: any[] = [];
            for (const event of extractedEvents) {
                const duplicateIdx = uniqueExtractedEvents.findIndex(u =>
                    (event.eventUrl && u.eventUrl === event.eventUrl) ||
                    (u.title && event.title && calculateSimilarity(u.title, event.title) >= 0.85)
                );

                if (duplicateIdx === -1) {
                    uniqueExtractedEvents.push(event);
                } else {
                    // すでに配列内にある場合、情報（URLや終了日）を補完してマージする
                    const existing = uniqueExtractedEvents[duplicateIdx];
                    if (!existing.eventUrl && event.eventUrl) existing.eventUrl = event.eventUrl;
                    if ((!existing.endDate || existing.endDate === 'UNKNOWN') && event.endDate && event.endDate !== 'UNKNOWN') {
                        existing.endDate = event.endDate;
                    }
                    if ((!existing.startDate || existing.startDate === 'UNKNOWN') && event.startDate && event.startDate !== 'UNKNOWN') {
                        existing.startDate = event.startDate;
                    }
                    if (!existing.redeemCode && event.redeemCode) existing.redeemCode = event.redeemCode;
                }
            }

            for (const event of uniqueExtractedEvents) {
                if (!event.title) continue;

                if (event.startDate === 'UNKNOWN') event.startDate = null;
                if (event.endDate === 'UNKNOWN') event.endDate = null;

                if (event.endDate) {
                    const endMs = new Date(event.endDate).getTime();
                    if (!isNaN(endMs) && endMs < nowMs) {
                        functions.logger.info(`[${traceId}] Skipping past event: ${event.title} (endDate: ${event.endDate})`);
                        continue;
                    }
                }

                if (event.tag === 'コード' && event.redeemCode) {
                    if (!/^[a-zA-Z0-9_-]+$/.test(event.redeemCode)) {
                        functions.logger.warn(`[${traceId}] Invalid redeemCode detected and skipped: ${event.redeemCode}`);
                        continue;
                    }
                    const matchingConfig = codeUrls.find(c => c.gameName === gameName);
                    if (matchingConfig && matchingConfig.url) {
                        event.eventUrl = matchingConfig.url.replace('（コード）', event.redeemCode);
                    }
                }

                let existingEvent = undefined;
                // 1. AIが既存イベントと判定し、IDを返した場合
                if (event.existing_id) {
                    existingEvent = currentEventsList.find(e => e.docId === event.existing_id);
                }
                // 2. IDがない場合（新規扱い）でも、保険としてURLまたは類似度(85%以上)で照合する
                if (!existingEvent) {
                    existingEvent = currentEventsList.find(e => {
                        if (event.eventUrl && e.data.eventUrl === event.eventUrl) return true;
                        if (e.data.title && event.title && calculateSimilarity(e.data.title, event.title) >= 0.85) return true;
                        return false;
                    });
                }

                if (existingEvent) {
                    matchedDocIds.add(existingEvent.docId);

                    const eData = existingEvent.data;
                    if (eData.isLocked === true || eData.isUpdateLocked === true) {
                        unchangedCount++;
                        continue;
                    }

                    const formattedStart = event.startDate && event.startDate !== 'UNKNOWN' ? event.startDate : eData.startDate;
                    const formattedEnd = event.endDate && event.endDate !== 'UNKNOWN' ? event.endDate : eData.endDate;

                    let changes: string[] = [];
                    if (event.title && eData.title !== event.title) changes.push('タイトル');
                    if (event.summary && eData.summary !== event.summary) changes.push('概要');
                    if (eData.startDate !== formattedStart) changes.push(`開始日(${eData.startDate || 'なし'}→${formattedStart})`);
                    if (eData.endDate !== formattedEnd) changes.push(`終了日(${eData.endDate || 'なし'}→${formattedEnd})`);
                    if (event.redeemCode && eData.redeemCode !== event.redeemCode) changes.push(`コード(${eData.redeemCode || 'なし'}→${event.redeemCode})`);
                    if (event.eventUrl && eData.eventUrl !== event.eventUrl) changes.push('URL');
                    if (event.tag && eData.tag !== event.tag) changes.push('タグ');

                    if (changes.length === 0) {
                        unchangedCount++;
                        continue;
                    }

                    const historyMsg = `[${currentDate}] 自動同期: 変更あり（${changes.join(', ')}）`;

                    const updateData: any = {
                        title: event.title || eData.title,
                        summary: event.summary || eData.summary,
                        startDate: formattedStart || null,
                        endDate: formattedEnd || null,
                        redeemCode: event.redeemCode || eData.redeemCode || null,
                        eventUrl: event.eventUrl || eData.eventUrl || null,
                        tag: event.tag || eData.tag || null,
                        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                        updateHistory: admin.firestore.FieldValue.arrayUnion(historyMsg)
                    };

                    batch.update(eventsCollection.doc(existingEvent.docId), updateData);
                    batchCount++;
                    updatedCount++;
                    await commitBatchIfNeeded();
                } else {
                    const docIdRaw = gameName + '_' + (event.eventUrl || event.title);
                    const docId = event.tag === 'コード' && event.redeemCode ? 'code_' + event.redeemCode.toUpperCase().replace(/\s+/g, '') : crypto.createHash('md5').update(docIdRaw).digest('hex');

                    const docRef = eventsCollection.doc(docId);

                    // Check if it exists in currentEventsList to avoid overwriting existing events by coincidence (e.g. hash collision)
                    const existingByHash = currentEventsList.find(e => e.docId === docId);

                    if (existingByHash) {
                        matchedDocIds.add(docId);
                        const eData = existingByHash.data;
                        if (eData.isLocked === true || eData.isUpdateLocked === true) {
                            unchangedCount++;
                            continue;
                        }

                        const formattedStart = event.startDate && event.startDate !== 'UNKNOWN' ? event.startDate : eData.startDate;
                        const formattedEnd = event.endDate && event.endDate !== 'UNKNOWN' ? event.endDate : eData.endDate;

                        let changes: string[] = [];
                        if (event.title && eData.title !== event.title) changes.push('タイトル');
                        if (event.summary && eData.summary !== event.summary) changes.push('概要');
                        if (eData.startDate !== formattedStart) changes.push(`開始日(${eData.startDate || 'なし'}→${formattedStart})`);
                        if (eData.endDate !== formattedEnd) changes.push(`終了日(${eData.endDate || 'なし'}→${formattedEnd})`);
                        if (event.redeemCode && eData.redeemCode !== event.redeemCode) changes.push(`コード(${eData.redeemCode || 'なし'}→${event.redeemCode})`);
                        if (event.eventUrl && eData.eventUrl !== event.eventUrl) changes.push('URL');
                        if (event.tag && eData.tag !== event.tag) changes.push('タグ');

                        if (changes.length === 0) {
                            unchangedCount++;
                            continue;
                        }

                        const historyMsg = `[${currentDate}] 自動同期: 変更あり（${changes.join(', ')}）`;

                        const updateData: any = {
                            title: event.title || eData.title,
                            summary: event.summary || eData.summary,
                            startDate: formattedStart || null,
                            endDate: formattedEnd || null,
                            redeemCode: event.redeemCode || eData.redeemCode || null,
                            eventUrl: event.eventUrl || eData.eventUrl || null,
                            tag: event.tag || eData.tag || null,
                            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                            updateHistory: admin.firestore.FieldValue.arrayUnion(historyMsg)
                        };

                        batch.update(docRef, updateData);
                        batchCount++;
                        updatedCount++;
                        await commitBatchIfNeeded();
                    } else {
                        batch.set(docRef, {
                            ...event,
                            gameName: gameName,
                            subTag: null,
                            imageUrl: null,
                            isLocked: false,
                            isUpdateLocked: false,
                            isCreationLocked: false,
                            isDeleted: false,
                            tasks: [],
                            isCycleEvent: false,
                            createdAt: admin.firestore.FieldValue.serverTimestamp(),
                            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                            updateHistory: [`[${currentDate}] Created by AI Sync`]
                        });
                        batchCount++;
                        addedCount++;
                        await commitBatchIfNeeded();
                    }
                }
            }

            for (const existingEvent of currentEventsList) {
                if (!matchedDocIds.has(existingEvent.docId)) {
                    const eData = existingEvent.data;
                    if (eData.isCycleEvent === true || eData.isLocked === true || eData.isUpdateLocked === true || eData.isDeleted === true) {
                        continue;
                    }

                    if (eData.endDate) {
                        const endDateObj = getSafeDateObj(eData.endDate);
                        if (endDateObj && endDateObj < now) {
                            batch.delete(eventsCollection.doc(existingEvent.docId));
                            batchCount++;
                            deletedCount++;
                            await commitBatchIfNeeded();
                        }
                    }
                }
            }

            if (batchCount > 0) {
                await batch.commit();
            }

            const syncRequestRef = db.collection('sync_requests').doc(requestId);
            await db.runTransaction(async (t) => {
                const doc = await t.get(syncRequestRef);
                if (doc.exists) {
                    const docData = doc.data()!;
                    const newTotalTokens = (docData.totalTokens || 0) + totalTokens;

                    const newDebugInfo = {
                        stage: 'Processed',
                        game: gameName,
                        added: addedCount,
                        updated: updatedCount,
                        deleted: deletedCount,
                        unchanged: unchangedCount,
                        tokens: totalTokens
                    };

                    t.update(syncRequestRef, {
                        totalTokens: newTotalTokens,
                        completedTasks: admin.firestore.FieldValue.increment(1),
                        debugInfo: admin.firestore.FieldValue.arrayUnion(newDebugInfo),
                        updatedAt: admin.firestore.FieldValue.serverTimestamp()
                    });
                }
            });

            // Status aggregation
            const updatedDoc = await syncRequestRef.get();
            const uData = updatedDoc.data();
            if (uData && uData.totalTasks && uData.completedTasks >= uData.totalTasks) {
                 await syncRequestRef.update({
                     status: 'completed',
                     updatedAt: admin.firestore.FieldValue.serverTimestamp()
                 });
                 await writeDebugLog(traceId, 'All tasks completed successfully.', { requestId });
            }

        } else {
             const syncRequestRef = db.collection('sync_requests').doc(requestId);
             await db.runTransaction(async (t) => {
                 const doc = await t.get(syncRequestRef);
                 if (doc.exists) {
                     t.update(syncRequestRef, {
                         completedTasks: admin.firestore.FieldValue.increment(1),
                         debugInfo: admin.firestore.FieldValue.arrayUnion({ stage: 'Processed', game: gameName, message: 'No events found' }),
                         updatedAt: admin.firestore.FieldValue.serverTimestamp()
                     });
                 }
             });

             const updatedDoc = await syncRequestRef.get();
             const uData = updatedDoc.data();
             if (uData && uData.totalTasks && uData.completedTasks >= uData.totalTasks) {
                  await syncRequestRef.update({
                      status: 'completed',
                      updatedAt: admin.firestore.FieldValue.serverTimestamp()
                  });
                  await writeDebugLog(traceId, 'All tasks completed successfully.', { requestId });
             }
        }
    } catch (error) {
        functions.logger.error(`[${traceId}] Error processing ${gameName}: ${error}`);
        const syncRequestRef = db.collection('sync_requests').doc(requestId);

        await db.runTransaction(async (t) => {
             const doc = await t.get(syncRequestRef);
             if (doc.exists) {
                 t.update(syncRequestRef, {
                     completedTasks: admin.firestore.FieldValue.increment(1),
                     debugInfo: admin.firestore.FieldValue.arrayUnion({ stage: 'Error', game: gameName, error: error instanceof Error ? error.message : String(error) }),
                     updatedAt: admin.firestore.FieldValue.serverTimestamp()
                 });
             }
        });

        const updatedDoc = await syncRequestRef.get();
        const uData = updatedDoc.data();
        if (uData && uData.totalTasks && uData.completedTasks >= uData.totalTasks) {
             // We had an error, so we might want to set status to 'error' or 'completed' with errors.
             // We'll set it to 'completed' so it doesn't stay 'dispatched', or 'error' if it's considered totally failed.
             // Let's set it to completed but maybe there's a UI handling for errors in debugInfo.
             // Setting to 'error' might be better if any task failed, but the prompt says 'status == error' expects an 'error' field.
             await syncRequestRef.update({
                 status: 'completed', // Or we can keep it simple
                 updatedAt: admin.firestore.FieldValue.serverTimestamp()
             });
        }

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

// イベントの全クリア処理 (バッチ上限対応済み・OOM対策済み)
export const clearAllEvents = functions.runWith({ memory: '256MB', timeoutSeconds: 300 }).https.onCall(async (data, context) => {
    try {
        let totalDeleted = 0;

        while (true) {
            const snapshot = await db.collectionGroup('events').limit(450).get();
            if (snapshot.empty) break;

            const batch = db.batch();
            snapshot.docs.forEach((doc) => {
                batch.delete(doc.ref);
            });

            await batch.commit();
            totalDeleted += snapshot.docs.length;
        }

        functions.logger.info(`Successfully deleted ${totalDeleted} events from all games.`);
        return { success: true, deletedCount: totalDeleted };
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
        const eventsSnapshot = await db.collectionGroup('events').get();
        if (eventsSnapshot.empty) {
            functions.logger.info(`[${traceId}] No events found`);
            return null;
        }

        const now = dayjs().tz('Asia/Tokyo');

        const batches: Promise<any>[] = [];
        let currentBatch = db.batch();
        let opCount = 0;
        let totalUpdated = 0;
        let totalDeleted = 0;

        for (const doc of eventsSnapshot.docs) {
            const data = doc.data();
            const endDateUTC = getSafeDateObj(data.endDate);
            if (!endDateUTC) continue;

            const endDateDayjs = dayjs(endDateUTC).tz('Asia/Tokyo');

            if (endDateDayjs.isSameOrBefore(now)) {
                if (data.isCycleEvent === true) {
                    // The cycle event has expired, recalculate next deadline based on Tokyo time.
                    const cycleType = data.cycleType;
                    const cycleSettings = data.cycleSettings || {};

                    let nextEndDateTokyoObj = now.hour(cycleSettings.hour || 0).minute(cycleSettings.minute || 0).second(0).millisecond(0);

                    if (cycleType === 'daily') {
                        if (nextEndDateTokyoObj.isSameOrBefore(now)) {
                            nextEndDateTokyoObj = nextEndDateTokyoObj.add(1, 'day');
                        }
                    } else if (cycleType === 'weekly') {
                        const targetDay = cycleSettings.dayOfWeek || 1; // 1: Mon .. 7: Sun
                        // dayjs 0 is Sunday, 1 is Monday ... 6 is Saturday
                        const targetDayjsDay = targetDay === 7 ? 0 : targetDay;

                        while (nextEndDateTokyoObj.day() !== targetDayjsDay || nextEndDateTokyoObj.isSameOrBefore(now)) {
                            nextEndDateTokyoObj = nextEndDateTokyoObj.add(1, 'day');
                        }
                    } else if (cycleType === 'biweekly') {
                        // Biweekly is relative to its original start date.
                        // Instead of starting from today, jump 14 days from its previous end date until it's > now
                        nextEndDateTokyoObj = endDateDayjs.hour(cycleSettings.hour || 0).minute(cycleSettings.minute || 0).second(0).millisecond(0);

                        while (nextEndDateTokyoObj.isSameOrBefore(now)) {
                            nextEndDateTokyoObj = nextEndDateTokyoObj.add(14, 'day');
                        }
                    } else if (cycleType === 'monthly') {
                        const dayOfMonth = cycleSettings.dayOfMonth || 1;
                        nextEndDateTokyoObj = now.date(dayOfMonth).hour(cycleSettings.hour || 0).minute(cycleSettings.minute || 0).second(0).millisecond(0);

                        if (nextEndDateTokyoObj.isSameOrBefore(now)) {
                            nextEndDateTokyoObj = nextEndDateTokyoObj.add(1, 'month');
                        }
                    }

                    const nextEndDateStr = nextEndDateTokyoObj.format('YYYY-MM-DD HH:mm:00');
                    const nextEndDateObj = nextEndDateTokyoObj.toDate();

                    // Reset tasks
                    const tasks = data.tasks || [];
                    const updatedTasks = tasks.map((task: any) => ({ ...task, isCompleted: false }));

                    currentBatch.update(doc.ref, {
                        startDate: admin.firestore.Timestamp.fromDate(endDateUTC),
                        endDate: admin.firestore.Timestamp.fromDate(nextEndDateObj),
                        tasks: updatedTasks,
                        isCompleted: false,
                        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                        updateHistory: admin.firestore.FieldValue.arrayUnion(`[${nextEndDateStr}] サイクル更新（自動リセット）`)
                    });

                    opCount++;
                    totalUpdated++;
                } else {
                    // Normal event that has expired
                    currentBatch.delete(doc.ref);
                    opCount++;
                    totalDeleted++;
                }

                if (opCount === 450) {
                    batches.push(currentBatch.commit());
                    currentBatch = db.batch();
                    opCount = 0;
                }
            }
        }

        if (opCount > 0) {
            batches.push(currentBatch.commit());
        }

        await Promise.all(batches);
        functions.logger.info(`[${traceId}] Successfully reset ${totalUpdated} cycle events and deleted ${totalDeleted} expired normal events.`);
        if (totalUpdated > 0 || totalDeleted > 0) {
            await writeDebugLog(traceId, `Successfully reset ${totalUpdated} cycle events and deleted ${totalDeleted} expired normal events.`);
        }

    } catch (error: any) {
        functions.logger.error(`[${traceId}] Error in resetCycleEvents: ${error.message}`, { stack: error instanceof Error ? error.stack : String(error) });
        await writeDebugLog(traceId, 'Error in resetCycleEvents', error instanceof Error ? error.stack : String(error));
    }
    return null;
});
