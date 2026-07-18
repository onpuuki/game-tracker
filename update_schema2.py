import re

with open('functions/src/index.ts', 'r') as f:
    content = f.read()

schema_search = """            responseSchema: {
                type: "object",
                properties: {
                    liveness_audit_purges: {
                        type: "array",
                        description: "パージ（削除）すべき既存イベントのリスト",
                        items: {
                            type: "object",
                            properties: {
                                doc_id: { type: "string", description: "削除対象の既存イベントID" },
                                purge_type: { type: "string", description: "削除の種類 (EXPIRED: 期限切れ, NOISE: ガチャやお知らせ等の対象外, HALLUCINATION: 捏造)" },
                                purge_reason: { type: "string", description: "削除すべき具体的な理由" }
                            },
                            required: ["doc_id", "purge_type", "purge_reason"]
                        }
                    },
                    events: {
                        type: "array",
                        items: {
                            type: "object",
                            properties: {
                                thought_process: {
                                    type: "object",
                                    description: "抽出・判定の論理的思考プロセス。各ステップを必ず詳細に記述すること",
                                    properties: {
                                        validity_check: { type: "string", description: "イベントの妥当性評価（ガチャ・単なるお知らせ等ではなく、抽出対象である明確な理由）" },
                                        deduplication_analysis: { type: "string", description: "既存リストとの名寄せ判断（言語差・表記ゆれの考慮結果、新規か更新かの根拠）" },
                                        summary_extraction_logic: { type: "string", description: "概要(summary)をどのように抽出・要約したかの根拠（『記載なし』とする場合はその正当な理由）" }
                                    },
                                    required: ["validity_check", "deduplication_analysis", "summary_extraction_logic"]
                                },
                                evidence_snippet: { type: "string", description: "抽出の根拠となった情報元の実際のテキスト抜粋（捏造防止用）。無い場合は絶対に抽出しないこと" },
                                is_valid_event: { type: "boolean", description: "ガチャやお知らせではなく、本当に対象となるイベント・コードであるか" },
                                existing_id: { type: "string", nullable: true, description: "既存リストに該当するものがあればそのID。完全新規ならnull" },
                                match_reason: { type: "string", description: "既存IDと紐付けた理由、または完全新規とした理由" },
                                title: { type: "string", description: "イベントまたはコードのタイトル（情報元の通り、一言一句違わず）" },
                                summary: { type: "string", description: "具体的なプレイ手順やキャンペーン内容の詳細な要約（最低3〜4文）。安易な『記載なし』は禁止" },
                                startDate: { type: "string", nullable: true, description: "YYYY-MM-DDTHH:mm:ssZ" },
                                endDate: { type: "string", nullable: true, description: "YYYY-MM-DDTHH:mm:ssZ" },
                                is_gift_code: { type: "boolean", description: "これがギフトコード情報であるかどうか" },
                                redeemCode: { type: "string", nullable: true, description: "ギフトコードの文字列（空白等除去）" },
                                tag: { type: "string" },
                                eventUrl: { type: "string", nullable: true },
                                rewards: {
                                    type: "array",
                                    description: "具体的な報酬内容（アイテム名と数量）のリスト",
                                    items: {
                                        type: "object",
                                        properties: {
                                            name: { type: "string", description: "報酬の具体的な固有名称" },
                                            quantity: { type: "string", description: "数量" }
                                        },
                                        required: ["name", "quantity"]
                                    }
                                }
                            },
                            required: [
                                "thought_process", "evidence_snippet", "is_valid_event", "existing_id", "match_reason",
                                "title", "summary", "startDate", "endDate",
                                "is_gift_code", "redeemCode", "tag", "eventUrl", "rewards"
                            ]
                        }
                    }
                },
                required: ["events", "liveness_audit_purges"]
            }"""

schema_replace = """            responseSchema: {
                type: "object",
                properties: {
                    liveness_audit_purges: {
                        type: "array",
                        description: "パージ（削除）すべき既存イベントのリスト",
                        items: {
                            type: "object",
                            properties: {
                                doc_id: { type: "string", description: "削除対象の既存イベントID" },
                                purge_type: { type: "string", description: "EXPIRED: 期限切れ, NOISE: ガチャやお知らせ等の対象外, HALLUCINATION: 捏造" },
                                purge_reason: { type: "string", description: "削除すべき具体的な理由。ソースとの矛盾点や、なぜノイズと判断したか等" }
                            },
                            required: ["doc_id", "purge_type", "purge_reason"]
                        }
                    },
                    events: {
                        type: "array",
                        items: {
                            type: "object",
                            properties: {
                                thought_process: {
                                    type: "object",
                                    description: "抽出・判定の論理的思考プロセス。結論を出す前に必ず各ステップを記述すること",
                                    properties: {
                                        validity_check: { type: "string", description: "これがガチャやお知らせではなく、真にプレイ可能なイベント/コードである理由" },
                                        deduplication_analysis: { type: "string", description: "既存リストとの名寄せ判断。既存IDと紐づけた理由、または完全新規である理由" },
                                        gift_code_analysis: { type: "string", description: "コードの場合、その報酬と期限をどう特定したか" },
                                        summary_extraction_logic: { type: "string", description: "概要をどのように見つけて要約したか。（記載なしとする場合の正当な理由）" }
                                    },
                                    required: ["validity_check", "deduplication_analysis", "summary_extraction_logic"]
                                },
                                is_valid_event: { type: "boolean", description: "真に対象となるイベント・コードであるか（ガチャ・お知らせはfalse）" },
                                existing_id: { type: "string", nullable: true, description: "既存リストに該当するものがあればそのID。完全新規ならnull" },
                                match_reason: { type: "string", description: "既存IDと紐付けた理由、または完全新規とした理由" },
                                title: { type: "string", description: "イベントまたはコードのタイトル（情報元の通り、一言一句違わず）" },
                                summary: { type: "string", description: "具体的なプレイ手順やキャンペーン内容の詳細な要約（最低3〜4文）。安易な『記載なし』は禁止" },
                                evidence_snippet: { type: "string", description: "抽出の根拠となった情報元の実際のテキスト抜粋。見つからない場合は抽出しない" },
                                startDate: { type: "string", nullable: true, description: "YYYY-MM-DDTHH:mm:ssZ" },
                                endDate: { type: "string", nullable: true, description: "YYYY-MM-DDTHH:mm:ssZ" },
                                is_gift_code: { type: "boolean", description: "これがギフトコード情報であるか" },
                                redeemCode: { type: "string", nullable: true, description: "ギフトコードの文字列（空白やハイフンを除去した英数字）" },
                                tag: { type: "string" },
                                eventUrl: { type: "string", nullable: true },
                                rewards: {
                                    type: "array",
                                    description: "具体的な報酬内容",
                                    items: {
                                        type: "object",
                                        properties: {
                                            name: { type: "string", description: "報酬の具体的な名称" },
                                            quantity: { type: "string", description: "数量" }
                                        },
                                        required: ["name", "quantity"]
                                    }
                                }
                            },
                            required: ["thought_process", "is_valid_event", "title", "summary", "evidence_snippet", "is_gift_code", "tag"]
                        }
                    }
                },
                required: ["liveness_audit_purges", "events"]
            }"""

if schema_search in content:
    content = content.replace(schema_search, schema_replace)
    with open('functions/src/index.ts', 'w') as f:
        f.write(content)
    print("Replaced successfully")
else:
    print("Could not find schema_search")
