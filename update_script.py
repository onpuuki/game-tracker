with open('functions/src/index.ts', 'r') as f:
    content = f.read()

normalize_str_search = """function normalizeString(str: string): string {
    if (!str) return '';
    const baseNormalized = str
        .normalize('NFKC')
        .toLowerCase()
        .replace(/[\\s\\u3000]+/g, '') // 半角・全角スペースの完全除去
        // ノイズ記号・絵文字の削除 (さらに広範に)
        .replace(/[【】\\[\\]（）()「」『』〜~ー\\-:：!?！？\\p{Emoji_Presentation}\\p{Extended_Pictographic}◆◇▼★☆♪]/gu, '');

    const fullyNormalized = baseNormalized
        // 汎用キーワードの削除 (新規追加のノイズワード)
        .replace(/(イベント|キャンペーン|開催|のお知らせ|お知らせ|復刻|記念|ピックアップ|祈願|跳躍|ガチャ|ログインボーナス|ログイン|フェス|ボーナス|プレゼント|事前登録|リリース)/g, '');

    if (fullyNormalized.length <= 2) {
        return baseNormalized;
    }
    return fullyNormalized;
}"""

normalize_str_replace = """function normalizeString(str: string): string {
    if (!str) return '';
    const baseNormalized = str
        .normalize('NFKC')
        .toLowerCase()
        .replace(/[\\s\\u3000]+/g, '') // 半角・全角スペースの完全除去
        // ノイズ記号・絵文字の削除 (さらに広範に)
        .replace(/[【】\\[\\]（）()「」『』〜~ー\\-:：!?！？\\p{Emoji_Presentation}\\p{Extended_Pictographic}◆◇▼★☆♪]/gu, '');

    const fullyNormalized = baseNormalized
        // 汎用キーワードに加え、「第○弾」「vol.」「ver.」などのバージョン表記も除去
        .replace(/(イベント|キャンペーン|開催|のお知らせ|お知らせ|復刻|記念|ピックアップ|祈願|跳躍|ガチャ|ログインボーナス|ログイン|フェス|ボーナス|プレゼント|事前登録|リリース)/g, '')
        .replace(/(第[0-9一二三四五六七八九十]+弾|vol\\.?\\d+|ver\\.?\\d+)/gi, '');

    if (fullyNormalized.length <= 2) {
        return baseNormalized;
    }
    return fullyNormalized;
}"""

if normalize_str_search in content:
    content = content.replace(normalize_str_search, normalize_str_replace)
    with open('functions/src/index.ts', 'w') as f:
        f.write(content)
    print("Replaced successfully")
else:
    print("Could not find normalize_str_search")
