using System;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

namespace VoxFlow;

/// <summary>
/// Rule-based transcript cleanup — the same ordered pipeline as the macOS
/// version: fillers, repeats, spoken commands, whitespace, punctuation
/// spacing, sentence capitalization, terminal punctuation.
/// </summary>
public static class TextCleaner
{
    public static string Clean(string input)
    {
        string text = input.Trim();
        if (text.Length == 0) return text;

        text = Regex.Replace(text, @"(?i)\b(um|uh|uhh|er|erm)\b,?", "");
        text = Regex.Replace(text, @"(?i),\s*you know\s*,", ",");
        text = Regex.Replace(text, @"(?i),\s*you know\b", "");
        text = Regex.Replace(text, @"(?i)\b(\w+)\b(\s+\1\b)+", "$1");
        text = Regex.Replace(text, @"(?i)[,.]?\s*\bnew paragraph\b[,.]?", "\n\n");
        text = Regex.Replace(text, @"(?i)[,.]?\s*\bnew line\b[,.]?", "\n");
        text = Regex.Replace(text, @"[ \t]+", " ");
        text = Regex.Replace(text, @" *\n *", "\n");
        text = Regex.Replace(text, @"\n{3,}", "\n\n").Trim();
        text = Regex.Replace(text, @"[ \t]+([,.!?;:])", "$1");
        text = Regex.Replace(text, @"([,!?;:])(?=[A-Za-z0-9])", "$1 ");
        text = Regex.Replace(text, @"(?<=[A-Za-z]{2})\.(?=[A-Za-z])", ". ");
        text = RunOnSplitter.Split(text);
        text = PunctuationSanity.Apply(text);
        // A joined restart ("the. The goal") leaves a doubled word.
        text = Regex.Replace(text, @"(?i)\b(\w+)\b(\s+\1\b)+", "$1");
        text = Regex.Replace(text, @"[ \t]+", " ");
        text = CapitalizeSentences(text);
        text = EnsureTerminalPunctuation(text);
        return text;
    }

    private static string CapitalizeSentences(string text)
    {
        var result = new StringBuilder(text.Length);
        bool capitalizeNext = true;
        foreach (char ch in text)
        {
            if (capitalizeNext && char.IsLetter(ch))
            {
                result.Append(char.ToUpperInvariant(ch));
                capitalizeNext = false;
                continue;
            }
            result.Append(ch);
            if (ch is '.' or '!' or '?' or '\n')
                capitalizeNext = true;
            else if (!char.IsWhiteSpace(ch))
                capitalizeNext = false;
        }
        return result.ToString();
    }

    private static string EnsureTerminalPunctuation(string text)
    {
        string trimmed = text.Trim();
        if (trimmed.Length == 0) return trimmed;
        int wordCount = trimmed.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length;
        if (wordCount < 3) return trimmed;
        char last = trimmed[^1];
        if (last is '.' or '!' or '?') return trimmed;
        return trimmed + ".";
    }
}
