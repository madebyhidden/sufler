using System.IO.Compression;
using System.Security;
using System.Text;
using System.Text.RegularExpressions;
using System.Xml.Linq;
using UglyToad.PdfPig;

namespace Sufler;

public static class TextTools
{
    /// <summary>Доля общих слов — грубая, но быстрая мера похожести двух фраз.</summary>
    public static double Similarity(string a, string b)
    {
        static HashSet<string> Words(string s) => Regex.Split(s.ToLowerInvariant(), @"[^\p{L}\p{N}]+").Where(w => w.Length > 1).ToHashSet();
        var x = Words(a);
        var y = Words(b);
        if (x.Count == 0 || y.Count == 0) return 0;
        return (double)x.Intersect(y).Count() / Math.Min(x.Count, y.Count);
    }

    public static float Cosine(float[] a, float[] b)
    {
        if (a.Length != b.Length || a.Length == 0) return 0;
        float dot = 0, na = 0, nb = 0;
        for (int i = 0; i < a.Length; i++) { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i]; }
        return dot / (MathF.Sqrt(na * nb) + 1e-9f);
    }

    /// <summary>Списки со звёздочками и дефисами — аккуратными пунктами.</summary>
    public static string Tidy(string text) => string.Join("\n", text.Split('\n').Select(raw =>
    {
        var t = raw.Trim();
        return t.StartsWith("* ") || t.StartsWith("- ") ? "•  " + t[2..].Trim() : raw;
    }));

    /// <summary>Делит текст по строкам на части не длиннее size.</summary>
    public static List<string> SplitLines(string s, int size)
    {
        var list = new List<string>();
        var cur = new StringBuilder();
        foreach (var line in s.Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            if (cur.Length + line.Length > size && cur.Length > 0) { list.Add(cur.ToString()); cur.Clear(); }
            cur.Append(line).Append('\n');
        }
        if (cur.Length > 0) list.Add(cur.ToString());
        return list;
    }

    /// <summary>Режет текст на куски по абзацам; слишком длинные абзацы делит принудительно.</summary>
    public static List<string> Chunk(string text, int size)
    {
        var list = new List<string>();
        var cur = new StringBuilder();
        void Flush()
        {
            var t = cur.ToString().Trim();
            if (t.Length > 0) list.Add(t);
            cur.Clear();
        }
        foreach (var para in text.Split('\n'))
        {
            var p = para.Trim();
            if (p.Length == 0) continue;
            while (p.Length > size)
            {
                Flush();
                list.Add(p[..size]);
                p = p[size..];
            }
            if (cur.Length + p.Length > size) Flush();
            cur.Append(p).Append('\n');
        }
        Flush();
        return list;
    }

    public static string Tail(string s, int n) => s.Length <= n ? s : s[^n..];
    public static string Head(string s, int n) => s.Length <= n ? s : s[..n];

    /// <summary>Итог без разметки Markdown — для буфера обмена.</summary>
    public static string PlainSummary(string summary) => string.Join("\n", summary.Split('\n').Select(raw =>
    {
        var line = raw.Trim();
        if (line.StartsWith("- ") || line.StartsWith("* ")) line = "• " + line[2..].Trim();
        return line.Replace("**", "").TrimStart('#').Trim();
    }));

    /// <summary>
    /// Итог построчно для показа: (вид, текст). Вид: h — заголовок раздела, b — пункт списка, p — обычный абзац.
    /// Внутри текста «**так**» остаётся как пометка полужирного.
    /// </summary>
    public static List<(char Kind, string Text)> SummaryLines(string summary)
    {
        var list = new List<(char, string)>();
        foreach (var raw in summary.Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length == 0) continue;
            if (line.StartsWith("- ") || line.StartsWith("* ")) list.Add(('b', line[2..].Trim()));
            else if (line.StartsWith('#') || (line.StartsWith("**") && line.EndsWith("**") && line.Length > 4 && line.IndexOf("**", 2, StringComparison.Ordinal) == line.Length - 2))
                list.Add(('h', line.TrimStart('#').Replace("**", "").Trim()));
            else list.Add(('p', line));
        }
        return list;
    }
}

/// <summary>Чтение документов для базы знаний и сохранение итога в Word.</summary>
public static class Documents
{
    public const string Filter = "Документы|*.pdf;*.docx;*.odt;*.txt;*.md;*.html;*.htm;*.csv;*.json|Все файлы|*.*";

    public static string? ExtractText(string path)
    {
        try
        {
            var ext = Path.GetExtension(path).ToLowerInvariant();
            switch (ext)
            {
                case ".pdf":
                    using (var pdf = PdfDocument.Open(path))
                        // В PDF текст часто разбит лишними пробелами — убираем их
                        return Regex.Replace(string.Join("\n\n", pdf.GetPages().Select(p => UglyToad.PdfPig.DocumentLayoutAnalysis.TextExtractor.ContentOrderTextExtractor.GetText(p))), @"[ \t]{2,}", " ");
                case ".docx": return ZipXml(path, "word/document.xml", "p", "t", "tab", "br");
                case ".odt": return ZipXml(path, "content.xml", "p", "", "tab", "line-break");
                case ".html" or ".htm":
                    var html = ReadText(path);
                    html = Regex.Replace(html, @"<(script|style)[\s\S]*?</\1>", " ", RegexOptions.IgnoreCase);
                    html = Regex.Replace(html, @"<(br|/p|/div|/li|/h\d|/tr)[^>]*>", "\n", RegexOptions.IgnoreCase);
                    return System.Net.WebUtility.HtmlDecode(Regex.Replace(html, "<[^>]+>", " "));
                case ".doc" or ".rtf" or ".pages" or ".xlsx" or ".pptx": return null;
                default: return ReadText(path);
            }
        }
        catch { return null; }
    }

