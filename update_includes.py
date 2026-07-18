import re

with open('functions/src/index.ts', 'r') as f:
    content = f.read()

includes_search = """                        // 【防御的要件1】誤検知防止: 短い場合は完全一致のみを許可、包含判定は文字列長5以上の場合のみ
                        if (normAI.length < 5 || normDB.length < 5) {
                            if (normAI === normDB) return true;
                        } else {
                            if (calculateSimilarity(u.title, event.title) >= 0.85) return true;
                            if (normDB.length >= 5 && normAI.length >= 5 && normAI.includes(normDB)) return true;
                            if (normAI.length >= 5 && normDB.length >= 5 && normDB.includes(normAI)) return true;
                        }"""

includes_replace = """                        // 【防御的要件1】誤検知防止: 短い場合は完全一致のみを許可、包含判定は文字列長5以上の場合のみ
                        if (normAI.length < 5 || normDB.length < 5) {
                            if (normAI === normDB) return true;
                        } else {
                            if (calculateSimilarity(u.title, event.title) >= 0.85) return true;
                            const minLen = Math.min(normAI.length, normDB.length);
                            if (minLen >= 5) {
                                if (normAI.includes(normDB)) return true;
                                if (normDB.includes(normAI)) return true;
                            }
                        }"""

if includes_search in content:
    content = content.replace(includes_search, includes_replace)
    with open('functions/src/index.ts', 'w') as f:
        f.write(content)
    print("Replaced successfully (1)")
else:
    print("Could not find includes_search (1)")

includes_search2 = """                            // 【防御的要件1】誤検知防止: 短い場合は完全一致のみを許可、包含判定は文字列長5以上の場合のみ
                            if (normAI.length < 5 || normDB.length < 5) {
                                if (normAI === normDB) return true;
                            } else {
                                // 類似度が85%以上
                                if (calculateSimilarity(e.data.title, event.title) >= 0.85) {
                                    return true;
                                }

                                // 一方がもう一方の文字列を完全に内包している場合（略称やサブタイトル違いの吸収）
                                if (normDB.length >= 5 && normAI.length >= 5 && normAI.includes(normDB)) {
                                    return true;
                                }
                                if (normAI.length >= 5 && normDB.length >= 5 && normDB.includes(normAI)) {
                                    return true;
                                }
                            }"""

includes_replace2 = """                            // 【防御的要件1】誤検知防止: 短い場合は完全一致のみを許可、包含判定は文字列長5以上の場合のみ
                            if (normAI.length < 5 || normDB.length < 5) {
                                if (normAI === normDB) return true;
                            } else {
                                // 類似度が85%以上
                                if (calculateSimilarity(e.data.title, event.title) >= 0.85) {
                                    return true;
                                }

                                // 一方がもう一方の文字列を完全に内包している場合（略称やサブタイトル違いの吸収）
                                const minLen = Math.min(normAI.length, normDB.length);
                                if (minLen >= 5) {
                                    if (normAI.includes(normDB)) return true;
                                    if (normDB.includes(normAI)) return true;
                                }
                            }"""

if includes_search2 in content:
    content = content.replace(includes_search2, includes_replace2)
    with open('functions/src/index.ts', 'w') as f:
        f.write(content)
    print("Replaced successfully (2)")
else:
    print("Could not find includes_search (2)")
