import { PassThrough } from 'stream';
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

function countJapaneseChars(str: string): number {
    if (!str) return 0;
    const match = str.match(/[ぁ-んァ-ン一-龯]/g);
    return match ? match.length : 0;
}

function selectBetterTitle(t1: string, t2: string): string {
    if (!t1) return t2 || '';
    if (!t2) return t1 || '';
    const count1 = countJapaneseChars(t1);
    const count2 = countJapaneseChars(t2);
    if (count1 > count2) return t1;
    if (count2 > count1) return t2;
    return t1.length >= t2.length ? t1 : t2; // 日本語文字数が同じなら長い方を残す
}

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
        // AIの出力揺れ（JST等の文字列）を除去
        const cleanVal = val.replace(/JST|UTC|GMT/gi, '').trim();
        // TypeScriptの型エラーを避けるため any キャストして tz を呼び出す
        const d = (dayjs as any).tz(cleanVal, 'Asia/Tokyo');

        if (d.isValid()) {
            // 時間指定がなく日付（YYYY-MM-DDやYYYY/MM/DD）のみの場合は、その日の23:59:59に設定
            if (!cleanVal.includes(' ') && !cleanVal.includes('T')) {
                return d.hour(23).minute(59).second(59).toDate();
            }
            return d.toDate();
        }
        return null;
    }
    return null;
}

async function cleanupDuplicateEvents(eventsList: any[], firestoreDb: admin.firestore.Firestore): Promise<any[]> {
    const toDelete = new Set<string>();
    let batch = firestoreDb.batch();
    let batchCount = 0;

    const commitIfNeeded = async () => {
        if (batchCount >= 450) {
            await batch.commit();
            batch = firestoreDb.batch();
            batchCount = 0;
        }
    };

    const gameGroups = new Map<string, any[]>();
    for (const e of eventsList) {
        const game = e.data.gameName || 'unknown';
        if (!gameGroups.has(game)) gameGroups.set(game, []);
        gameGroups.get(game)!.push(e);
    }

    for (const group of gameGroups.values()) {
        for (let i = 0; i < group.length; i++) {
            const e1 = group[i];
            if (toDelete.has(e1.docId)) continue;

            for (let j = i + 1; j < group.length; j++) {
                const e2 = group[j];
                if (toDelete.has(e2.docId)) continue;

                let isDuplicate = false;

                if (e1.data.tag === 'コード' || e2.data.tag === 'コード') {
                    if (e1.data.redeemCode && e2.data.redeemCode && e1.data.redeemCode.toUpperCase() === e2.data.redeemCode.toUpperCase()) {
                        isDuplicate = true;
                    }
                } else if (e1.data.eventUrl && e2.data.eventUrl && e1.data.eventUrl === e2.data.eventUrl) {
                    isDuplicate = true;
                } else if (e1.data.title && e2.data.title && calculateSimilarity(e1.data.title, e2.data.title) >= 0.85) {
                    isDuplicate = true;
                }

                if (isDuplicate) {
                    const updateData: any = {};
                    let hasUpdate = false;

                    const betterTitle = selectBetterTitle(e1.data.title, e2.data.title);
                    if (betterTitle !== e1.data.title) {
                        updateData.title = betterTitle;
                        hasUpdate = true;
                        e1.data.title = betterTitle;
                    }

                    if (!e1.data.eventUrl && e2.data.eventUrl) { updateData.eventUrl = e2.data.eventUrl; hasUpdate = true; e1.data.eventUrl = e2.data.eventUrl; }
                    if (!e1.data.redeemCode && e2.data.redeemCode) { updateData.redeemCode = e2.data.redeemCode; hasUpdate = true; e1.data.redeemCode = e2.data.redeemCode; }
                    if (!e1.data.startDate && e2.data.startDate) { updateData.startDate = e2.data.startDate; hasUpdate = true; e1.data.startDate = e2.data.startDate; }
                    if (!e1.data.endDate && e2.data.endDate) { updateData.endDate = e2.data.endDate; hasUpdate = true; e1.data.endDate = e2.data.endDate; }

                    if (hasUpdate) {
                        batch.update(e1.ref, updateData);
                        batchCount++;
                        await commitIfNeeded();
                    }

                    batch.delete(e2.ref);
                    batchCount++;
                    await commitIfNeeded();

                    toDelete.add(e2.docId);
                }
            }
        }
    }

    if (batchCount > 0) {
        await batch.commit();
    }

    return eventsList.filter(e => !toDelete.has(e.docId));
}

