import * as functions from 'firebase-functions';
import * as admin from 'firebase-admin';
import { getFirestore } from 'firebase-admin/firestore';
import { GoogleGenAI } from '@google/genai';
import axios from 'axios';
import * as cheerio from 'cheerio';

admin.initializeApp();
const db = getFirestore(admin.app(), 'default');

// ユーティリティ: 待機処理（バックオフ用）
const sleep = (ms: number) => new Promise(resolve => setTimeout(resolve, ms));

interface ConfigItem {
    gameName: string;
    url: string;
}

/**
 * 【防御的マージロジック】
 * 新しい値（Stage 2）が真に有効な文字列であるかを検証する。
 * 無効な値（null, undefined, '不明', 'なし' 等のLLMのハルシネーション）であれば古い値（Stage 1）を維持し、データの破壊を完全に防ぐ。
 */
function getValidString(newValue: any, oldValue: any): string | null {
    if (newValue === null || newValue === undefined) return oldValue || null;
    if (typeof newValue === 'string') {
        const trimmed = newValue.trim();
        const invalidKeywords = ['', '不明', 'なし', 'null', 'undefined', 'Unknown Period', '未定', 'Unknown'];
        if (invalidKeywords.includes(trimmed)) {
            return oldValue || null;
        }
        return trimmed;
    }
    return oldValue || null;
}

/**
 * 【JSONサニタイズ処理】
 * LLMが返すレスポンスからMarkdownタグ（```json ... ```）などの不要な装飾を安全に除去し、パースを成功させる。
 */
function sanitizeAndParseJson(rawText: string, traceId: string): any {
    try {
        let cleaned = rawText.replace(/```json/gi, '').replace(/```/g, '').trim();

        // 前後の不要なテキストを切り落とし、純粋なJSONオブジェクトまたは配列領域のみを抽出
        const firstBrace = cleaned.indexOf('{');
        const firstBracket = cleaned.indexOf('[');
        const startIdx = (firstBrace !== -1 && firstBracket !== -1) ? Math.min(firstBrace, firstBracket) : Math.max(firstBrace, firstBracket);

        const lastBrace = cleaned.lastIndexOf('}');
        const lastBracket = cleaned.lastIndexOf(']');
        const endIdx = Math.max(lastBrace, lastBracket);

        if (startIdx !== -1 && endIdx !== -1 && startIdx < endIdx) {
            cleaned = cleaned.substring(startIdx, endIdx + 1);
        }

        return JSON.parse(cleaned);
    } catch (e: any) {
        functions.logger.error(`[${traceId}] Failed to parse JSON from LLM response`, { error: e.message, rawText });
        return null;
    }
}

/**
 * 【耐障害性ロジック】
 * エクスポネンシャル・バックオフとフルジッターを伴う堅牢なHTTPリクエスト処理。
 * 対象サイトからの 500系エラーやタイムアウト時に自動で再試行を行い、システムダウンを回避する。
 */
async function fetchHtmlWithRetry(url: string, baseUrl: string, traceId: string, maxRetries = 3): Promise<string> {
    let attempt = 0;
    const baseDelay = 1500; // 初期待機時間 (1.5秒)

    while (attempt < maxRetries) {
        try {
            const response = await axios.get(url, {
                headers: {
                    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
                },
                timeout: 10000 // 10秒の接続タイムアウト
            });

            const htmlContent = response.data;
            const $ = cheerio.load(htmlContent);

            // <a>タグからリンクを抽出し、テキストフローに埋め込む
            $('a').each((_, element) => {
                const href = $(element).attr('href');
                if (href && !href.startsWith('javascript:') && !href.startsWith('#')) {
                    try {
                        const absoluteUrl = new URL(href, baseUrl).href;
                        const currentText = $(element).text();
                        if (currentText.trim()) {
                            $(element).append(` [詳細URL: ${absoluteUrl}] `);
                        }
                    } catch (e) {
                        // パース不可能なURLは無視して処理を継続
                    }
                }
            });

            // サイドバー等のノイズ領域をDOMツリーから完全に削除
            $('script, style, noscript, iframe, header, footer, nav, aside, .sidebar, .menu, #side').remove();

            // 改行を維持するための置換処理
            $('br').replaceWith('\n');
            $('td, th, div, p, li, h1, h2, h3, h4').append('\n');

            let mainContentText = $('article').text() || $('main').text() || $('.kw-article').text() || $('body').text();

            // 連続する空白や改行を正規化し、LLMへのトークン数を最適化
            return mainContentText.replace(/[ \t]+/g, ' ').replace(/\n+/g, '\n').trim();

        } catch (err: any) {
            attempt++;
            const isLastAttempt = attempt >= maxRetries;

            functions.logger.warn(`[${traceId}] Axios fetch failed for ${url} (Attempt ${attempt}/${maxRetries}). Error: ${err.message}`);

            if (isLastAttempt) {
                functions.logger.error(`[${traceId}] Exhausted all retries for ${url}. Aborting extraction.`);
                return '';
            }

            // フルジッターを用いた指数的バックオフによる待機時間の算出と適用
            const exponentialDelay = baseDelay * Math.pow(2, attempt);
            const jitter = Math.floor(Math.random() * exponentialDelay);
            await sleep(baseDelay + jitter);
        }
    }
    return '';
}

