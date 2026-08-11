using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace VoxFlow;

/// <summary>App settings persisted to %APPDATA%\VoxFlow\settings.json.</summary>
public sealed class Settings
{
    public bool CleanupEnabled { get; set; } = true;
    public bool TrailingSpace { get; set; } = true;
    /// <summary>
    /// medium.en: on a GPU-accelerated machine the extra ~100 ms is
    /// imperceptible and it is measurably better on technical vocabulary.
    /// </summary>
    public string Model { get; set; } = "medium.en";
    /// <summary>True once we've auto-enabled start-with-Windows on first run.</summary>
    public bool AutoStartConfigured { get; set; } = false;

    /// <summary>
    /// How long dictation history is kept, in hours. Everything dictated is
    /// stored in plaintext, so it expires by default rather than accumulating.
    /// Set to 0 to keep entries until the 200-entry cap evicts them.
    /// </summary>
    public int HistoryRetentionHours { get; set; } = 24;

    private static string FilePath =>
        Path.Combine(AppDataDirectory(), "settings.json");

    public static string AppDataDirectory()
    {
        string dir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "VoxFlow");
        Directory.CreateDirectory(dir);
        return dir;
    }

    public static Settings Load()
    {
        try
        {
            if (File.Exists(FilePath))
            {
                string json = File.ReadAllText(FilePath);
                var loaded = JsonSerializer.Deserialize<Settings>(json) ?? new Settings();

                // A settings file written by an older build is missing any key
                // added since. Those keys then only exist as C# defaults, so
                // the user cannot discover or edit them. Write the normalised
                // form back so the file always documents every option.
                if (JsonSerializer.Serialize(loaded, WriteOptions).Trim() != json.Trim())
                    loaded.Save();

                return loaded;
            }
        }
        catch { }

        var fresh = new Settings();
        fresh.Save();
        return fresh;
    }

    private static readonly JsonSerializerOptions WriteOptions = new() { WriteIndented = true };

    public void Save()
    {
        try
        {
            File.WriteAllText(FilePath, JsonSerializer.Serialize(this, WriteOptions));
        }
        catch { }
    }
}

/// <summary>
/// Personal dictionary: whole-word, case-insensitive replacements loaded from
/// %APPDATA%\VoxFlow\dictionary.json (editable via the tray menu).
/// </summary>
public static class PersonalDictionary
{
    private static string FilePath =>
        Path.Combine(Settings.AppDataDirectory(), "dictionary.json");

    public static void EnsureExists()
    {
        if (File.Exists(FilePath)) return;
        // Whisper has no idea "VoxFlow" is a word, so it guesses at the sounds
        // and lands on things like "box flow" or "Vox Flow". Seed the common
        // mishearings — this is exactly what the dictionary is for.
        var sample = new Dictionary<string, string>
        {
            ["voxflow"] = "VoxFlow",
            ["vox flow"] = "VoxFlow",
            ["box flow"] = "VoxFlow",
            ["fox flow"] = "VoxFlow",
        };
        try
        {
            File.WriteAllText(FilePath, JsonSerializer.Serialize(sample,
                new JsonSerializerOptions { WriteIndented = true }));
        }
        catch { }
    }

    public static string PathForEditing()
    {
        EnsureExists();
        return FilePath;
    }

    public static string Apply(string text)
    {
        Dictionary<string, string>? entries = null;
        try
        {
            if (File.Exists(FilePath))
                entries = JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(FilePath));
        }
        catch { }
        if (entries == null || entries.Count == 0) return text;

        foreach (var pair in entries.OrderByDescending(p => p.Key.Length))
        {
            if (string.IsNullOrWhiteSpace(pair.Key)) continue;
            string escaped = Regex.Escape(pair.Key);
            string pattern = (char.IsLetterOrDigit(pair.Key[0]) ? @"\b" : "")
                + escaped
                + (char.IsLetterOrDigit(pair.Key[^1]) ? @"\b" : "");
            text = Regex.Replace(text, pattern, pair.Value.Replace("$", "$$"), RegexOptions.IgnoreCase);
        }
        return text;
    }
}