function calculateSimilarity(s1: string, s2: string): number {
    let longer = s1.toLowerCase().replace(/[\s　]+/g, '');
    let shorter = s2.toLowerCase().replace(/[\s　]+/g, '');
    if (longer.length < shorter.length) {
        const temp = longer; longer = shorter; shorter = temp;
    }
    const longerLength = longer.length;
    if (longerLength === 0) return 1.0;
    const shorterLength = shorter.length;
    if (shorterLength === 0) return 0.0;

    // LCS (Longest Common Subsequence) based logic for 80% partial match
    const dp = Array.from({ length: longerLength + 1 }, () => new Array(shorterLength + 1).fill(0));

    for (let i = 1; i <= longerLength; i++) {
        for (let j = 1; j <= shorterLength; j++) {
            if (longer[i - 1] === shorter[j - 1]) {
                dp[i][j] = dp[i - 1][j - 1] + 1;
            } else {
                dp[i][j] = Math.max(dp[i - 1][j], dp[i][j - 1]);
            }
        }
    }
    const lcsLength = dp[longerLength][shorterLength];
    if (shorterLength >= 5 && (lcsLength / shorterLength) >= 0.8) {
        return 0.85; // Meets the 80% partial match criteria
    }

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
            let isRetryable = errStr.includes('429') || errStr.includes('503') || errStr.includes('RESOURCE_EXHAUSTED');

            if (errStr.includes('GenerateRequestsPerDay') || errStr.includes('FreeTier')) {
                isRetryable = false;
            }

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

        let currentEventsList = currentEventsSnapshot.docs.map(doc => ({ docId: doc.id, data: doc.data(), ref: doc.ref }));

        currentEventsList = await cleanupDuplicateEvents(currentEventsList, db);

        const existingMiniList = currentEventsList.map(e => {
            const d = e.data;
            let endStr = '未定';
            if (d.endDate && typeof d.endDate.toDate === 'function') {
                endStr = d.endDate.toDate().toLocaleDateString('ja-JP');
            } else if (typeof d.endDate === 'string') {
                endStr = d.endDate;
            }
            const codeStr = d.redeemCode ? ` (コード: ${d.redeemCode})` : '';
            return `[ID: ${e.docId}] ${d.title}${codeStr} (期限: ${endStr})`;
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
1. Google検索機能を利用する際、必ず日本語の検索クエリを発行し、日本語で書かれた公式・攻略ウェブサイトのみを情報源としてください（検索クエリに lang:ja 等の演算子を含めて意図的に絞り込むこと）。英語や他言語のサイトは検索対象外です。
2. Google検索機能を最大限に活用し、【現在開催中】および【近日開催予定】の期間限定イベント、ガチャ、コラボ情報、ギフトコードを最新のウェブ検索結果から広く調査してください。
3. 一つの検索結果で妥協せず、内部で複数の検索クエリを発行して深掘りしてください。
4. 些細なログインボーナスやキャンペーン、コードであっても、独自の判断で省略・要約せず必ずすべて列挙してください。
5. 常設コンテンツ、恒常ガチャ、毎月定期開催されるものは除外してください。
6. ハルシネーション（推測・捏造）は絶対に禁止です。不明なURLや日時は無理に補完せずnullとしてください。
7. 期限管理が命です。「アップデート後」などの曖昧な表記は具体的な日付に変換してください。時間不明ならYYYY-MM-DDのみ。年省略時は今年を補完。
8. 現在日時（${currentDate}）を基準とし、すでに終了した過去のイベント（前年などの古いデータ）は絶対に除外してください。出力するイベントは必ず終了日が本日の日付以降、または未定（null）のもののみにすること。

${keywords ? `【必須検索指定】以下のキーワードに関連するイベントやガチャ情報は、必ず優先的に検索・調査して出力結果に含めてください：${keywords}` : ''}

【追加禁止イベント】以下のイベント（類似する日課・週課等のコンテンツ含む）はシステムで独自管理しているため、絶対に出力結果に含めず、新規追加しないでください：
[ ${cycleEventTitles.join(', ')} ]

【出力要件】
（マークダウン使用禁止。純粋なJSON配列のみ）
配列内の各オブジェクトは、必ず以下のプロパティキーを厳格な順序で使用すること：
- "date_extraction_reasoning": (文字列) ※最重要※ 検索結果のテキストから、イベントの開始・終了日時を特定・推測するための論理的な思考プロセスや計算式（例:「開始日は〇日で期間が2週間だから終了日は〇日」）を必ずここに記載すること。
- "existing_id": (文字列) 既存のイベント一覧と同一（または実質的に同じ）イベントと判断した場合、一覧にある [ID: xxx] の xxx の文字列を必ず出力すること。検索結果が外国語（英語等）でも、既存の日本語イベントの和訳・意訳と思われる場合は『実質的に同じ』とみなし、既存のIDを紐づけること。また、省略形や一部欠落でも明らかに同じイベントを指している場合は新規にせず紐づけること。完全に新規の場合は null。
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

                    const betterTitle = selectBetterTitle(existing.title, event.title);
                    if (betterTitle) existing.title = betterTitle;

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
                    const endDateObj = getSafeDateObj(event.endDate);
                    if (endDateObj && endDateObj.getTime() < nowMs) {
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
                        // コードの場合はタイトル類似度を無視し、コードの一致のみで判定する
                        if (event.tag === 'コード' || e.data.tag === 'コード') {
                            return event.redeemCode && e.data.redeemCode && event.redeemCode.toUpperCase() === e.data.redeemCode.toUpperCase();
                        }
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

                    const newTitle = selectBetterTitle(event.title, eData.title);

                    let changes: string[] = [];
                    if (newTitle && eData.title !== newTitle) changes.push('タイトル');
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
                        title: newTitle,
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

                        const newTitle = selectBetterTitle(event.title, eData.title);

                        let changes: string[] = [];
                        if (newTitle && eData.title !== newTitle) changes.push('タイトル');
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
                            title: newTitle,
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
        const fileName = 'events_export.json';
        const passThrough = new PassThrough();
        let exportedCount = 0;

        (async () => {
            try {
                passThrough.write('[\n');
                let isFirst = true;
                const stream = db.collectionGroup('events').stream();

                for await (const doc of stream) {
                    const data = (doc as unknown as admin.firestore.QueryDocumentSnapshot).data();
                    const eventData = {
                        id: (doc as unknown as admin.firestore.QueryDocumentSnapshot).id,
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

                    if (!isFirst) {
                        passThrough.write(',\n');
                    }
                    passThrough.write(JSON.stringify(eventData, null, 2));
                    isFirst = false;
                    exportedCount++;
                }
                passThrough.write('\n]');
                passThrough.end();
            } catch (err) {
                functions.logger.error(`[${traceId}] Stream error in exportToDrive`, err);
                passThrough.destroy(err as Error);
            }
        })();

        const media = {
            mimeType: 'application/json',
            body: passThrough
        };

        const auth = new google.auth.GoogleAuth({
            scopes: ['https://www.googleapis.com/auth/drive']
        });
        const drive = google.drive({ version: 'v3', auth });

        const query = `'${folderId}' in parents and trashed=false`;
        const res = await drive.files.list({
            q: query,
            spaces: 'drive',
            fields: 'files(id, name, mimeType)',
            includeItemsFromAllDrives: true,
            supportsAllDrives: true
        });

        const allFiles = res.data.files || [];
        const existingFile = allFiles.find(f => f.name === fileName);

        let driveFile;
        if (existingFile) {
            const fileId = existingFile.id!;
            functions.logger.info(`[${traceId}] Updating existing file: ${fileId}`);
            const updateRes = await drive.files.update({
                fileId: fileId,
                media: media
            });
            driveFile = updateRes.data;
            await writeDebugLog(traceId, `Updated existing file in Drive. File ID: ${fileId}`);
        } else {
            const errorMsg = `Target file '${fileName}' not found. Recognized files: ${JSON.stringify(allFiles)}`;
            functions.logger.error(`[${traceId}] ${errorMsg}`);
            await writeDebugLog(traceId, errorMsg);
            throw new functions.https.HttpsError('not-found', `ダミーファイル(${fileName})が見つかりません。ドライブに空のファイルを手動で作成してください。`);
        }

        functions.logger.info(`[${traceId}] Export completed successfully. File ID: ${driveFile.id}`);
        return {
            success: true,
            message: 'Export successful',
            fileId: driveFile.id,
            exportedCount: exportedCount
        };
    } catch (error: any) {
         functions.logger.error(`[${traceId}] Export failed: ${error.message}`, { stack: error instanceof Error ? error.stack : String(error) });
         await writeDebugLog(traceId, 'Export failed', error instanceof Error ? error.stack : String(error));
         throw new functions.https.HttpsError('internal', 'Failed to export to Google Drive', error.message);
    }
});

export const exportFeedbacksToDrive = functions.region('asia-northeast1').runWith({ memory: '256MB', timeoutSeconds: 300 }).https.onCall(async (data, context) => {
    const traceId = 'exportFeedbacks-' + Date.now() + '-' + Math.floor(Math.random() * 10000);
    const targetIds = data.targetIds;

    try {
        const configDoc = await db.collection('settings').doc('export_config').get();
        const folderId = configDoc.data()?.folder_id;

        if (!folderId) {
            throw new functions.https.HttpsError('failed-precondition', 'folderId is not set in settings/export_config');
        }

        functions.logger.info(`[${traceId}] Starting exportFeedbacksToDrive to folder: ${folderId}`);
        await writeDebugLog(traceId, `Starting feedback export to Google Drive. Folder ID: ${folderId}`);

        const feedbacksRef = db.collection('feedbacks');
        const fileName = 'feedback.json';
        const passThrough = new PassThrough();
        let exportedCount = 0;

        (async () => {
            try {
                passThrough.write('[\n');
                let isFirst = true;

                const processDoc = (doc: any) => {
                    const docData = doc.data();
                    if (!docData) return;
                    let createdAt = null;
                    if (docData.createdAt && docData.createdAt.toDate) {
                        createdAt = docData.createdAt.toDate().toISOString();
                    }
                    const feedbackData = {
                        id: (doc as unknown as admin.firestore.QueryDocumentSnapshot).id,
                        title: docData.title ?? null,
                        body: docData.body ?? null,
                        tag: docData.tag ?? null,
                        status: docData.status ?? null,
                        createdAt: createdAt
                    };
                    if (!isFirst) {
                        passThrough.write(',\n');
                    }
                    passThrough.write(JSON.stringify(feedbackData, null, 2));
                    isFirst = false;
                    exportedCount++;
                };

                if (targetIds && Array.isArray(targetIds) && targetIds.length > 0) {
                    for (const id of targetIds) {
                        const doc = await feedbacksRef.doc(id).get();
                        if (doc.exists) processDoc(doc);
                    }
                } else {
                    const stream = feedbacksRef.stream();
                    for await (const doc of stream) {
                        processDoc(doc);
                    }
                }

                passThrough.write('\n]');
                passThrough.end();
            } catch (err) {
                functions.logger.error(`[${traceId}] Stream error in exportFeedbacksToDrive`, err);
                passThrough.destroy(err as Error);
            }
        })();

        const media = {
            mimeType: 'application/json',
            body: passThrough
        };

        const auth = new google.auth.GoogleAuth({
            scopes: ['https://www.googleapis.com/auth/drive']
        });
        const drive = google.drive({ version: 'v3', auth });

        const query = `'${folderId}' in parents and trashed=false`;
        const res = await drive.files.list({
            q: query,
            spaces: 'drive',
            fields: 'files(id, name, mimeType)',
            includeItemsFromAllDrives: true,
            supportsAllDrives: true
        });

        const allFiles = res.data.files || [];
        const existingFile = allFiles.find(f => f.name === fileName);

        let driveFile;
        if (existingFile) {
            const fileId = existingFile.id!;
            functions.logger.info(`[${traceId}] Updating existing file: ${fileId}`);
            const updateRes = await drive.files.update({
                fileId: fileId,
                media: media
            });
            driveFile = updateRes.data;
            await writeDebugLog(traceId, `Updated existing file in Drive. File ID: ${fileId}`);
        } else {
            const errorMsg = `Target file '${fileName}' not found. Recognized files: ${JSON.stringify(allFiles)}`;
            functions.logger.error(`[${traceId}] ${errorMsg}`);
            await writeDebugLog(traceId, errorMsg);
            throw new functions.https.HttpsError('not-found', `ダミーファイル(${fileName})が見つかりません。ドライブに空のファイルを手動で作成してください。`);
        }

        functions.logger.info(`[${traceId}] Export completed successfully. File ID: ${driveFile.id}`);
        return {
            success: true,
            message: 'Export successful',
            fileId: driveFile.id,
            exportedCount: exportedCount
        };
    } catch (error: any) {
         functions.logger.error(`[${traceId}] Export failed: ${error.message}`, { stack: error instanceof Error ? error.stack : String(error) });
         await writeDebugLog(traceId, 'Export failed', error instanceof Error ? error.stack : String(error));
         throw new functions.https.HttpsError('internal', 'Failed to export feedbacks to Google Drive', error.message);
    }
});

async function runCycleResetLogic(traceId: string) {
    functions.logger.info(`[${traceId}] Starting runCycleResetLogic`);
    try {
        const eventsSnapshot = await db.collectionGroup('events').get();
        if (eventsSnapshot.empty) {
            functions.logger.info(`[${traceId}] No events found`);
            return;
        }

        let currentEventsList = eventsSnapshot.docs.map(doc => ({ docId: doc.id, data: doc.data(), ref: doc.ref }));
        currentEventsList = await cleanupDuplicateEvents(currentEventsList, db);

        const now = dayjs().tz('Asia/Tokyo');

        const batches: Promise<any>[] = [];
        let currentBatch = db.batch();
        let opCount = 0;
        let totalUpdated = 0;
        let totalDeleted = 0;

        for (const event of currentEventsList) {
            const doc = event.ref;
            const data = event.data;
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

                    currentBatch.update(doc, {
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
                    currentBatch.delete(doc);
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

        // Clean up debug_logs older than 7 days
        const sevenDaysAgo = admin.firestore.Timestamp.fromDate(new Date(Date.now() - 7 * 24 * 60 * 60 * 1000));
        const oldLogsSnapshot = await db.collection('debug_logs').where('timestamp', '<', sevenDaysAgo).get();

        let deletedLogsCount = 0;
        if (!oldLogsSnapshot.empty) {
            const logBatches: Promise<any>[] = [];
            let logBatch = db.batch();
            let logOpCount = 0;

            for (const logDoc of oldLogsSnapshot.docs) {
                logBatch.delete(logDoc.ref);
                logOpCount++;
                deletedLogsCount++;

                if (logOpCount === 450) {
                    logBatches.push(logBatch.commit());
                    logBatch = db.batch();
                    logOpCount = 0;
                }
            }

            if (logOpCount > 0) {
                logBatches.push(logBatch.commit());
            }

            await Promise.all(logBatches);
        }

        functions.logger.info(`[${traceId}] Successfully deleted ${deletedLogsCount} old debug logs.`);
        await writeDebugLog(traceId, `Successfully deleted ${deletedLogsCount} old debug logs.`);

    } catch (error: any) {
        functions.logger.error(`[${traceId}] Error in runCycleResetLogic: ${error.message}`, { stack: error instanceof Error ? error.stack : String(error) });
        await writeDebugLog(traceId, 'Error in runCycleResetLogic', error instanceof Error ? error.stack : String(error));
        throw error;
    }
}

export const resetCycleEvents = functions.region('asia-northeast1').pubsub.schedule('0 * * * *').timeZone('Asia/Tokyo').onRun(async (context) => {
    const traceId = 'cycle-reset-pubsub-' + Date.now();
    await runCycleResetLogic(traceId);
    return null;
});

export const manualResetCycleEvents = functions.region('asia-northeast1').runWith({ memory: '256MB', timeoutSeconds: 300 }).https.onCall(async (data, context) => {
    if (!context.auth) {
        throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated to run cycle reset.');
    }
    const traceId = 'cycle-reset-manual-' + Date.now();
    try {
        await runCycleResetLogic(traceId);
        return { success: true, message: 'Cycle reset logic completed successfully.' };
    } catch (error: any) {
        throw new functions.https.HttpsError('internal', 'Error executing manual cycle reset', error.message);
    }
});

export const setAdminRole = functions.region('asia-northeast1').https.onCall(async (data, context) => {
    if (!context.auth) {
        throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated.');
    }

    // フロントエンドから送られてくる秘密鍵
    const secret = data.secret;
    const ADMIN_SECRET = process.env.ADMIN_SECRET || 'GT_ADMIN_SECRET_2026';

    if (secret !== ADMIN_SECRET) {
        functions.logger.warn(`Failed admin role attempt for UID: ${context.auth.uid}`);
        throw new functions.https.HttpsError('permission-denied', 'Invalid admin secret.');
    }

    // すでに付与されている場合はスキップ
    if (context.auth.token.admin === true) {
        return { success: true, message: 'Already admin.' };
    }

    await admin.auth().setCustomUserClaims(context.auth.uid, { admin: true });
    functions.logger.info(`Admin role granted to UID: ${context.auth.uid}`);

    return { success: true, message: 'Admin role granted. Please refresh token.' };
});