    private static string ReadText(string path)
    {
        var bytes = File.ReadAllBytes(path);
        try { return new UTF8Encoding(false, true).GetString(bytes).TrimStart('﻿'); }
        catch
        {
            Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
            return Encoding.GetEncoding(1251).GetString(bytes);
        }
    }

    /// <summary>Текст из документа-архива (Word, OpenDocument): абзацы — строками.</summary>
    private static string? ZipXml(string path, string entry, string para, string text, string tab, string br)
    {
        using var zip = ZipFile.OpenRead(path);
        var e = zip.GetEntry(entry);
        if (e is null) return null;
        using var s = e.Open();
        var doc = XDocument.Load(s);
        var sb = new StringBuilder();
        foreach (var p in doc.Descendants().Where(x => x.Name.LocalName == para))
        {
            // Вложенные абзацы (таблицы в OpenDocument) обойдём отдельно
            if (p.Ancestors().Any(a => a.Name.LocalName == para)) continue;
            foreach (var n in p.DescendantNodes())
            {
                if (n is XElement el)
                {
                    if (el.Name.LocalName == tab) sb.Append('\t');
                    else if (el.Name.LocalName == br) sb.Append('\n');
                    else if (text.Length > 0 && el.Name.LocalName == text) sb.Append(el.Value);
                }
                else if (text.Length == 0 && n is XText t) sb.Append(t.Value);
            }
            sb.Append('\n');
        }
        return sb.ToString();
    }

    /// <summary>Итог встречи как документ Word: название, дата, разделы и пункты.</summary>
    public static void SaveSummaryDocx(string path, Meeting m)
    {
        static string Runs(string text, bool bold, int halfPoints, string? color = null)
        {
            // Внутри строки «**так**» помечен полужирный
            var sb = new StringBuilder();
            var parts = text.Split("**");
            for (int i = 0; i < parts.Length; i++)
            {
                if (parts[i].Length == 0) continue;
                bool b = bold || i % 2 == 1;
                sb.Append("<w:r><w:rPr><w:rFonts w:ascii=\"Calibri\" w:hAnsi=\"Calibri\" w:cs=\"Calibri\"/>");
                if (b) sb.Append("<w:b/>");
                if (color is not null) sb.Append($"<w:color w:val=\"{color}\"/>");
                sb.Append($"<w:sz w:val=\"{halfPoints}\"/></w:rPr><w:t xml:space=\"preserve\">{SecurityElement.Escape(parts[i])}</w:t></w:r>");
            }
            return sb.ToString();
        }
        static string Para(string runs, int before = 0, bool bullet = false) =>
            $"<w:p><w:pPr><w:spacing w:before=\"{before}\" w:after=\"80\"/>{(bullet ? "<w:ind w:left=\"360\" w:hanging=\"360\"/>" : "")}</w:pPr>{runs}</w:p>";

        var body = new StringBuilder();
        body.Append(Para(Runs(m.Title, true, 36)));
        body.Append(Para(Runs(m.StartedAt.ToString("d MMMM yyyy, HH:mm", Ru.Culture), false, 20, "666666")));
        foreach (var (kind, text) in TextTools.SummaryLines(m.Summary))
        {
            if (kind == 'b') body.Append(Para("<w:r><w:rPr><w:sz w:val=\"24\"/></w:rPr><w:t>•</w:t><w:tab/></w:r>" + Runs(text, false, 24), 0, true));
            else if (kind == 'h') body.Append(Para(Runs(text, true, 26), 200));
            else body.Append(Para(Runs(text, false, 24), text.StartsWith("**") ? 200 : 0));
        }

        const string ns = "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"";
        var files = new Dictionary<string, string>
        {
            ["[Content_Types].xml"] = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/></Types>",
            ["_rels/.rels"] = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>",
            ["word/document.xml"] = $"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:document {ns}><w:body>{body}<w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/><w:pgMar w:top=\"1134\" w:right=\"1134\" w:bottom=\"1134\" w:left=\"1134\" w:header=\"708\" w:footer=\"708\" w:gutter=\"0\"/></w:sectPr></w:body></w:document>",
        };
        if (File.Exists(path)) File.Delete(path);
        using var zip = ZipFile.Open(path, ZipArchiveMode.Create);
        foreach (var (name, content) in files)
        {
            using var w = new StreamWriter(zip.CreateEntry(name).Open(), new UTF8Encoding(false));
            w.Write(content);
        }
    }
}
