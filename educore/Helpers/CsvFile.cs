using System.Text;

namespace educore.Helpers
{
    /// <summary>
    /// Plain CSV in and out for School > Import Data. Excel saves a sheet as
    /// "CSV UTF-8", so no Excel library is needed: a value in quotes may hold
    /// commas, line breaks and "" for a quote mark.
    /// </summary>
    public static class CsvFile
    {
        /// <summary>Rows as header -> value (headers compared without case or spaces).</summary>
        public static List<Dictionary<string, string>> Read(string text)
        {
            var lines = Parse(text);
            var result = new List<Dictionary<string, string>>();
            if (lines.Count == 0) return result;

            var headers = lines[0].Select(Key).ToList();
            foreach (var line in lines.Skip(1))
            {
                if (line.All(string.IsNullOrWhiteSpace)) continue;     // blank row
                var row = new Dictionary<string, string>();
                for (int i = 0; i < headers.Count; i++)
                    if (headers[i].Length > 0)
                        row[headers[i]] = i < line.Count ? line[i].Trim() : string.Empty;
                result.Add(row);
            }
            return result;
        }

        /// <summary>"Date of Birth" -> "dateofbirth", the key a column is looked up by.</summary>
        public static string Key(string header) =>
            new string((header ?? string.Empty).Where(char.IsLetterOrDigit).ToArray()).ToLowerInvariant();

        /// <summary>A file with a header line and the given rows, ready to open in Excel.</summary>
        public static byte[] Write(IEnumerable<string> headers, IEnumerable<IEnumerable<string>> rows)
        {
            var sb = new StringBuilder();
            sb.AppendLine(string.Join(",", headers.Select(Quote)));
            foreach (var r in rows)
                sb.AppendLine(string.Join(",", r.Select(Quote)));
            // BOM first, so Excel reads the file as UTF-8 (names in Hindi stay readable)
            return Encoding.UTF8.GetPreamble().Concat(Encoding.UTF8.GetBytes(sb.ToString())).ToArray();
        }

        private static string Quote(string v)
        {
            v ??= string.Empty;
            return v.IndexOfAny(new[] { ',', '"', '\n', '\r' }) >= 0 ? "\"" + v.Replace("\"", "\"\"") + "\"" : v;
        }

        private static List<List<string>> Parse(string text)
        {
            var lines = new List<List<string>>();
            var line = new List<string>();
            var cell = new StringBuilder();
            bool quoted = false;
            text = (text ?? string.Empty).TrimStart('﻿');

            for (int i = 0; i < text.Length; i++)
            {
                char c = text[i];
                if (quoted)
                {
                    if (c == '"' && i + 1 < text.Length && text[i + 1] == '"') { cell.Append('"'); i++; }
                    else if (c == '"') quoted = false;
                    else cell.Append(c);
                }
                else if (c == '"') quoted = true;
                else if (c == ',') { line.Add(cell.ToString()); cell.Clear(); }
                else if (c == '\n' || c == '\r')
                {
                    if (c == '\r' && i + 1 < text.Length && text[i + 1] == '\n') i++;
                    line.Add(cell.ToString()); cell.Clear();
                    lines.Add(line); line = new List<string>();
                }
                else cell.Append(c);
            }
            if (cell.Length > 0 || line.Count > 0) { line.Add(cell.ToString()); lines.Add(line); }
            return lines;
        }
    }
}