/**
 * Gemini API専用のリトライ関数。503 (Service Unavailable) などの一時エラー時に指数的バックオフで再試行する。
 */
async function generateContentWithRetry(ai: GoogleGenAI, model: string, contents: string, traceId: string, maxRetries = 3): Promise<any> {
    let attempt = 0;
    const baseDelay = 5000; // 初期待機時間 (5秒)

    while (attempt < maxRetries) {
        try {
            return await ai.models.generateContent({
                model: model,
                contents: contents,
                config: { responseMimeType: 'application/json' }
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

export const syncEvents = functions.runWith({ memory: '1GB', timeoutSeconds: 300 }).https.onCall(async (data, context) => {
    const traceId = data.traceId || `trace-${Date.now()}`;
    functions.logger.info(`[${traceId}] Starting syncEvents execution`, { traceId });

    try {
        // 設定ドキュメントのフェッチ
        const configDoc = await db.collection('settings').doc('config').get();
        if (!configDoc.exists) {
            functions.logger.warn(`[${traceId}] Configuration settings/config not found.`);
            return { success: false, message: 'Configuration settings/config not found.' };
        }

        const configData = configDoc.data();
        const targetGames: ConfigItem[] = configData?.targets || [];
        const geminiApiKey = configData?.geminiApiKey;

        if (targetGames.length === 0) return { success: true, message: 'No games configured to sync.' };

        if (!geminiApiKey) {
            functions.logger.error(`[${traceId}] Gemini API Key missing.`);
            return { success: false, message: 'Gemini API Key missing.' };
        }

        // 【耐障害性ロジック】
        // @google/genai SDKに組み込まれたリトライ機構を構成し、503(Overloaded)等のエラーに自動対処する。
        const ai = new GoogleGenAI({
            apiKey: geminiApiKey.trim(),
            httpOptions: {
                retryOptions: {
                    attempts: 4           // 初回を含む最大試行回数
                },
                timeout: 120000           // クライアント側タイムアウトを長めに設定
            }
        });

        const debugInfo: any[] = [];

        for (const game of targetGames) {
            functions.logger.info(`[${traceId}] Processing game: ${game.gameName}`, { url: game.url });

            // Stage 1: 一覧ページのHTMLをフェッチし、テキストを正規化（リトライ機構付き）
            const cleanText = await fetchHtmlWithRetry(game.url, game.url, traceId);

            if (!cleanText) {
                functions.logger.warn(`[${traceId}] Cleaned text is empty for ${game.gameName}, skipping extraction.`);
                continue;
            }

            debugInfo.push({
                stage: 1,
                type: 'HTML Fetched',
                url: game.url,
                snippet: cleanText.substring(0, 1000)
            });

            // Stage 1: Geminiによるイベントメタデータの抽出
            let extractedEvents: any[] = [];
            try {
                // 【プロンプトエンジニアリングの再構築】未来イベントの明確な包含と、代替文字列の利用禁止
                const prompt = `あなたはゲームのイベント情報を抽出する専門のAIアシスタントです。
以下のテキストは『${game.gameName}』の攻略サイト（一覧ページ）のメインコンテンツです。
テキスト内から「現在開催中の期間限定イベント」および「近日開催予定の期間限定イベント」のリストを抽出し、必ずJSONの配列形式のみを出力してください。

【抽出対象の厳格な条件】
- 「現在開催中」の期間限定イベント
- 「これから開催される予定（未来）」の期間限定イベント（テキスト内に存在する場合は絶対に抽出対象に含めること）

【抽出除外の厳格な条件】
以下のいずれかに該当するものは、抽出対象から絶対に除外してください。
1. 終了日が設定されていない常設コンテンツ
2. 常に開催されている恒常イベントや恒常ガチャ
3. 毎月自動的に開催される定常的なスケジュールコンテンツ

【出力要件（JSONプロパティ）】
各イベントは以下のプロパティを持つオブジェクトとしてください。
- title: イベントのタイトル
- imageUrl: イベントの画像URL
- eventUrl: テキスト内に付与された [詳細URL: https://...] の情報から抽出したURL
- period: 開催期間（例: "2024/01/01 ~ 2024/01/15"）
- endDate: イベントの終了日（YYYY-MM-DD形式。年が不明な場合は現在の年や文脈から補完）

【極めて重要な禁止事項】
情報が存在しない、または特定できないプロパティについては、「不明」「なし」「未定」などの文字列を値として使用せず、厳密にJSONの \`null\` を指定してください。

テキスト:
${cleanText.substring(0, 20000)}`;

                const response = await generateContentWithRetry(ai, 'gemini-2.5-flash', prompt, traceId);

                if (response.text) {
                    debugInfo.push({
                        stage: 1,
                        type: 'Gemini Raw Response',
                        text: response.text
                    });
                    const parsedData = sanitizeAndParseJson(response.text, traceId);
                    if (Array.isArray(parsedData)) {
                        extractedEvents = parsedData;
                        debugInfo.push({
                            stage: 1,
                            type: 'JSON Parsed Array',
                            data: JSON.stringify(extractedEvents)
                        });
                        functions.logger.info(`[${traceId}] Stage 1 extracted ${extractedEvents.length} events for ${game.gameName}`);
                    }
                }
            } catch (err) {
                // 組み込みリトライを使い切った上での致命的エラーの場合
                functions.logger.error(`[${traceId}] Stage 1 extraction completely failed for ${game.gameName}`, { error: err });
                continue; // 次のゲームへ移行してシステム全体の中断を防ぐ
            }

            if (extractedEvents.length === 0) continue;

            // Stage 2: 各イベントの詳細ページに対するデータ補完
            functions.logger.info(`[${traceId}] Starting Stage 2 enrichment for ${extractedEvents.length} events`);

            for (let i = 0; i < extractedEvents.length; i++) {
                const event = extractedEvents[i];
                if (!event.eventUrl) continue;

                try {
                    // 対象サイトへの過剰な負荷（Rate Limit超過）を防ぐためのスロットリング
                    await sleep(3000);
                    const detailCleanText = await fetchHtmlWithRetry(event.eventUrl, game.url, traceId);

                    if (!detailCleanText) continue;

                    debugInfo.push({
                        stage: 2,
                        type: 'HTML Fetched',
                        url: event.eventUrl,
                        snippet: detailCleanText.substring(0, 1000)
                    });

                    const detailPrompt = `あなたは情報補完専門のAIです。
以下のテキストは『${game.gameName}』の特定のイベント詳細ページのメインコンテンツです。
一覧ページから取得した【仮のイベント情報】を、詳細ページの内容を元に補完・修正し、1つのJSONオブジェクトとして出力してください。配列ではなく単一のオブジェクトです。

【仮のイベント情報】
- title: ${event.title || 'null'}
- period: ${event.period || 'null'}
- endDate: ${event.endDate || 'null'}
- imageUrl: ${event.imageUrl || 'null'}

【出力要件（JSONプロパティ）】
- title: 正式なイベントのタイトル（詳細ページの内容を優先して更新）
- summary: イベントの詳細な概要や報酬内容（文字列）
- period: 開催期間（詳細ページからより正確な期間を抽出）
- endDate: イベントの終了日（YYYY-MM-DD形式）
- imageUrl: イベントの画像URL（詳細ページに適切な画像URLがあれば更新）
- eventUrl: "${event.eventUrl}"（この値は維持してください）

【極めて重要な禁止事項】
情報が存在しない、または特定できないプロパティについては、「不明」「なし」などの文字列を値として使用せず、必ず厳密なJSONの \`null\` を指定してください。

テキスト:
${detailCleanText.substring(0, 20000)}`;

                    const detailResponse = await generateContentWithRetry(ai, 'gemini-2.5-flash', detailPrompt, traceId);

                    if (detailResponse.text) {
                        debugInfo.push({
                            stage: 2,
                            type: 'Gemini Raw Response',
                            text: detailResponse.text
                        });
                        const detailData = sanitizeAndParseJson(detailResponse.text, traceId);

                        if (detailData && typeof detailData === 'object') {
                            debugInfo.push({
                                stage: 2,
                                type: 'JSON Parsed Object',
                                data: JSON.stringify(detailData)
                            });
                            // 【防御的マージ処理の実行】有効なデータのみをStage 1のオブジェクトに適用する
                            event.title   = getValidString(detailData.title, event.title);
                            event.period  = getValidString(detailData.period, event.period);
                            event.summary = getValidString(detailData.summary, event.summary || '');
                            event.endDate = getValidString(detailData.endDate, event.endDate);
                            event.imageUrl= getValidString(detailData.imageUrl, event.imageUrl);

                            extractedEvents[i] = event;
                            debugInfo.push({
                                stage: 2,
                                type: 'Merged Event Data',
                                data: JSON.stringify(event)
                            });
                            functions.logger.info(`[${traceId}] Successfully enriched details for: ${event.title}`);
                        }
                    }
                } catch (err) {
                    functions.logger.error(`[${traceId}] Stage 2 enrichment failed for event ${event.title}`, { error: err });
                    // Stage 2が失敗しても、Stage 1のデータは維持されるためループを継続し、FirestoreへはStage 1のデータを保存する
                }
            }

            // Firestoreへの同期処理 (バッチサイズの上限を考慮したチャンク処理)
            try {
                const eventsCollection = db.collection(`games/${game.gameName}/events`);
                const currentEventsSnapshot = await eventsCollection.get();
                const currentEventsMap = new Map();

                currentEventsSnapshot.forEach(doc => {
                    currentEventsMap.set(doc.data().title, doc.id);
                });

                const newEventTitles = new Set();
                let batch = db.batch();
                let batchCount = 0;

                // ユーティリティ: Firestoreのバッチ書き込み上限（500件）を安全に回避するためのコミット処理
                const commitBatchIfNeeded = async () => {
                    if (batchCount >= 450) {
                        await batch.commit();
                        batch = db.batch();
                        batchCount = 0;
                    }
                };

                // 抽出されたイベントの新規追加または更新
                for (const event of extractedEvents) {
                    if (!event.title) continue; // タイトル欠落は不正データとして除外

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

                // 終了した不要なイベントドキュメントのクリーンアップ
                for (const [title, docId] of currentEventsMap.entries()) {
                    if (!newEventTitles.has(title)) {
                        const docRef = eventsCollection.doc(docId);
                        batch.delete(docRef);
                        batchCount++;
                        await commitBatchIfNeeded();
                    }
                }

                if (batchCount > 0) {
                    await batch.commit();
                }
                functions.logger.info(`[${traceId}] Successfully synchronized Firestore events for ${game.gameName}`);

            } catch (err) {
                functions.logger.error(`[${traceId}] Firestore synchronization failed for ${game.gameName}`, { error: err });
            }
        }

        functions.logger.info(`[${traceId}] syncEvents process completed successfully.`);
        return { success: true, message: 'Sync completed.', debugInfo };

    } catch (error) {
        functions.logger.error(`[${traceId}] Unhandled catastrophic error: ${error instanceof Error ? error.stack : String(error)}`);
        throw new functions.https.HttpsError('internal', 'Internal error occurred during the sync process.');
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