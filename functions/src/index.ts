import { PassThrough } from 'stream';
import * as functions from 'firebase-functions';
import { onDocumentCreated, onDocumentWritten } from "firebase-functions/v2/firestore";
import { onTaskDispatched } from "firebase-functions/v2/tasks";
import { getFunctions } from "firebase-admin/functions";
import * as admin from 'firebase-admin';
import { getFirestore } from 'firebase-admin/firestore';
// import * as messaging from 'firebase-admin/messaging';
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



function normalizeString(str: string): string {
    if (!str) return '';
    return str
        .replace(/[【】\[\]（）()「」『』]/g, '')
        .replace(/[Ａ-Ｚａ-ｚ０-９]/g, (s) => String.fromCharCode(s.charCodeAt(0) - 0xFEE0))
        .replace(/\s+/g, '')
        .toLowerCase();
}
function getSafeDateObj(val: any): Date | null {
    if (!val) return null;
    if (val.toDate && typeof val.toDate === 'function') return val.toDate();
    if (typeof val === 'string') {
        let cleanVal = val.replace(/JST|UTC|GMT/gi, '').trim();
        if (!cleanVal) return null;

        // YYYY/MM/DD のような表記を YYYY-MM-DD に統一
        cleanVal = cleanVal.replace(/\//g, '-');

        // タイムゾーン情報（+09:00 や Z など）が含まれていない場合、強制的にJSTオフセットを付与する
        if (!cleanVal.includes('+') && !cleanVal.includes('-0') && !cleanVal.endsWith('Z')) {
            if (cleanVal.includes(' ')) {
                cleanVal = cleanVal.replace(' ', 'T') + '+09:00';
            } else if (cleanVal.includes('T')) {
                cleanVal = cleanVal + '+09:00';
            } else {
                // 日付のみ ('YYYY-MM-DD') の場合はその日の終わり (23:59:59) に設定
                cleanVal = cleanVal + 'T23:59:59+09:00';
            }
        }

        const d = new Date(cleanVal);
        if (!isNaN(d.getTime())) {
            return d;
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
                } else if (e1.data.title && e2.data.title && calculateSimilarity(normalizeString(e1.data.title), normalizeString(e2.data.title)) >= 0.85) {
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

        // Optimization: Only scan premium custom games for ACTIVE users
        // For this, we assume a user is active if they have logged in recently.
        // We'll collect UIDs from premium_custom_games, chunk them if large, and check their last active status.
        // If no user associated with a custom game is active (e.g. within 7 days), we can skip the sync for that game to save costs.
        const customGamesSet = new Set<string>();
        const premiumGamesSnapshot = await db.collection('premium_custom_games').get();

        // Define active threshold (e.g., 14 days)
        // Since we don't track lastLogin by default everywhere yet, we might rely on the fact that
        // we can check if they have valid token or premium status active.
        // If we strictly want to filter inactive, we would check the users collection.
        // To avoid massive reads, if the array of UIDs has any premium user, we assume it's active.
        // But for absolute cost savings, maybe we just deduplicate and enqueue only up to a global batch limit,
        // or check if users exist and have fcmToken (meaning they installed the app).

        // A simple optimization: check if at least one UID has a valid fcmToken
        const uidsToCheck = new Set<string>();
        const gameUidsMap = new Map<string, string[]>();

        premiumGamesSnapshot.forEach(doc => {
            const data = doc.data();
            if (data && Array.isArray(data.uids) && data.uids.length > 0) {
                const gameName = decodeURIComponent(doc.id);
                gameUidsMap.set(gameName, data.uids);
                data.uids.forEach(uid => uidsToCheck.add(uid));
            }
        });

        const activeUids = new Set<string>();
        const uidList = Array.from(uidsToCheck);

        // Batch read users to find active ones (has fcmToken)
        for (let i = 0; i < uidList.length; i += 100) {
            const chunk = uidList.slice(i, i + 100);
            const userSnapshots = await db.collection('users').where(admin.firestore.FieldPath.documentId(), 'in', chunk).get();
            userSnapshots.forEach(doc => {
                const uData = doc.data();
                // Consider active if they have FCM token (app installed) and are premium
                if (uData.isPremium === true && (uData.fcmToken || uData.settings?.fcmToken)) {
                    activeUids.add(doc.id);
                }
            });
        }

        for (const [gameName, uids] of gameUidsMap.entries()) {
            const hasActiveUser = uids.some(uid => activeUids.has(uid));
            if (hasActiveUser) {
                customGamesSet.add(gameName);
            }
        }

        // Filter out those already in targetGames
        targetGames.forEach(tg => {
            if (tg && tg.gameName) {
                customGamesSet.delete(tg.gameName);
            }
        });

        // Add to targetGames
        customGamesSet.forEach(customGame => {
            targetGames.push({
                gameName: customGame,
                keywords: ''
            });
        });

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
        const targetGames: ConfigItem[] = configData?.targets || [];
        const isCustomGame = !targetGames.some(tg => tg.gameName === gameName);
        const geminiApiKey = configData?.geminiApiKey;

        if (!geminiApiKey) {
            throw new Error('Gemini API key is missing');
        }

        const ai = new GoogleGenAI({ apiKey: geminiApiKey.trim() });

        const eventsCollection = db.collection(`games/${gameName}/events`);
        const currentEventsSnapshot = await eventsCollection.get();

        let currentEventsList = currentEventsSnapshot.docs.map(doc => ({ docId: doc.id, data: doc.data(), ref: doc.ref }));

        currentEventsList = await cleanupDuplicateEvents(currentEventsList, db);

        const now = dayjs().tz("Asia/Tokyo");

        // Filter out deleted events and past events (ended more than 3 days ago)
        const activeEventsList = currentEventsList.filter(e => {
            const d = e.data;
            if (d.isDeleted === true) return false;

            if (d.endDate) {
                let endDateJs;
                if (typeof d.endDate.toDate === 'function') {
                    endDateJs = dayjs(d.endDate.toDate()).tz("Asia/Tokyo");
                } else if (typeof d.endDate === 'string') {
                    endDateJs = dayjs(d.endDate).tz("Asia/Tokyo");
                }

                if (endDateJs && endDateJs.isValid()) {
                    // Check if ended more than 3 days ago
                    if (now.diff(endDateJs, 'day') > 3) {
                        return false;
                    }
                }
            } else {
                // If endDate is null, prune based on updatedAt (older than 30 days) to prevent context explosion
                const rawUpdated = d.updatedAt || d.createdAt;
                let updatedJs;
                if (rawUpdated && typeof rawUpdated.toDate === 'function') {
                    updatedJs = dayjs(rawUpdated.toDate()).tz("Asia/Tokyo");
                } else if (typeof rawUpdated === 'string') {
                    updatedJs = dayjs(rawUpdated).tz("Asia/Tokyo");
                }

                if (updatedJs && updatedJs.isValid()) {
                    if (now.diff(updatedJs, 'day') > 30) {
                        return false; // Skip events updated more than 30 days ago
                    }
                }
            }
            return true;
        });

        const existingMiniList = activeEventsList.map(e => {
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
6. ハルシネーション（推測・捏造）は絶対に禁止です。情報源（公式サイト・公式X・大手攻略サイト等）に明確に記載されている【実際の正式なイベント名・ガチャ名】のみを抽出してください。テキストにない架空のイベント名や、AIによる独自の命名（例：「炎の試練」「夏イベント」など）は固く禁じます。確証が得られない場合は絶対に抽出（出力）しないでください。不明なURLや日時は無理に補完せずnullとしてください。
7. 期限管理が命です。運営の「お知らせ記事の公開日」や「アップデート日」を、イベントの開始日として誤認しないように注意してください。必ず「ゲーム内でそのイベントが実際にプレイ可能になる開催期間」の記述を本文中から探し出して日付として採用してください。「アップデート後」などの曖昧な表記は具体的な日付に変換してください。時間不明ならYYYY-MM-DDのみ。年省略時は今年を補完。
8. 現在日時（${currentDate}）を基準とし、すでに終了した過去のイベント（前年などの古いデータ）は絶対に除外してください。出力するイベントは必ず終了日が本日の日付以降、または未定（null）のもののみにすること。
9. イベントの報酬を最大3つまで抽出し、配列として返してください。原石、星玉、ポリクローム、星声などのガチャ石（プレミアム通貨）やガチャチケットを最優先し、必ず配列の先頭（1番目）に配置してください。表記は簡潔にしてください（例: '💎 原石 x420', '🎁 限定武器', '💰 育成素材'）。報酬が不明、または攻略サイトに明確な記載がない場合は無理に抽出せず、空の配列を返してください（ハルシネーション厳禁）。
10. 「〇〇のお知らせ」「〇〇アップデート情報」「プロデューサーレター」のような【告知記事やニュースそのもの】はイベントではありませんので、絶対に抽出しないでください。さらに、原神の『祈願』や、崩壊：スターレイルの『跳躍』のような単なるガチャ・ピックアップ施策、あるいは恒常的なキャンペーンは、プレイ可能なゲーム内イベントではないため絶対に抽出しないでください。抽出対象は、あくまでその記事内で告知されている【個別の期間限定ゲーム内イベントやコード】のみです。
11. 【自己修復(Liveness Audit)】今回の検索結果と【既存のイベント一覧（参考）】を比較し、既存リストの中に「今回の検索結果には存在しない捏造・誤報イベント」や「すでに終了しているのに残っているイベント」があれば、その既存IDを \`invalid_existing_ids\` 配列に含めて返却してください。

${keywords ? `【必須検索指定】以下のキーワードに関連するイベントやガチャ情報は、必ず優先的に検索・調査して出力結果に含めてください：${keywords}` : ''}

【追加禁止イベント】以下のイベント（類似する日課・週課等のコンテンツ含む）はシステムで独自管理しているため、絶対に出力結果に含めず、新規追加しないでください：
[ ${cycleEventTitles.join(', ')} ]

【出力要件】
（マークダウン使用禁止。純粋なJSONのみ）
ルート要素は必ず \`events\` (配列) と \`invalid_existing_ids\` (文字列配列) を持つオブジェクトにしてください。
\`events\` 配列内の各オブジェクトは、必ず以下のプロパティキーを厳格な順序で使用すること：
- "event_validity_reasoning": (文字列) ※最重要※ なぜこれが単なるお知らせやガチャではなく、プレイ可能な期間限定イベントなのかの論理的な理由。
- "date_extraction_reasoning": (文字列) ※最重要※ 検索結果から日付を特定した理由。検索結果のテキストから、イベントの開始・終了日時を特定・推測するための論理的な思考プロセスや計算式（例:「開始日は〇日で期間が2週間だから終了日は〇日」）を記載すること。また必ず「この記事の公開日（〇日）ではなく、本文中の開催期間の記述（〇日〜〇日）を基準にした」など、公開日と実際の開催期間を明確に区別して判断したプロセスをここに記載すること。
- "match_reason": (文字列) 既存IDを紐づけた理由、または新規とした理由（「言語が違うが内容は同じである」「表記ゆれだが同一イベントである」など）。
- "existing_id": (文字列) 既存のイベント一覧と同一（または実質的に同じ）イベントと判断した場合、一覧にある [ID: xxx] の xxx の文字列を必ず出力すること。検索結果が外国語（英語等）でも、既存の日本語イベントの和訳・意訳と思われる場合は『実質的に同じ』とみなし、既存のIDを紐づけること。また、省略形や一部欠落でも明らかに同じイベントを指している場合は新規にせず紐づけること。完全に新規の場合は null。
- "title": (文字列) 既存IDを出力した場合は、一覧と「一言一句同じ」タイトルを使用すること。新規の場合は情報源に記載されている正式名称を一言一句そのまま使用すること。AIによる独自の命名、推測、要約は禁止。
- "summary": (文字列) イベント概要
- "startDate": (文字列) 開始日時(YYYY-MM-DD HH:mm:00) または 'UNKNOWN'
- "endDate": (文字列) 既存IDを出力し、かつ検索結果から終了日が判明しない場合は、絶対にnullにせず一覧にある（期限: xxx）の日付を引き継ぐこと。判明した場合は (YYYY-MM-DD HH:mm:00) または 'UNKNOWN'。
- "redeemCode": (文字列) ギフトコード または null
- "tag": (文字列) "ゲーム内", "ゲーム外", "コード" のいずれか
- "eventUrl": (文字列) URL または null
- "rewards": (オブジェクトの配列) 報酬リスト。必ず以下の構造を持つオブジェクトの配列にすること： [{ "name": "アイテムの完全な固有名称", "quantity": "数量（文字列）" }] 。一般的な「アイテム」等に要約せず、公式の固有名称を抽出すること。数量が記載されている場合は絶対に省略しないこと。記載がない場合は空配列 [] を返すこと。推測による補完は厳禁。`;

        const generationConfig = {
            temperature: 0.0,
            tools: [{ googleSearch: {} }],
            responseMimeType: "application/json",
            responseSchema: {
                type: "object",
                properties: {
                    invalid_existing_ids: {
                        type: "array",
                        items: { type: "string" }
                    },
                    events: {
                        type: "array",
                        items: {
                            type: "object",
                            properties: {
                                event_validity_reasoning: { type: "string" },
                                date_extraction_reasoning: { type: "string" },
                                match_reason: { type: "string" },
                                existing_id: { type: "string", nullable: true },
                                title: { type: "string" },
                                summary: { type: "string" },
                                startDate: { type: "string", nullable: true },
                                endDate: { type: "string", nullable: true },
                                redeemCode: { type: "string", nullable: true },
                                tag: { type: "string" },
                                eventUrl: { type: "string", nullable: true },
                                rewards: {
                                    type: "array",
                                    items: {
                                        type: "object",
                                        properties: {
                                            name: { type: "string" },
                                            quantity: { type: "string" }
                                        },
                                        required: ["name", "quantity"]
                                    }
                                }
                            },
                            required: ["event_validity_reasoning", "date_extraction_reasoning", "match_reason", "existing_id", "title", "summary", "startDate", "endDate", "redeemCode", "tag", "eventUrl", "rewards"]
                        }
                    }
                },
                required: ["events", "invalid_existing_ids"]
            }
        };

        functions.logger.info(`[${traceId}] Calling Gemini API for ${gameName}`);

        const response = await generateContentWithRetry(ai, 'gemini-2.5-flash-lite', promptText, generationConfig, traceId);

        let extractedEvents: any[] = [];
        let invalidExistingIds: string[] = [];
        if (response.text) {
            let cleanText = response.text.replace(/```json/gi, '').replace(/```/gi, '').trim();
            try {
                const parsedData = JSON.parse(cleanText);
                extractedEvents = parsedData.events || [];
                invalidExistingIds = parsedData.invalid_existing_ids || [];
            } catch (e) {
                functions.logger.warn(`[${traceId}] Failed to parse JSON via normal method. Attempting regex fallback...`);
                try {
                    const match = cleanText.match(/\{\s*"events"\s*:\s*\[[\s\S]*\]\s*,\s*"invalid_existing_ids"\s*:\s*\[[\s\S]*\]\s*\}/) ||
                                  cleanText.match(/\{\s*"invalid_existing_ids"\s*:\s*\[[\s\S]*\]\s*,\s*"events"\s*:\s*\[[\s\S]*\]\s*\}/);
                    if (match && match[0]) {
                        const parsedData = JSON.parse(match[0]);
                        extractedEvents = parsedData.events || [];
                        invalidExistingIds = parsedData.invalid_existing_ids || [];
                        functions.logger.info(`[${traceId}] Successfully parsed JSON using regex fallback.`);
                    } else {
                        throw new Error("Regex fallback failed to find a valid JSON object.");
                    }
                } catch (fallbackError) {
                    functions.logger.error(`[${traceId}] Failed to parse JSON object from response.`, { text: response.text });
                    throw new Error("Failed to parse JSON object from response: " + (fallbackError instanceof Error ? fallbackError.message : String(fallbackError)));
                }
            }
            await writeDebugLog(traceId, `Gemini Response for ${gameName}`, { text: response.text });


        } else {
            throw new Error("Gemini response text was empty.");
        }

        let totalTokens = response.usageMetadata?.totalTokenCount || 0;

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
            // パージ処理 (Liveness Audit)
            if (invalidExistingIds.length > 0) {
                functions.logger.info(`[${traceId}] Purging ${invalidExistingIds.length} invalid existing events for ${gameName}`);
                for (const docId of invalidExistingIds) {
                    if (docId) {
                        const existingDoc = currentEventsList.find(e => e.docId === docId);
                        if (existingDoc) {
                            const eData = existingDoc.data;
                            // 保護されているイベントは削除しない
                            if (eData.isCycleEvent === true || eData.isLocked === true || eData.isUpdateLocked === true || eData.isCreationLocked === true) {
                                continue;
                            }
                            batch.delete(eventsCollection.doc(docId));
                            batchCount++;
                            deletedCount++;
                            await commitBatchIfNeeded();
                            functions.logger.info(`[${traceId}] Purged invalid event: ${docId}`);
                        }
                    }
                }
            }

        if (Array.isArray(extractedEvents) && extractedEvents.length > 0) {
            const matchedDocIds = new Set<string>();

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
                    if (event.rewards && event.rewards.length > 0) {
                        existing.rewards = event.rewards;
                    }
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
                        if (e.data.title && event.title && calculateSimilarity(normalizeString(e.data.title), normalizeString(event.title)) >= 0.85) return true;
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

                    const newRewardsStr = Array.isArray(event.rewards) ? JSON.stringify(event.rewards) : '';
                    const oldRewardsStr = Array.isArray(eData.rewards) ? JSON.stringify(eData.rewards) : '';
                    if (event.rewards && newRewardsStr !== oldRewardsStr) {
                        changes.push('報酬');
                    }

                    if (changes.length === 0) {
                        unchangedCount++;
                        continue;
                    }

                    const updateData: any = {
                        title: newTitle,
                        summary: event.summary || eData.summary,
                        startDate: formattedStart || null,
                        endDate: formattedEnd || null,
                        redeemCode: event.redeemCode || eData.redeemCode || null,
                        eventUrl: event.eventUrl || eData.eventUrl || null,
                        tag: event.tag || eData.tag || null,
                        rewards: (event.rewards && event.rewards.length > 0) ? event.rewards : (eData.rewards || []),
                        isCustomGame: isCustomGame ? true : admin.firestore.FieldValue.delete(),
                        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                    };

                    if (!(changes.length === 1 && changes[0] === '概要')) {
                        const historyMsg = `[${currentDate}] 自動同期: 変更あり（${changes.join(', ')}）`;
                        updateData.updateHistory = admin.firestore.FieldValue.arrayUnion(historyMsg);
                    }

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

                        const newRewardsStr = Array.isArray(event.rewards) ? JSON.stringify(event.rewards) : '';
                        const oldRewardsStr = Array.isArray(eData.rewards) ? JSON.stringify(eData.rewards) : '';
                        if (event.rewards && newRewardsStr !== oldRewardsStr) {
                            changes.push('報酬');
                        }

                        if (changes.length === 0) {
                            unchangedCount++;
                            continue;
                        }

                        const updateData: any = {
                            title: newTitle,
                            summary: event.summary || eData.summary,
                            startDate: formattedStart || null,
                            endDate: formattedEnd || null,
                            redeemCode: event.redeemCode || eData.redeemCode || null,
                            eventUrl: event.eventUrl || eData.eventUrl || null,
                            tag: event.tag || eData.tag || null,
                            rewards: (event.rewards && event.rewards.length > 0) ? event.rewards : (eData.rewards || []),
                            isCustomGame: isCustomGame ? true : admin.firestore.FieldValue.delete(),
                            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                        };

                        if (!(changes.length === 1 && changes[0] === '概要')) {
                            const historyMsg = `[${currentDate}] 自動同期: 変更あり（${changes.join(', ')}）`;
                            updateData.updateHistory = admin.firestore.FieldValue.arrayUnion(historyMsg);
                        }

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
                            ...(isCustomGame ? { isCustomGame: true } : {}),
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
                        if (endDateObj && endDateObj.getTime() < nowMs) {
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

                    const newCompletedTasks = (docData.completedTasks || 0) + 1;
                    const totalTasks = docData.totalTasks || 0;

                    const updateData: any = {
                        totalTokens: newTotalTokens,
                        completedTasks: newCompletedTasks,
                        debugInfo: admin.firestore.FieldValue.arrayUnion(newDebugInfo),
                        updatedAt: admin.firestore.FieldValue.serverTimestamp()
                    };

                    if (totalTasks > 0 && newCompletedTasks >= totalTasks) {
                        updateData.status = 'completed';
                    }

                    t.update(syncRequestRef, updateData);
                }
            });

            const updatedDoc = await syncRequestRef.get();
            const uData = updatedDoc.data();
            if (uData && uData.status === 'completed') {
                 await writeDebugLog(traceId, 'All tasks completed successfully.', { requestId });
            }

        } else {
             const syncRequestRef = db.collection('sync_requests').doc(requestId);
             await db.runTransaction(async (t) => {
                 const doc = await t.get(syncRequestRef);
                 if (doc.exists) {
                     const docData = doc.data()!;
                     const newCompletedTasks = (docData.completedTasks || 0) + 1;
                     const totalTasks = docData.totalTasks || 0;

                     const updateData: any = {
                         completedTasks: newCompletedTasks,
                         debugInfo: admin.firestore.FieldValue.arrayUnion({ stage: 'Processed', game: gameName, message: 'No events found' }),
                         updatedAt: admin.firestore.FieldValue.serverTimestamp()
                     };

                     if (totalTasks > 0 && newCompletedTasks >= totalTasks) {
                         updateData.status = 'completed';
                     }

                     t.update(syncRequestRef, updateData);
                 }
             });

             const updatedDoc = await syncRequestRef.get();
             const uData = updatedDoc.data();
             if (uData && uData.status === 'completed') {
                  await writeDebugLog(traceId, 'All tasks completed successfully.', { requestId });
             }
        }
    } catch (error) {
        functions.logger.error(`[${traceId}] Error processing ${gameName}: ${error}`);
        const syncRequestRef = db.collection('sync_requests').doc(requestId);

        await db.runTransaction(async (t) => {
             const doc = await t.get(syncRequestRef);
             if (doc.exists) {
                 const docData = doc.data()!;
                 const newCompletedTasks = (docData.completedTasks || 0) + 1;
                 const totalTasks = docData.totalTasks || 0;

                 const updateData: any = {
                     completedTasks: newCompletedTasks,
                     debugInfo: admin.firestore.FieldValue.arrayUnion({ stage: 'Error', game: gameName, error: error instanceof Error ? error.message : String(error) }),
                     updatedAt: admin.firestore.FieldValue.serverTimestamp()
                 };

                 if (totalTasks > 0 && newCompletedTasks >= totalTasks) {
                     updateData.status = 'completed';
                 }

                 t.update(syncRequestRef, updateData);
             }
        });

        throw error;
    }
});


export const triggerScheduledNotifications = functions.region('asia-northeast1').https.onRequest(async (req, res) => {
    try {
        const result = await performSendNotifications();
        res.status(200).send('Scheduled notifications completed: ' + result.message);
    } catch (error: any) {
        functions.logger.error('Error triggering scheduled notifications', error);
        res.status(500).send('Internal Server Error');
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

export const updateNotificationSchedule = onDocumentWritten({ document: 'settings/notification_config', database: 'default', region: 'asia-northeast1' }, async (event) => {
    const traceId = 'sched-notify-upd-' + Date.now();
    functions.logger.info(`[${traceId}] updateNotificationSchedule triggered`, { traceId });

    const afterData = event.data?.after?.data();

    const projectId = process.env.GCLOUD_PROJECT || process.env.GOOGLE_CLOUD_PROJECT || 'game-tracker-444b2';
    const locationId = 'asia-northeast1';
    const client = new CloudSchedulerClient();
    const parent = client.locationPath(projectId, locationId);

    const functionUrl = `https://${locationId}-${projectId}.cloudfunctions.net/triggerScheduledNotifications`;

    try {
        let existingJobs: any[] = [];
        try {
            const [jobs] = await client.listJobs({ parent });
            existingJobs = jobs.filter(job => job.name?.includes('/jobs/notify-job-') || job.name?.endsWith('/jobs/notify-job'));
        } catch (listError: any) {
            functions.logger.warn(`[${traceId}] Could not list jobs: ${listError.message}`);
        }

        const isPaused = afterData?.is_paused === true;

        let scanTimes: string[] = [];
        if (afterData?.scan_times && Array.isArray(afterData.scan_times)) {
            scanTimes = afterData.scan_times;
        } else if (afterData?.cron_schedule) {
            const parts = (afterData.cron_schedule as string).split(' ');
            if (parts.length >= 2) {
                 const minute = parts[0].padStart(2, '0');
                 const hour = parts[1].padStart(2, '0');
                 scanTimes.push(`${hour}:${minute}`);
            }
        }

        if (isPaused || scanTimes.length === 0) {
            for (const job of existingJobs) {
                if (job.name) {
                    await client.deleteJob({ name: job.name });
                    functions.logger.info(`[${traceId}] Cloud Scheduler job deleted: ${job.name}`);
                }
            }
            await writeDebugLog(traceId, isPaused ? 'All Notification Cloud Scheduler jobs deleted (Paused).' : 'All Notification Cloud Scheduler jobs deleted (No times set).');
            return;
        }

        const activeJobNames = new Set<string>();

        for (const timeStr of scanTimes) {
            const parts = timeStr.split(':');
            if (parts.length !== 2) continue;

            const hour = parts[0];
            const minute = parts[1];

            const cronSchedule = `${parseInt(minute)} ${parseInt(hour)} * * *`;
            const jobId = `notify-job-${hour}-${minute}`;
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
                await client.updateJob({
                    job,
                    updateMask: { paths: ['schedule', 'http_target.uri'] }
                });
                functions.logger.info(`[${traceId}] Notification Cloud Scheduler job updated: ${name}`);
            } else {
                try {
                    await client.createJob({
                        parent,
                        job
                    });
                    functions.logger.info(`[${traceId}] Notification Cloud Scheduler job created: ${name}`);
                } catch (createErr: any) {
                    if (createErr.code === 6) {
                        await client.updateJob({
                            job,
                            updateMask: { paths: ['schedule', 'http_target.uri'] }
                        });
                        functions.logger.info(`[${traceId}] Notification Cloud Scheduler job updated (already exists): ${name}`);
                    } else {
                        throw createErr;
                    }
                }
            }
        }

        for (const job of existingJobs) {
            if (job.name && !activeJobNames.has(job.name)) {
                await client.deleteJob({ name: job.name });
                functions.logger.info(`[${traceId}] Notification Cloud Scheduler job deleted: ${job.name}`);
            }
        }

        await writeDebugLog(traceId, `Notification Cloud Scheduler jobs updated successfully. Active jobs: ${activeJobNames.size}`);
    } catch (error: any) {
        functions.logger.error(`[${traceId}] Failed to update Notification Cloud Scheduler jobs`, error);
        await writeDebugLog(traceId, 'Failed to update Notification Cloud Scheduler jobs', error instanceof Error ? error.stack : String(error));
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
export const clearAllEvents = functions.region('asia-northeast1').runWith({ memory: '512MB', timeoutSeconds: 300 }).https.onCall(async (data, context) => {
    try {
        let totalDeleted = 0;
        let lastDoc: admin.firestore.QueryDocumentSnapshot | undefined = undefined;

        while (true) {
            let query = db.collectionGroup('events').limit(450);

            if (lastDoc) {
                query = query.startAfter(lastDoc);
            }
            const snapshot = await query.get();
            if (snapshot.empty) break;

            const bulkWriter = db.bulkWriter();
            let deletedInBatch = 0;
            snapshot.docs.forEach((doc) => {
                const docData = doc.data();
                // isLocked, isCreationLocked, isUpdateLocked, isCycleEventをチェックして手動イベントを保護
                if (docData.isCycleEvent === true || docData.isLocked === true || docData.isCreationLocked === true || docData.isUpdateLocked === true) {
                    return;
                }
                bulkWriter.delete(doc.ref);
                deletedInBatch++;
            });

            await bulkWriter.close();
            totalDeleted += deletedInBatch;
            lastDoc = snapshot.docs[snapshot.docs.length - 1] as admin.firestore.QueryDocumentSnapshot;
        }

        functions.logger.info(`Successfully deleted ${totalDeleted} non-manual/non-cycle events from all games.`);
        return { success: true, deletedCount: totalDeleted };
    } catch (error) {
        functions.logger.error('Error clearing events from Firestore:', error instanceof Error ? error.stack : String(error));
        throw new functions.https.HttpsError('internal', 'Unable to clear events due to internal error', error);
    }
});

// Google Driveへのエクスポート処理

async function performExportToDrive(folderId: string, traceId: string): Promise<{ fileId: string, exportedCount: number }> {
    functions.logger.info(`[${traceId}] Starting performExportToDrive to folder: ${folderId}`);
    await writeDebugLog(traceId, `Starting export to Google Drive. Folder ID: ${folderId}`);

    const fileName = 'events_export.json';
    const passThrough = new PassThrough();
    let exportedCount = 0;

    // Use a Promise to properly handle the stream
    const uploadPromise = new Promise<{ fileId: string, exportedCount: number }>(async (resolve, reject) => {
        try {
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

            let fileIdToUpdate;
            if (existingFile) {
                fileIdToUpdate = existingFile.id!;
            } else {
                const errorMsg = `Target file '${fileName}' not found. Recognized files: ${JSON.stringify(allFiles)}`;
                functions.logger.error(`[${traceId}] ${errorMsg}`);
                await writeDebugLog(traceId, errorMsg);
                return reject(new functions.https.HttpsError('not-found', `ダミーファイル(${fileName})が見つかりません。ドライブに空のファイルを手動で作成してください。`));
            }

            const media = {
                mimeType: 'application/json',
                body: passThrough
            };

            // Start uploading in the background
            const updatePromise = drive.files.update({
                fileId: fileIdToUpdate,
                media: media
            });

            // Feed data to the stream
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

            // Wait for the upload to finish
            const updateRes = await updatePromise;

            functions.logger.info(`[${traceId}] Updating existing file: ${fileIdToUpdate}`);
            await writeDebugLog(traceId, `Updated existing file in Drive. File ID: ${fileIdToUpdate}`);

            resolve({ fileId: updateRes.data.id!, exportedCount });
        } catch (error: any) {
            functions.logger.error(`[${traceId}] Stream error in exportToDrive`, error);
            passThrough.destroy(error as Error);
            reject(error);
        }
    });

    return uploadPromise;
}



export const updateExportSchedule = onDocumentWritten({ document: 'settings/export_config', database: 'default', region: 'asia-northeast1' }, async (event) => {
    const traceId = 'export-sched-upd-' + Date.now();
    functions.logger.info(`[${traceId}] updateExportSchedule triggered`, { traceId });

    const afterData = event.data?.after?.data();

    const projectId = process.env.GCLOUD_PROJECT || process.env.GOOGLE_CLOUD_PROJECT || 'game-tracker-444b2'; // Fallback to project ID
    const locationId = 'asia-northeast1';
    const client = new CloudSchedulerClient();
    const parent = client.locationPath(projectId, locationId);

    // Get the Cloud Function URL dynamically or construct it
    const functionUrl = `https://${locationId}-${projectId}.cloudfunctions.net/triggerScheduledExport`;

    try {
        // Fetch existing jobs to delete old ones
        let existingJobs: any[] = [];
        try {
            const [jobs] = await client.listJobs({ parent });
            existingJobs = jobs.filter(job => job.name?.includes('/jobs/export-job-') || job.name?.endsWith('/jobs/export-job'));
        } catch (listError: any) {
            functions.logger.warn(`[${traceId}] Could not list export jobs (might not exist yet): ${listError.message}`);
        }

        let exportTimes: string[] = [];
        if (afterData?.export_times && Array.isArray(afterData.export_times)) {
            exportTimes = afterData.export_times;
        }

        if (exportTimes.length === 0) {
            // Delete all jobs
            for (const job of existingJobs) {
                if (job.name) {
                    await client.deleteJob({ name: job.name });
                    functions.logger.info(`[${traceId}] Cloud Scheduler job deleted: ${job.name}`);
                }
            }
            await writeDebugLog(traceId, 'All Cloud Scheduler export jobs deleted (No times set).');
            return;
        }

        const activeJobNames = new Set<string>();

        // Create or update required jobs
        for (const timeStr of exportTimes) {
            const parts = timeStr.split(':');
            if (parts.length !== 2) continue;

            const hour = parts[0];
            const minute = parts[1];

            const cronSchedule = `${parseInt(minute)} ${parseInt(hour)} * * *`;
            const jobId = `export-job-${hour}-${minute}`;
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
                        functions.logger.info(`[${traceId}] Cloud Scheduler export job already exists, updated: ${name} with schedule: ${cronSchedule}`);
                    } else {
                        throw createErr;
                    }
                }
            }
        }

        // Delete obsolete jobs
        for (const job of existingJobs) {
            if (job.name && !activeJobNames.has(job.name)) {
                await client.deleteJob({ name: job.name });
                functions.logger.info(`[${traceId}] Obsolete Cloud Scheduler export job deleted: ${job.name}`);
            }
        }

        await writeDebugLog(traceId, 'Export schedule updated successfully.', { times: exportTimes });

    } catch (error: any) {
         functions.logger.error(`[${traceId}] Failed to update export schedule`, { error: error.message, stack: error instanceof Error ? error.stack : String(error) });
         await writeDebugLog(traceId, 'Failed to update export schedule', error instanceof Error ? error.stack : String(error));
    }
});

export const triggerScheduledExport = functions.region('asia-northeast1').runWith({ memory: '512MB', timeoutSeconds: 300 }).https.onRequest(async (req, res) => {
    const traceId = 'sched-export-' + Date.now();
    functions.logger.info(`[${traceId}] triggerScheduledExport started`);

    try {
        const configDoc = await db.collection('settings').doc('export_config').get();
        const folderId = configDoc.data()?.folder_id;

        if (!folderId) {
            functions.logger.warn(`[${traceId}] folder_id is not set in settings/export_config`);
            res.status(200).send('Skipped: folder_id not set');
            return;
        }

        const { fileId, exportedCount } = await performExportToDrive(folderId, traceId);

        functions.logger.info(`[${traceId}] Scheduled export completed. File ID: ${fileId}, Count: ${exportedCount}`);
        await writeDebugLog(traceId, 'Scheduled export completed successfully', { fileId, exportedCount });

        res.status(200).send('Scheduled export completed');
    } catch (error: any) {
        functions.logger.error(`[${traceId}] Failed to execute scheduled export`, { error: error.message, stack: error instanceof Error ? error.stack : String(error) });
        await writeDebugLog(traceId, 'Failed to execute scheduled export', error instanceof Error ? error.stack : String(error));
        res.status(500).send('Internal Server Error');
    }
});

export const exportToDrive = functions.region('asia-northeast1').runWith({ memory: '512MB', timeoutSeconds: 300 }).https.onCall(async (data, context) => {
    const traceId = 'export-' + Date.now() + '-' + Math.floor(Math.random() * 10000);
    const folderId = data.folderId;

    if (!folderId) {
        throw new functions.https.HttpsError('invalid-argument', 'folderId is required');
    }

    try {
        const { fileId, exportedCount } = await performExportToDrive(folderId, traceId);
        functions.logger.info(`[${traceId}] Export completed successfully. File ID: ${fileId}`);
        return {
            success: true,
            message: 'Export successful',
            fileId: fileId,
            exportedCount: exportedCount
        };
    } catch (error: any) {
         functions.logger.error(`[${traceId}] Export failed: ${error.message}`, { stack: error instanceof Error ? error.stack : String(error) });
         await writeDebugLog(traceId, 'Export failed', error instanceof Error ? error.stack : String(error));
         if (error instanceof functions.https.HttpsError) {
             throw error;
         }
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
        const now = dayjs().tz('Asia/Tokyo');

        const eventsSnapshot = await db.collectionGroup('events').select('endDate', 'isCycleEvent', 'cycleType', 'cycleSettings', 'tasks', 'updateHistory').get();

        if (eventsSnapshot.empty) {
            functions.logger.info(`[${traceId}] No events found`);
            return;
        }

        const uniqueDocs = eventsSnapshot.docs;

        let currentEventsList = uniqueDocs.map(doc => ({ docId: doc.id, data: doc.data(), ref: doc.ref }));
        currentEventsList = await cleanupDuplicateEvents(currentEventsList, db);

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
                    await currentBatch.commit();
                    currentBatch = db.batch();
                    opCount = 0;
                }
            }
        }

        if (opCount > 0) {
            await currentBatch.commit();
        }

        functions.logger.info(`[${traceId}] Successfully reset ${totalUpdated} cycle events and deleted ${totalDeleted} expired normal events.`);
        if (totalUpdated > 0 || totalDeleted > 0) {
            await writeDebugLog(traceId, `Successfully reset ${totalUpdated} cycle events and deleted ${totalDeleted} expired normal events.`);
        }

        // Clean up debug_logs older than 7 days
        const sevenDaysAgo = admin.firestore.Timestamp.fromDate(new Date(Date.now() - 7 * 24 * 60 * 60 * 1000));
        const oldLogsSnapshot = await db.collection('debug_logs').where('timestamp', '<', sevenDaysAgo).get();

        let deletedLogsCount = 0;
        if (!oldLogsSnapshot.empty) {
            let logBatch = db.batch();
            let logOpCount = 0;

            for (const logDoc of oldLogsSnapshot.docs) {
                logBatch.delete(logDoc.ref);
                logOpCount++;
                deletedLogsCount++;

                if (logOpCount === 450) {
                    await logBatch.commit();
                    logBatch = db.batch();
                    logOpCount = 0;
                }
            }

            if (logOpCount > 0) {
                await logBatch.commit();
            }
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
    const ADMIN_SECRET = process.env.ADMIN_SECRET;
    if (!ADMIN_SECRET) {
        functions.logger.error('ADMIN_SECRET environment variable is not set. Denying admin role.');
        throw new functions.https.HttpsError('internal', 'Server configuration error.');
    }

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

export const sendScheduledNotifications = functions.region('asia-northeast1').pubsub.schedule('0 * * * *').timeZone('Asia/Tokyo').onRun(async (context) => {
    const traceId = 'notify-' + Date.now();
    const now = dayjs().tz('Asia/Tokyo');
    const currentHour = now.hour();

    try {
        await writeDebugLog(traceId, `Starting scheduled notifications at hour ${currentHour}`);

        // Find users who have notifications enabled for this hour
        const usersSnapshot = await db.collection('users').get();
        const targetUsers = usersSnapshot.docs.filter(doc => {
            const data = doc.data();
            const settings = data.settings;
            const token = data.fcmToken || settings?.fcmToken;
            return settings &&
                   settings.notificationEnabled === true &&
                   settings.notificationHour === currentHour &&
                   token;
        });

        if (targetUsers.length === 0) {
            functions.logger.info(`[${traceId}] No users configured for notifications at hour ${currentHour}`);
            await writeDebugLog(traceId, `No users configured for notifications at hour ${currentHour}`);
            return;
        }

        await writeDebugLog(traceId, `Found ${targetUsers.length} users with notifications enabled for this hour`);

        // Fetch all events
        const nowDay = now.startOf('day');

        // Firestoreクエリ側で事前に不要なドキュメントを除外しOOMリスクを軽減する
        // endDateはTimestamp型とString型が混在している可能性があるため、両方のクエリを発行する
        // To avoid string date comparison lexicographical flaws and OOM, query all events but with select projection.
        const eventsSnapshot = await db.collectionGroup('events').get();
        const combinedDocs = eventsSnapshot.docs;

        const uniqueDocs = combinedDocs;

        const allEvents = uniqueDocs.map(doc => ({ id: doc.id, ...doc.data() as any })).filter(event => {
            if (event.isCompleted) return false;
            if (event.isDeleted === true) return false;

            let endDateObj = event.endDate;
            if (endDateObj && typeof endDateObj.toDate === 'function') {
                endDateObj = endDateObj.toDate();
            } else if (typeof endDateObj === 'string') {
                endDateObj = new Date(endDateObj);
            }
            if (!endDateObj) return false;

            const eventDateDay = dayjs(endDateObj).tz('Asia/Tokyo').startOf('day');
            if (eventDateDay.diff(nowDay, 'day') < 0) return false;

            event.diffDays = eventDateDay.diff(nowDay, 'day');
            return true;
        });

        // Send notifications
        let successfulCount = 0;
        let failedCount = 0;

        for (const userDoc of targetUsers) {
            const userData = userDoc.data();
            const token = userData.fcmToken || userData.settings?.fcmToken;
            const checkedEvents: string[] = userData.checkedEvents || [];
            const daysBefore = userData.settings?.notificationDaysBefore ?? 7;

            let completedSkipped = 0;
            let deletedSkipped = 0;
            let noEndDateSkipped = 0;
            let checkedSkipped = 0;
            let pastSkipped = 0;
            let futureSkipped = 0;

            const userUncompletedEvents = allEvents.filter(event => {
                if (checkedEvents.includes(event.id)) { checkedSkipped++; return false; }
                if (event.diffDays > daysBefore) { futureSkipped++; return false; }
                return true;
            });

            await writeDebugLog(traceId, 'Filter breakdown', `Total: ${allEvents.length}, Checked: ${checkedSkipped}, Past: ${pastSkipped}, Future: ${futureSkipped}, NoDate: ${noEndDateSkipped}, Completed: ${completedSkipped}, Deleted: ${deletedSkipped}, Matched: ${userUncompletedEvents.length}`);

            if (userUncompletedEvents.length > 0) {
                const title = '未完了のイベントがあります';
                const deadlineText = daysBefore === 0 ? '当日期限' : `${daysBefore}日以内`;
                const body = `設定した期限（${deadlineText}）の未完了イベントが${userUncompletedEvents.length}件あります。`;
                const msg: any = {
                    token: token,
                    notification: {
                        title: title,
                        body: body
                    },
                    data: {
                        title: title,
                        body: body
                    },
                    android: {
                        priority: 'high'
                    }
                };

                try {
                    await admin.messaging().send(msg);
                    successfulCount++;
                } catch (e: any) {
                    functions.logger.error(`[${traceId}] Failed to send message to user ${userDoc.id}:`, e);
                    await writeDebugLog(traceId, `Failed to send message to user ${userDoc.id}`, e instanceof Error ? e.stack : String(e));
                    failedCount++;
                }
            } else {
                 await writeDebugLog(traceId, `No uncompleted events in the range for user ${userDoc.id}`);
            }
        }

        functions.logger.info(`[${traceId}] Sent ${successfulCount} notifications successfully, ${failedCount} failed.`);
        await writeDebugLog(traceId, `Completed notification run. Success: ${successfulCount}, Failed: ${failedCount}`);

    } catch (error: any) {
        functions.logger.error(`[${traceId}] Error in sendScheduledNotifications:`, error);
        await writeDebugLog(traceId, 'Error in sendScheduledNotifications', error instanceof Error ? error.stack : String(error));
    }
});

async function performSendNotifications(targetUid?: string): Promise<{ success: boolean, message: string }> {
    const traceId = (targetUid ? 'test-' : 'sched-') + 'notify-' + Date.now();
    const now = dayjs().tz('Asia/Tokyo');

    try {
        await writeDebugLog(traceId, `Starting notifications run for ${targetUid ? 'user ' + targetUid : 'all eligible users'}`);

        let targetUsers: any[] = [];

        if (targetUid) {
            const userDoc = await db.collection('users').doc(targetUid).get();
            if (!userDoc.exists) {
                await writeDebugLog(traceId, `User doc not found for uid ${targetUid}`);
                throw new functions.https.HttpsError('not-found', 'User data not found.');
            }
            const userData = userDoc.data() as any;
            const settings = userData.settings;
            const token = userData.fcmToken || settings?.fcmToken;

            if (!settings || settings.notificationEnabled !== true || !token) {
                const msg = 'Notification is disabled or FCM token is missing for this user.';
                await writeDebugLog(traceId, msg);
                throw new functions.https.HttpsError('failed-precondition', msg);
            }
            targetUsers.push(userDoc);
        } else {
            const usersSnapshot = await db.collection('users').get();
            targetUsers = usersSnapshot.docs.filter(doc => {
                const data = doc.data();
                const settings = data.settings;
                const token = data.fcmToken || settings?.fcmToken;
                return settings &&
                       settings.notificationEnabled === true &&
                       token;
            });
            if (targetUsers.length === 0) {
                await writeDebugLog(traceId, 'No users configured for notifications');
                return { success: true, message: '通知対象のユーザーがいません' };
            }
        }

        await writeDebugLog(traceId, `Proceeding to fetch events for ${targetUsers.length} users...`);

        // Fetch all events
        const nowDay = now.startOf('day');

        // Firestoreクエリ側で事前に不要なドキュメントを除外しOOMリスクを軽減する
        // endDateはTimestamp型とString型が混在している可能性があるため、両方のクエリを発行する
        // To avoid string date comparison lexicographical flaws and OOM, query all events but with select projection.
        const eventsSnapshot = await db.collectionGroup('events').get();
        const combinedDocs = eventsSnapshot.docs;

        const uniqueDocs = combinedDocs;

        const allEvents = uniqueDocs.map(doc => ({ id: doc.id, ...doc.data() as any })).filter(event => {
            if (event.isCompleted) return false;
            if (event.isDeleted === true) return false;

            let endDateObj = event.endDate;
            if (endDateObj && typeof endDateObj.toDate === 'function') {
                endDateObj = endDateObj.toDate();
            } else if (typeof endDateObj === 'string') {
                endDateObj = new Date(endDateObj);
            }
            if (!endDateObj) return false;

            const eventDateDay = dayjs(endDateObj).tz('Asia/Tokyo').startOf('day');
            if (eventDateDay.diff(nowDay, 'day') < 0) return false;

            event.diffDays = eventDateDay.diff(nowDay, 'day');

            return true;
        });

        let successfulCount = 0;
        let failedCount = 0;
        let totalMatchedEvents = 0;

        for (const userDoc of targetUsers) {
            const userData = userDoc.data() as any;
            const token = userData.fcmToken || userData.settings?.fcmToken;
            const checkedEvents: string[] = userData.checkedEvents || [];
            const daysBefore = userData.settings?.notificationDaysBefore ?? 7;

            let completedSkipped = 0;
            let deletedSkipped = 0;
            let noEndDateSkipped = 0;
            let checkedSkipped = 0;
            let pastSkipped = 0;
            let futureSkipped = 0;

            const userUncompletedEvents = allEvents.filter(event => {
                if (checkedEvents.includes(event.id)) { checkedSkipped++; return false; }
                if (event.diffDays > daysBefore) { futureSkipped++; return false; }
                return true;
            });

            await writeDebugLog(traceId, `Filter breakdown for ${userDoc.id}`, `Total: ${allEvents.length}, Checked: ${checkedSkipped}, Past: ${pastSkipped}, Future: ${futureSkipped}, NoDate: ${noEndDateSkipped}, Completed: ${completedSkipped}, Deleted: ${deletedSkipped}, Matched: ${userUncompletedEvents.length}`);

            if (userUncompletedEvents.length > 0) {
                totalMatchedEvents += userUncompletedEvents.length;
                const title = '未完了のイベントがあります';
                const prefix = targetUid ? '[手動テスト] ' : '';
                const deadlineText = daysBefore === 0 ? '当日期限' : `${daysBefore}日以内`;
                const body = `${prefix}設定した期限（${deadlineText}）の未完了イベントが${userUncompletedEvents.length}件あります。`;
                const msg: any = {
                    token: token,
                    notification: {
                        title: title,
                        body: body
                    },
                    data: {
                        title: title,
                        body: body
                    },
                    android: {
                        priority: 'high'
                    }
                };

                try {
                    await admin.messaging().send(msg);
                    successfulCount++;
                } catch (e: any) {
                    functions.logger.error(`[${traceId}] Failed to send message to user ${userDoc.id}:`, e);
                    await writeDebugLog(traceId, `Failed to send message to user ${userDoc.id}`, e instanceof Error ? e.stack : String(e));
                    failedCount++;
                    if (targetUid) {
                        throw new functions.https.HttpsError('internal', '通知の送信に失敗しました。詳細エラーはデバッグログを確認してください。');
                    }
                }
            } else {
                 await writeDebugLog(traceId, `No uncompleted events in the range for user ${userDoc.id}`);
            }
        }

        if (targetUid) {
            if (successfulCount > 0) {
                await writeDebugLog(traceId, `Successfully sent test notification to user ${targetUid}`);
                return { success: true, message: `プッシュ通知を送信しました (対象: ${totalMatchedEvents}件)` };
            } else {
                return { success: true, message: '通知対象の未完了イベントが0件でした (条件外または全て完了済み)' };
            }
        } else {
            await writeDebugLog(traceId, `Completed scheduled notification run. Success: ${successfulCount}, Failed: ${failedCount}`);
            return { success: true, message: `Scheduled notifications completed. Success: ${successfulCount}, Failed: ${failedCount}` };
        }

    } catch (error: any) {
        functions.logger.error(`[${traceId}] Error in performSendNotifications:`, error);
        await writeDebugLog(traceId, 'Error in performSendNotifications', error instanceof Error ? error.stack : String(error));

        if (error instanceof functions.https.HttpsError) {
            throw error;
        }
        throw new functions.https.HttpsError('internal', error.message || '内部エラーが発生しました');
    }
}

export const testSendNotifications = functions.region('asia-northeast1').runWith({ memory: '256MB', timeoutSeconds: 300 }).https.onCall(async (data, context) => {
    if (!context.auth) {
        throw new functions.https.HttpsError('unauthenticated', 'User not authenticated');
    }
    return await performSendNotifications(context.auth.uid);
});

export const executeManualPrompt = functions.region('asia-northeast1').runWith({ memory: '256MB', timeoutSeconds: 300 }).https.onCall(async (data, context) => {
    if (!context.auth) {
        throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated.');
    }
    if (context.auth.token.admin !== true) {
        throw new functions.https.HttpsError('permission-denied', 'Only admins can execute this prompt.');
    }

    const { prompt } = data;
    if (!prompt) {
        throw new functions.https.HttpsError('invalid-argument', 'Prompt is required.');
    }

    const traceId = 'manual-prompt-' + Date.now();
    await writeDebugLog(traceId, 'executeManualPrompt called', { prompt });

    try {
        const configDoc = await db.collection('settings').doc('config').get();
        const configData = configDoc?.data();
        const geminiApiKey = configData?.geminiApiKey;

        if (!geminiApiKey) {
            throw new Error('Gemini API key is missing');
        }

        const ai = new GoogleGenAI({ apiKey: geminiApiKey.trim() });

        const systemInstruction = `
あなたはデータベース修正用APIです。与えられた「修正指示プロンプト」を解析し、以下のJSONスキーマに従って出力してください。
必ずJSONのみを出力してください（バッククォートでの修飾は可）。

{
  "operations": [
    {
      "gameId": "ゲームID",
      "operation": "update | delete | add",
      "eventId": "イベントID（update/deleteの場合は必須）",
      "updates": {
        "title": "タイトル（変更がある場合のみ）",
        "endDate": "YYYY-MM-DD（変更がある場合のみ）",
        "startDate": "YYYY-MM-DD（変更がある場合のみ）",
        "rewards": ["報酬1", "報酬2"]
      },
      "reason": "変更理由"
    }
  ],
  "message": "完了後の話し言葉での結果報告"
}
`;

        const generationConfig = {
            temperature: 0.1,
            responseMimeType: "application/json",
        };

        const response = await ai.models.generateContent({
            model: 'gemini-2.5-flash',
            contents: [{ role: 'user', parts: [{ text: systemInstruction + '\n\n【修正指示プロンプト】\n' + prompt }] }],
            config: generationConfig,
        });

        const text = response.text || '';
        let parsedData: any;
        try {
            const cleanText = text.replace(/```json/gi, '').replace(/```/gi, '').trim();
            parsedData = JSON.parse(cleanText);
        } catch (err) {
            functions.logger.warn(`[${traceId}] Failed to parse JSON via normal method. Attempting regex fallback...`);
            const match = text.match(/\{[\s\S]*\}/);
            if (match) {
                try {
                    parsedData = JSON.parse(match[0]);
                    functions.logger.info(`[${traceId}] Successfully parsed JSON using regex fallback.`);
                } catch (fallbackErr) {
                    functions.logger.error(`[${traceId}] Regex fallback parsing failed. Text: ${text}`);
                    throw new Error('Failed to parse JSON from Gemini response using fallback: ' + text);
                }
            } else {
                throw new Error('Failed to parse JSON from Gemini response: ' + text);
            }
        }

        if (!parsedData || !Array.isArray(parsedData.operations)) {
            throw new Error('Invalid response format from Gemini.');
        }

        const operations = parsedData.operations;
        let appliedCount = 0;

        for (const op of operations) {
            const gameId = op.gameId;
            const eventId = op.eventId;
            const updates = op.updates || {};

            if (!gameId) continue;

            const eventsCol = db.collection(`games/${gameId}/events`);

            if (op.operation === 'delete') {
                if (!eventId) continue;
                await eventsCol.doc(eventId).update({ isDeleted: true });
                appliedCount++;
            } else if (op.operation === 'update') {
                if (!eventId) continue;

                const dbUpdates: any = {};
                if (updates.title) dbUpdates.title = updates.title;
                if (updates.endDate) {
                    const dateObj = getSafeDateObj(updates.endDate);
                    if (dateObj) dbUpdates.endDate = admin.firestore.Timestamp.fromDate(dateObj);
                }
                if (updates.startDate) {
                    const dateObj = getSafeDateObj(updates.startDate);
                    if (dateObj) dbUpdates.startDate = admin.firestore.Timestamp.fromDate(dateObj);
                }
                if (op.updates?.rewards) {
                    dbUpdates.rewards = op.updates.rewards;
                }

                if (Object.keys(dbUpdates).length > 0) {
                    dbUpdates.updatedAt = admin.firestore.FieldValue.serverTimestamp();
                    await eventsCol.doc(eventId).update(dbUpdates);
                    appliedCount++;
                }
            } else if (op.operation === 'add') {
                const dbUpdates: any = {};
                if (updates.title) dbUpdates.title = updates.title;
                if (updates.endDate) {
                    const dateObj = getSafeDateObj(updates.endDate);
                    if (dateObj) dbUpdates.endDate = admin.firestore.Timestamp.fromDate(dateObj);
                }
                if (updates.startDate) {
                    const dateObj = getSafeDateObj(updates.startDate);
                    if (dateObj) dbUpdates.startDate = admin.firestore.Timestamp.fromDate(dateObj);
                }
                if (op.updates?.rewards) {
                    dbUpdates.rewards = op.updates.rewards;
                }
                dbUpdates.createdAt = admin.firestore.FieldValue.serverTimestamp();
                dbUpdates.updatedAt = admin.firestore.FieldValue.serverTimestamp();
                dbUpdates.isDeleted = false;

                await eventsCol.add(dbUpdates);
                appliedCount++;
            }
        }

        await writeDebugLog(traceId, 'executeManualPrompt finished', { appliedCount, response: parsedData });

        return {
            success: true,
            message: parsedData.message || `${appliedCount}件の操作を完了しました。`
        };

    } catch (error: any) {
        await writeDebugLog(traceId, 'executeManualPrompt error', { error: error.message });
        throw new functions.https.HttpsError('internal', error.message || 'Unknown error');
    }
});


export const searchIGDBGames = functions.region('asia-northeast1').runWith({ memory: '256MB', timeoutSeconds: 60 }).https.onCall(async (data, context) => {
    if (!context.auth) {
        throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated.');
    }

    const query = data.query;
    if (!query || typeof query !== 'string') {
        throw new functions.https.HttpsError('invalid-argument', 'Query is required.');
    }

    const traceId = 'igdb-search-' + Date.now();
    try {

        const configDoc = await db.collection('settings').doc('config').get();
        const configData = configDoc?.data();
        const clientId = process.env.TWITCH_CLIENT_ID || configData?.twitchClientId;
        const clientSecret = process.env.TWITCH_CLIENT_SECRET || configData?.twitchClientSecret;

        if (!clientId || !clientSecret) {
            functions.logger.error(`[${traceId}] Missing Twitch API credentials.`);
            throw new functions.https.HttpsError('failed-precondition', 'API credentials are not configured.');
        }


        // 1. Get Access Token
        const tokenResponse = await fetch('https://id.twitch.tv/oauth2/token', {
            method: 'POST',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            body: new URLSearchParams({
                'client_id': clientId,
                'client_secret': clientSecret,
                'grant_type': 'client_credentials'
            })
        });

        if (!tokenResponse.ok) {
            functions.logger.error(`[${traceId}] Failed to get Twitch token: ${tokenResponse.status}`);
            return { success: false, message: 'トークンの取得に失敗しました' };
        }

        const tokenData = await tokenResponse.json();
        const accessToken = tokenData.access_token;

        // 2. Search Games via IGDB API
        const escapedQuery = query.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
        const searchResponse = await fetch('https://api.igdb.com/v4/games', {
            method: 'POST',
            headers: {
                'Client-ID': clientId,
                'Authorization': `Bearer ${accessToken}`,
                'Accept': 'application/json',
                'Content-Type': 'text/plain'
            },
            body: `search "${escapedQuery}"; fields name, first_release_date; limit 10;`
        });

        if (!searchResponse.ok) {
            functions.logger.error(`[${traceId}] Failed to search IGDB: ${searchResponse.status}`);
            return { success: false, message: 'ゲームの検索に失敗しました' };
        }

        const games = await searchResponse.json();
        return { success: true, games: games };

    } catch (error: any) {
        functions.logger.error(`[${traceId}] Error in searchIGDBGames: ${error.message}`);
        throw new functions.https.HttpsError('internal', '内部エラーが発生しました', error.message);
    }
});


export const addPremiumCustomGame = functions.region('asia-northeast1').https.onCall(async (data, context) => {
    const uid = context.auth?.uid;
    if (!uid) {
        throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated.');
    }

    const gameName = data.gameName;
    if (!gameName || typeof gameName !== 'string') {
        throw new functions.https.HttpsError('invalid-argument', 'Game name is required.');
    }

    const encodedGameName = encodeURIComponent(gameName.replace(/\//g, '\uff0f'));
    const userRef = db.collection('users').doc(uid);
    const customGameRef = db.collection('premium_custom_games').doc(encodedGameName);

    try {
        await db.runTransaction(async (transaction) => {
            const userDoc = await transaction.get(userRef);
            if (!userDoc.exists) {
                throw new functions.https.HttpsError('not-found', 'User data not found.');
            }

            const userData = userDoc.data();
            if (!userData?.isPremium) {
                throw new functions.https.HttpsError('permission-denied', 'Only premium users can add custom games.');
            }

            const customGames = userData.customGames || [];
            if (customGames.length >= 3) {
                throw new functions.https.HttpsError('resource-exhausted', 'You can register up to 3 custom games.');
            }

            if (customGames.includes(gameName)) {
                throw new functions.https.HttpsError('already-exists', 'Game already registered.');
            }

            transaction.update(userRef, {
                customGames: admin.firestore.FieldValue.arrayUnion(gameName)
            });
            transaction.set(customGameRef, {
                uids: admin.firestore.FieldValue.arrayUnion(uid)
            }, { merge: true });
        });
    } catch (error: any) {
        if (error instanceof functions.https.HttpsError) {
            throw error;
        }
        throw new functions.https.HttpsError('internal', error.message || 'Transaction failed');
    }

    return { success: true, message: 'Game added successfully.' };
});

export const removePremiumCustomGame = functions.region('asia-northeast1').https.onCall(async (data, context) => {
    const uid = context.auth?.uid;
    if (!uid) {
        throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated.');
    }

    const gameName = data.gameName;
    if (!gameName || typeof gameName !== 'string') {
        throw new functions.https.HttpsError('invalid-argument', 'Game name is required.');
    }

    const encodedGameName = encodeURIComponent(gameName.replace(/\//g, '\uff0f'));
    const userRef = db.collection('users').doc(uid);
    const customGameRef = db.collection('premium_custom_games').doc(encodedGameName);

    try {
        await db.runTransaction(async (transaction) => {
            transaction.update(userRef, {
                customGames: admin.firestore.FieldValue.arrayRemove(gameName)
            });
            transaction.set(customGameRef, {
                uids: admin.firestore.FieldValue.arrayRemove(uid)
            }, { merge: true });
        });
    } catch (error: any) {
        if (error instanceof functions.https.HttpsError) {
            throw error;
        }
        throw new functions.https.HttpsError('internal', error.message || 'Transaction failed');
    }

    return { success: true, message: 'Game removed successfully.' };
});