/// <summary>
/// History of dictations, newest first. Bounded two ways: by age
/// (<see cref="RetentionHours"/>, 24 h by default) and by count (200).
///
/// The age bound is the one that matters. Everything dictated goes through
/// here in plaintext — messages, invoices, client details — so it should not
/// accumulate on disk indefinitely just because the entry count stayed under
/// a cap.
///
/// Expiry is event-driven: enforced at startup, on every write, and whenever
/// the history is opened for reading. There is no background sweep, so on a
/// machine left running and unused an expired entry survives on disk until
/// one of those happens.
/// </summary>
public static class HistoryStore
{
    private sealed record Entry(DateTime Date, string Raw, string Cleaned, string? App);

    private const int MaxEntries = 200;

    /// <summary>
    /// Hours to keep dictations for. Zero or less disables time-based expiry
    /// and falls back to the count cap alone.
    /// </summary>
    public static int RetentionHours { get; set; } = 24;

    private static readonly object Gate = new();

    private static readonly JsonSerializerOptions WriteOptions = new() { WriteIndented = true };

    private static string FilePath =>
        Path.Combine(Settings.AppDataDirectory(), "history.json");

    /// <summary>Path for the tray's "Open History" — pruned first, so what
    /// the user reads is never staler than the retention policy claims.</summary>
    public static string PathForViewing()
    {
        Prune();
        return FilePath;
    }

    public static void Add(string raw, string cleaned, string? app)
    {
        if (string.IsNullOrWhiteSpace(cleaned)) return;
        lock (Gate)
        {
            try
            {
                var entries = Load();
                entries.Insert(0, new Entry(DateTime.Now, raw, cleaned, app));
                Save(Trim(entries));
            }
            catch (Exception ex)
            {
                Log.Warn("Could not append to history: " + ex.Message);
            }
        }
    }

    /// <summary>Drops expired entries. Returns how many were removed.</summary>
    public static int Prune()
    {
        lock (Gate)
        {
            try
            {
                if (!File.Exists(FilePath)) return 0;
                var entries = Load();
                int before = entries.Count;
                var kept = Trim(entries);
                if (kept.Count == before) return 0;
                Save(kept);
                Log.Info($"History pruned: {before - kept.Count} expired, {kept.Count} kept " +
                         $"(retention {RetentionHours} h)");
                return before - kept.Count;
            }
            catch (Exception ex)
            {
                Log.Warn("History prune failed: " + ex.Message);
                return 0;
            }
        }
    }

    /// <summary>Deletes the history file outright.</summary>
    public static void Clear()
    {
        lock (Gate)
        {
            try
            {
                if (File.Exists(FilePath)) File.Delete(FilePath);
                Log.Info("History cleared");
            }
            catch (Exception ex)
            {
                Log.Warn("Could not clear history: " + ex.Message);
            }
        }
    }

    /// <summary>Number of entries currently retained (after pruning).</summary>
    public static int Count()
    {
        Prune();
        lock (Gate)
        {
            try { return Load().Count; }
            catch { return 0; }
        }
    }

    private static List<Entry> Load()
    {
        if (!File.Exists(FilePath)) return new List<Entry>();
        return JsonSerializer.Deserialize<List<Entry>>(File.ReadAllText(FilePath)) ?? new List<Entry>();
    }

    private static void Save(List<Entry> entries) =>
        File.WriteAllText(FilePath, JsonSerializer.Serialize(entries, WriteOptions));

    private static List<Entry> Trim(List<Entry> entries)
    {
        if (RetentionHours > 0)
        {
            var cutoff = DateTime.Now - TimeSpan.FromHours(RetentionHours);
            // Entries are written with a local timestamp and round-trip through
            // JSON with an offset, so Kind is Local; compare directly rather
            // than via ToLocalTime, which would misread an Unspecified Kind.
            entries = entries.Where(e => e.Date >= cutoff).ToList();
        }
        if (entries.Count > MaxEntries)
            entries.RemoveRange(MaxEntries, entries.Count - MaxEntries);
        return entries;
    }
}
