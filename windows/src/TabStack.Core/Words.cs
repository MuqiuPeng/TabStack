namespace TabStack.Core;

public static class Words
{
    /// <summary>Whether <paramref name="text"/> has <paramref name="word"/> as a word of its own
    /// (so "TabStack" is not found in "TabStackOverflow"), ignoring case.</summary>
    public static bool Has(string? text, string word)
    {
        if (string.IsNullOrEmpty(text) || word.Length == 0) return false;
        for (var i = text.IndexOf(word, StringComparison.OrdinalIgnoreCase); i >= 0;
             i = text.IndexOf(word, i + 1, StringComparison.OrdinalIgnoreCase))
        {
            var before = i == 0 || !char.IsLetterOrDigit(text[i - 1]);
            var end = i + word.Length;
            var after = end == text.Length || !char.IsLetterOrDigit(text[end]);
            if (before && after) return true;
        }
        return false;
    }
}
