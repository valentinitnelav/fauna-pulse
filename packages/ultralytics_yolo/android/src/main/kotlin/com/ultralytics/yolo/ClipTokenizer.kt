// FaunaPulse (round 257, sam3 branch): the CLIP text tokenizer SAM 3's text encoder expects.
//
// A "tokenizer" cuts a prompt such as "flower-visiting insect" into word pieces and turns
// each piece into the number the text model knows it by. CLIP's is a byte-level BPE (byte
// pair encoding): every word starts as single characters, then the most common neighbouring
// pairs, as listed in merges.txt, are glued together until no listed pair is left. This is a
// port of OpenAI's `simple_tokenizer.py` (the one SAM 3 ships) without its ftfy/HTML clean-up,
// which changes nothing for plain typed prompts. vocab.json and merges.txt come with the
// SAM 3 files; nothing is bundled in the app.

package com.ultralytics.yolo

import org.json.JSONObject
import java.io.File

class ClipTokenizer(vocabJson: File, mergesTxt: File) {
    companion object {
        const val BOS = 49406 // <|startoftext|>
        const val EOT = 49407 // <|endoftext|>

        // Words: the English contractions, runs of letters, single digits, runs of other symbols.
        private val WORDS = Regex(
            """<\|startoftext\|>|<\|endoftext\|>|'s|'t|'re|'ve|'m|'ll|'d|\p{L}+|\p{N}|[^\s\p{L}\p{N}]+""",
            RegexOption.IGNORE_CASE,
        )

        /** CLIP's byte-to-character table: printable bytes stand for themselves, the rest are
         *  moved to characters from 256 on, so every byte has a visible stand-in. */
        private val BYTE_CHARS: Array<String> = run {
            val keep = (('!'.code..'~'.code) + ('¡'.code..'¬'.code) + ('®'.code..'ÿ'.code)).toSet()
            var extra = 0
            Array(256) { b -> (if (b in keep) b else 256 + extra++).toChar().toString() }
        }
    }

    private val ids: Map<String, Int>
    private val ranks: Map<String, Int> // "a b" -> merge priority (lower = earlier)
    private val cache = HashMap<String, List<String>>()

    init {
        val json = JSONObject(vocabJson.readText())
        ids = HashMap<String, Int>(json.length() * 2).also { m -> json.keys().forEach { m[it] = json.getInt(it) } }
        // The first line is a version header; CLIP uses the next 49152 - 256 - 2 merges.
        ranks = mergesTxt.readLines().drop(1).take(49152 - 256 - 2).withIndex().associate { (i, line) -> line to i }
    }

    /** Token numbers of [text]: start token, pieces, end token, then zeros up to [length]
     *  (a prompt that is too long is cut, keeping the end token). */
    fun encode(text: String, length: Int = 32): IntArray {
        val clean = text.replace(Regex("\\s+"), " ").trim().lowercase()
        val out = ArrayList<Int>()
        out.add(BOS)
        for (m in WORDS.findAll(clean)) {
            val chars = m.value.toByteArray(Charsets.UTF_8).joinToString("") { BYTE_CHARS[it.toInt() and 0xFF] }
            for (piece in bpe(chars)) out.add(ids[piece] ?: continue)
        }
        val body = out.take(length - 1)
        return IntArray(length) { i -> if (i < body.size) body[i] else if (i == body.size) EOT else 0 }
    }

    private fun bpe(word: String): List<String> = cache.getOrPut(word) {
        // Characters, the last one marked as a word end.
        var parts = word.map { it.toString() }.toMutableList()
        parts[parts.size - 1] = parts.last() + "</w>"
        while (parts.size > 1) {
            var best = -1
            var bestRank = Int.MAX_VALUE
            for (i in 0 until parts.size - 1) {
                val r = ranks["${parts[i]} ${parts[i + 1]}"] ?: continue
                if (r < bestRank) { bestRank = r; best = i }
            }
            if (best < 0) break
            val a = parts[best]
            val b = parts[best + 1]
            val merged = ArrayList<String>(parts.size)
            var i = 0
            while (i < parts.size) {
                if (i < parts.size - 1 && parts[i] == a && parts[i + 1] == b) { merged.add(a + b); i += 2 }
                else { merged.add(parts[i]); i++ }
            }
            parts = merged
        }
        parts
    }
}
