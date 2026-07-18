import re

with open('functions/src/index.ts', 'r') as f:
    content = f.read()

purge_search = """            // LLMの不調による undefined 防止 (デフォルト値設定)
            extractedEvents = extractedEvents || [];
            livenessAuditPurges = livenessAuditPurges || [];

            await writeDebugLog(traceId, `Gemini Response for ${gameName}`, { text: response.text });"""

purge_replace = """            // LLMの不調による undefined 防止 (デフォルト値設定)
            extractedEvents = extractedEvents || [];
            livenessAuditPurges = livenessAuditPurges || [];

            for (const event of extractedEvents) {
                // もし今回AIが「無効なイベント（ガチャやノイズ）」と判定し、かつ既存DBと紐付いていた場合
                if (event.is_valid_event === false && event.existing_id) {
                    // すでに livenessAuditPurges に含まれていないか確認して追加
                    const alreadyPurged = livenessAuditPurges.some((p: any) => p.doc_id === event.existing_id);
                    if (!alreadyPurged) {
                        livenessAuditPurges.push({
                            doc_id: event.existing_id,
                            purge_type: 'NOISE',
                            purge_reason: 'AIの再評価により対象外(ノイズ)と判定されたため'
                        });
                    }
                }
            }

            await writeDebugLog(traceId, `Gemini Response for ${gameName}`, { text: response.text });"""

if purge_search in content:
    content = content.replace(purge_search, purge_replace)
    with open('functions/src/index.ts', 'w') as f:
        f.write(content)
    print("Replaced successfully")
else:
    print("Could not find purge_search")
