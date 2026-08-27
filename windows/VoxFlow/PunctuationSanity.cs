using System;
using System.Collections.Generic;
using System.Text;
using System.Text.RegularExpressions;

namespace VoxFlow;

/// <summary>
/// Final grammar-aware pass over the whole transcript. Every earlier layer
/// (whisper, pause/segment breaks, the run-on splitter) is a guess about
/// where sentences end; this pass removes the guesses that cannot be right:
///  - a sentence never ends on a word that needs a continuation ("the",
///    "to", "whether", "and", "of", …) — that break is a hesitation, so join;
///  - a one- or two-word "sentence" that is not an interjection ("Okay.",
///    "Go!", "Fine.") is a fragment — fold it into the previous sentence;
///  - a sentence never starts with "or"/"nor" — join.
/// Joining a false break that was a restart ("the. The goal") leaves a
/// doubled word, which the cleaner's repeat rule then collapses.
/// </summary>
public static class PunctuationSanity
{
    /// <summary>Words a sentence cannot end on.</summary>
    private static readonly HashSet<string> NonTerminal = new(StringComparer.OrdinalIgnoreCase)
    {
        // Only words that genuinely need a continuation. "I like that.",
        // "I think so.", "Do this.", "I can't." are all real sentence ends
        // and must not be joined.
        "the", "a", "an", "to", "of", "and", "but", "or", "nor", "if", "whether", "with", "for",
        "from", "into", "onto", "than", "as", "because", "my", "your", "our", "their", "his",
        "its", "every", "which", "whose", "while", "until", "unless", "although", "though",
        "since", "per", "without", "within", "very", "really", "such", "versus", "via",
        "towards", "toward", "among", "between", "during", "through", "throughout", "upon",
        "despite", "regarding", "except", "besides", "i'm", "you're", "we're", "they're",
        "he's", "she's", "it's", "that's", "there's", "i've", "we've", "you've", "i'll", "we'll",
        "you'll", "i'd", "we'd", "you'd", "gonna", "wanna", "kind", "sort", "pretty", "quite",
    };

    /// <summary>Very short sentences that are fine standing alone.</summary>
    private static readonly HashSet<string> Interjections = new(StringComparer.OrdinalIgnoreCase)
    {
        "yes", "no", "okay", "ok", "fine", "go", "thanks", "thank you", "sure", "exactly", "right",
        "done", "great", "good", "perfect", "correct", "wrong", "stop", "wait", "please", "sorry",
        "hello", "hi", "hey", "bye", "goodbye", "cool", "nice", "wow", "alright", "all right",
        "yeah", "yep", "nope", "absolutely", "definitely", "maybe", "never", "always", "agreed",
        "seriously", "whatever", "unbelievable", "obviously", "clearly", "interesting", "weird",
        "amazing", "awesome", "terrible", "unacceptable", "enough", "next", "continue", "proceed",
        "cancel", "undo", "retry", "again", "why", "what", "how", "really", "true", "false",
        "impossible", "possibly", "probably", "certainly", "indeed", "period", "finally",
        "understood", "noted", "got it", "no way", "of course", "not really", "that's it",
        "that's all", "let's go", "go ahead", "well done", "good job", "same here", "me too",
    };

    private static readonly HashSet<string> NoSentenceStart = new(StringComparer.OrdinalIgnoreCase)
    {
        "or", "nor",
    };

    private static readonly Regex SentenceEnd = new(@"(?<=[.!?])\s+(?=\S)", RegexOptions.Compiled);

    public static string Apply(string text)
    {
        if (string.IsNullOrWhiteSpace(text)) return text;
        var paragraphs = text.Split('\n');
        for (int p = 0; p < paragraphs.Length; p++)
            paragraphs[p] = ApplyParagraph(paragraphs[p]);
        return string.Join("\n", paragraphs);
    }

    private static string ApplyParagraph(string text)
    {
        var sentences = new List<string>(SentenceEnd.Split(text));
        if (sentences.Count < 2) return text;

        int joined = 0;
        var result = new List<string> { sentences[0] };
        for (int i = 1; i < sentences.Count; i++)
        {
            string prev = result[^1];
            string cur = sentences[i];
            string reason = JoinReason(prev, cur);
            if (reason == null)
            {
                result.Add(cur);
                continue;
            }
            joined++;
            result[^1] = Join(prev, cur);
        }
        if (joined > 0) Log.Info($"Punctuation sanity: {joined} false sentence break(s) removed");
        return string.Join(" ", result);
    }

    private static string? JoinReason(string prev, string cur)
    {
        char prevEnd = prev[^1];
        if (prevEnd is '?' or '!') return null; // questions and exclamations are deliberate
        string prevLast = LastWord(prev);
        string curFirst = FirstWord(cur);
        int curWords = WordCount(cur);

        if (NonTerminal.Contains(prevLast)) return "ends on non-terminal word";
        if (NoSentenceStart.Contains(curFirst)) return "starts with conjunction";
        // A lone word is a fragment ("Afterwards.") unless it is a real
        // one-word sentence. Two-word sentences ("Do this.", "I can't.") are
        // left alone. A fragment ending on a continuation word ("Like the.")
        // belongs to the sentence AFTER it; the non-terminal rule joins it
        // forward on the next step, so do not pull it backward here.
        if (curWords == 1 && cur[^1] == '.' && !Interjections.Contains(Core(cur)) && !NonTerminal.Contains(curFirst))
            return "fragment";
        return null;
    }

    private static string Join(string prev, string cur)
    {
        // Drop the false terminal punctuation on prev (keep a comma if it was one).
        string head = prev.TrimEnd();
        head = head.Substring(0, head.Length - 1).TrimEnd();
        // The word after a false break is not a sentence start; lower-case it
        // unless it is the pronoun I or an all-caps token (acronym).
        string tail = cur;
        int firstLetter = 0;
        while (firstLetter < tail.Length && !char.IsLetter(tail[firstLetter])) firstLetter++;
        if (firstLetter < tail.Length)
        {
            string w = FirstWord(tail);
            bool keep = w == "I" || w.StartsWith("I'", StringComparison.Ordinal) ||
                        (w.Length > 1 && w.ToUpperInvariant() == w);
            if (!keep)
                tail = tail.Substring(0, firstLetter) + char.ToLowerInvariant(tail[firstLetter]) + tail.Substring(firstLetter + 1);
        }
        return head + " " + tail;
    }

    private static string Core(string s) => Regex.Replace(s, @"^[^\w']+|[^\w']+$", "").Trim();

    private static string LastWord(string s)
    {
        string t = Core(s);
        int i = t.LastIndexOf(' ');
        return i < 0 ? t : t.Substring(i + 1);
    }

    private static string FirstWord(string s)
    {
        string t = Core(s);
        int i = t.IndexOf(' ');
        return i < 0 ? t : t.Substring(0, i);
    }

    private static int WordCount(string s) =>
        Core(s).Split(' ', StringSplitOptions.RemoveEmptyEntries).Length;
}
