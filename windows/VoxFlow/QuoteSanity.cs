using System;

namespace VoxFlow;

/// <summary>
/// Drops whisper's phantom opening quote. When a take starts like a message
/// being relayed, whisper sometimes decides it is reported speech and wraps
/// the first sentence — or the whole take — in double quotes:
///   "Help me choose between my insurance options." So for reference, …
///   "Expire all the creators..."
/// Nothing was quoted. Evidence (log, 198 takes): every take that BEGAN with
/// a quote (5) was phantom; every genuine quote (5) was mid-take, after a
/// word like asked/think/called. So a quote in the first position is removed
/// together with the quote that closes it (the next one), or alone if it
/// never closes. Quotes anywhere else are whisper's to keep.
/// </summary>
public static class QuoteSanity
{
    public static string Apply(string text)
    {
        if (string.IsNullOrEmpty(text)) return text;
        string t = text.TrimStart();
        if (t.Length == 0 || !IsQuote(t[0])) return text;

        int close = -1;
        for (int i = 1; i < t.Length; i++)
        {
            if (IsQuote(t[i])) { close = i; break; }
        }

        string result;
        if (close < 0)
        {
            result = t.Substring(1).TrimStart();
        }
        else
        {
            string inner = t.Substring(1, close - 1).Trim();
            string rest = t.Substring(close + 1).TrimStart();
            result = rest.Length == 0 ? inner : inner + " " + rest;
        }
        Log.Info($"Quote sanity: dropped phantom opening quote ({(close < 0 ? "unclosed" : "closed at " + close)})");
        return result;
    }

    private static bool IsQuote(char c) => c is '"' or '“' or '”';
}
