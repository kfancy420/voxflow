using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text.RegularExpressions;

namespace VoxFlow;

/// <summary>
/// Undoes whisper's phantom lists. When a multi-word name is spoken with
/// slight pauses ("Vitality Massage pricing", "Corvette Diner"), whisper's
/// decoder sometimes drops into list mode and emits every word as a
/// capitalised item: "change Vitality, Massage, Pricing, and Update the
/// website". No sentence-break rule can see this — the commas and the
/// capitals are whisper's own — so it is repaired here, before the
/// dictionary and the cleaner run.
///
/// The signature is narrow on purpose: a comma list of three or more single
/// Title-cased words, mid-sentence, where every item after the first is an
/// ordinary English word. Whisper capitalises ordinary words only when it
/// believes they are names; a real list of names ("Alice, Bob, and Carol")
/// is left alone because its items are not in the common-word lexicon, and a
/// real list of things ("apples, oranges, and pears") is left alone because
/// it is lower-case. A list right after a determiner ("the Home, About, and
/// Contact pages") is also left alone — that shape is how named things are
/// listed deliberately. Evidence (log, 198 takes): two lists matched this
/// shape, both phantom; zero genuine ones.
///
/// Repair: drop the commas, keep the conjunction, lower-case the items whisper
/// invented. The first item keeps its case (it is the likely head of the
/// name), as does a final item that heads a further capitalised word
/// ("…and Gamer Garage").
/// </summary>
public static class ListSanity
{
    private const int MinItems = 3;

    private static readonly Regex TitleList = new(
        @"(?<=\b(?!(?:the|these|those|all|our|my|your|his|her|their|its|some|both)\s)[a-z][a-z']*\s)" +
        @"(?<first>[A-Z][a-z]+)(?<mid>(?:,\s[A-Z][a-z]+)+)" +
        @"(?:,?\s(?<conj>and|or)\s(?<last>[A-Z][a-z]+))?" +
        @"(?=[\s,.!?;:]|$)",
        RegexOptions.Compiled);

    private static readonly Regex HeadsPhrase = new(@"^\s[A-Z][a-z]", RegexOptions.Compiled);

    private static readonly Lazy<HashSet<string>> Common = new(LoadCommon);

    /// <summary>Loads the lexicon off the first take's critical path.</summary>
    public static void Warm() => _ = Common.Value.Count;

    public static string Apply(string text)
    {
        if (string.IsNullOrEmpty(text) || text.IndexOf(',') < 0) return text;
        return TitleList.Replace(text, m => Repair(m, text));
    }

    private static string Repair(Match m, string text)
    {
        var mid = m.Groups["mid"].Value.Split(", ", StringSplitOptions.RemoveEmptyEntries)
            .Select(s => s.Trim(',', ' ')).Where(s => s.Length > 0).ToList();
        string? last = m.Groups["last"].Success ? m.Groups["last"].Value : null;
        int count = 1 + mid.Count + (last != null ? 1 : 0);
        if (count < MinItems) return m.Value;

        var lexicon = Common.Value;
        if (mid.Any(w => !lexicon.Contains(w)) || (last != null && !lexicon.Contains(last)))
            return m.Value;

        string tail = text.Substring(m.Index + m.Length);
        var parts = new List<string> { m.Groups["first"].Value };
        parts.AddRange(mid.Select(w => w.ToLowerInvariant()));
        if (last != null)
        {
            parts.Add(m.Groups["conj"].Value);
            parts.Add(HeadsPhrase.IsMatch(tail) ? last : last.ToLowerInvariant());
        }
        string repaired = string.Join(" ", parts);
        Log.Info($"List sanity: phantom list \"{m.Value}\" → \"{repaired}\"");
        return repaired;
    }

    private static HashSet<string> LoadCommon()
    {
        var set = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        try
        {
            using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("VoxFlow.CommonWords.txt");
            if (stream == null) { Log.Error("List sanity: CommonWords.txt resource missing"); return set; }
            using var reader = new StreamReader(stream);
            string? line;
            while ((line = reader.ReadLine()) != null)
            {
                line = line.Trim();
                if (line.Length > 0) set.Add(line);
            }
        }
        catch (Exception ex)
        {
            Log.Error("List sanity: lexicon load failed: " + ex.Message);
        }
        return set;
    }
}
