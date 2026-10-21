using System.Text;
using System.Text.Json.Nodes;

namespace Sufler;

public sealed partial class AppCore
{
    /// <summary>Векторы кусков открытой встречи — чтобы чат искал по всей расшифровке и не считал их заново.</summary>
    private readonly Dictionary<string, float[]> _meetingVectors = new();

    private static JsonNode Schema(string json) => JsonNode.Parse(json)!;

    private async Task<float[]> EmbedFact(string text)
    {
        try { return (await _llm.Embed(["title: none | text: " + text])).FirstOrDefault() ?? []; }
        catch { return []; }
    }

    private string FactMeta(Fact f)
    {
        var s = (f.Previous.Length == 0 ? "добавлен " : "обновлён ") + f.UpdatedAt.ToString("d MMM", Ru.Culture);
        var m = Meetings.FirstOrDefault(x => x.Id == f.MeetingId);
        if (m is not null) s += " · " + m.Title; else if (f.MeetingId == 0) s += " · вручную";
        return s;
    }

    private void PutFirst(Fact f)
    {
        f.Meta = FactMeta(f);
        Facts.Remove(f);
        Facts.Insert(0, f);
    }

    // MARK: Факты

    /// <summary>После встречи: вытаскиваем долговечные факты и сверяем с базой — новое добавляем, изменившееся заменяем.</summary>
    public async Task ExtractFacts(Meeting m)
    {
        if (!LlmReady || !EmbedReady) return;
        var text = Transcript(m.Id);
        if (text.Split('\n').Length < 2) return;
        if (text.Length > _budget) text = m.Summary + "\n\nКонец расшифровки:\n" + TextTools.Tail(text, _budget * 2 / 3);
        KbStatus = "Ищу факты во встрече…";
        try
        {
            const string system = """
                Ты ведёшь базу знаний владельца приложения. Из расшифровки встречи выдели долговечные факты — то, что будет полезно помнить через недели и месяцы:
                цифры и метрики («сервис раскатили на 15 тысяч пользователей»), принятые решения, сроки и даты, кто за что отвечает, договорённости, параметры проектов и продуктов.
                Каждый факт — одно самостоятельное предложение, понятное без самой встречи: с названиями, именами и числами, без «он», «это», «там».
                Не включай: мнения и эмоции, ход обсуждения, вопросы без ответа, сиюминутное («сейчас посмотрю»), догадки и то, в чём говорящие не уверены.
                Если таких фактов нет — верни пустой список. Не больше 8 фактов. Ничего не выдумывай.
                """;
            var schema = Schema("""{"type":"object","properties":{"facts":{"type":"array","items":{"type":"string"}}},"required":["facts"],"additionalProperties":false}""");
            var o = await _llm.ChatJson(system, text, schema, 700);
            if (o?["facts"] is not JsonArray found) return;
            foreach (var f in found.Take(8))
            {
                var t = (f?.GetValue<string>() ?? "").Trim();
                if (t.Length >= 10) await MergeFact(t, m.Id);
            }
        }
        catch (Exception ex) { Log("факты: " + ex.Message); }
        finally { KbStatus = ""; }
    }

    /// <summary>Кладёт факт в базу: если там уже есть про то же самое — заменяет или пропускает.</summary>
    private async Task MergeFact(string text, long meetingId)
    {
        var v = await EmbedFact(text);
        if (v.Length == 0) return;
        var near = Facts.Select(f => (Fact: f, Sim: TextTools.Cosine(f.Vector, v))).Where(x => x.Sim > 0.5).OrderByDescending(x => x.Sim).Take(4).Select(x => x.Fact).ToList();
        if (near.Count == 0)
        {
            PutFirst(_store.AddFact(text, meetingId, v));
            return;
        }
        const string system = """
            Ты ведёшь базу фактов. Пришёл новый факт, в базе есть похожие. Реши, что делать:
            - add — в базе нет факта о том же самом, это новая информация;
            - update — новый факт о том же самом предмете, что и один из существующих, но значение изменилось или стало точнее (другое число, другой срок, другой ответственный): верни id заменяемого факта и итоговый текст с актуальным значением;
            - skip — в базе уже есть то же самое.
            Если новый факт о другом предмете, пусть и из той же темы, — это add. В тексте используй только числа и имена из нового факта.
            """;
        var user = $"Новый факт: {text}\n\nПохожие факты в базе:\n" + string.Join("\n", near.Select(f => $"[{f.Id}] {f.Text}"));
        var schema = Schema("""{"type":"object","properties":{"op":{"type":"string","enum":["add","update","skip"]},"id":{"type":"integer"},"text":{"type":"string"}},"required":["op","id","text"],"additionalProperties":false}""");
        var o = await _llm.ChatJson(system, user, schema, 200);
        var op = o?["op"]?.GetValue<string>();
        if (op == "skip") return;
        if (op == "update")
        {
            long fid = o?["id"]?.GetValue<long>() ?? 0;
            var newText = (o?["text"]?.GetValue<string>() ?? "").Trim();
            if (near.FirstOrDefault(f => f.Id == fid) is { } target)
            {
                // Модель иногда вписывает в итоговый текст число, которого не было ни в старом, ни в новом факте.
                // Такому тексту не верим и берём новый факт как есть
                var known = Numbers(text).Concat(Numbers(target.Text)).ToHashSet();
                if (newText.Length < 10 || Numbers(newText).Any(n => !known.Contains(n))) newText = text;
                await ApplyOps([new FactOp { Op = "update", FactId = fid, Text = newText }], meetingId);
                return;
            }
        }
        PutFirst(_store.AddFact(text, meetingId, v));
    }

    private static IEnumerable<string> Numbers(string s) => System.Text.RegularExpressions.Regex.Matches(s, @"\d+").Select(m => m.Value);

    /// <summary>Применяет изменения к базе фактов. Возвращает то, что реально сделано (с прежним текстом).</summary>
    public async Task<List<FactOp>> ApplyOps(IEnumerable<FactOp> ops, long meetingId = 0)
    {
        var done = new List<FactOp>();
        foreach (var op in ops.ToList())
        {
            var text = op.Text.Trim();
            var f = Facts.FirstOrDefault(x => x.Id == op.FactId);
            switch (op.Op)
            {
                case "add":
                    if (text.Length < 5) continue;
                    PutFirst(_store.AddFact(text, meetingId, await EmbedFact(text)));
                    break;
                case "update":
                    if (text.Length < 5 || f is null || text == f.Text) continue;
                    op.Old = f.Text;
                    f.Previous = f.Text;
                    f.Text = text;
                    f.UpdatedAt = DateTime.Now;
                    if (meetingId != 0) f.MeetingId = meetingId;
                    f.Vector = await EmbedFact(text);
                    _store.UpdateFact(f);
                    PutFirst(f);
                    break;
                case "delete":
                    if (f is null) continue;
                    op.Old = f.Text;
                    _store.DeleteFact(f.Id);
                    Facts.Remove(f);
                    break;
                default: continue;
            }
            done.Add(op);
        }
        return done;
    }

    public void DeleteFact(Fact f)
    {
        _store.DeleteFact(f.Id);
        Facts.Remove(f);
    }

    /// <summary>Подтверждение изменений, предложенных ревизией.</summary>
    public async Task ApplyProposal(ChatLine line)
    {
        if (!line.OpsPending) return;
        line.OpsPending = false;
        var done = await ApplyOps(line.Ops);
        line.Ops.Clear();
        foreach (var d in done) line.Ops.Add(d);
        line.Text += $"\n\nПрименено изменений: {done.Count}.";
    }

    public void RejectProposal(ChatLine line)
    {
        line.OpsPending = false;
        line.Ops.Clear();
        line.Text += "\n\nИзменения отклонены, база не тронута.";
    }

    private async Task<string> KbIntent(string q)
    {
        const string system = """
            Определи, чего хочет пользователь от базы знаний:
            - answer — задаёт вопрос или просит что-то найти, рассказать, сравнить;
            - edit — просит добавить, запомнить, изменить, исправить или удалить факт («запомни, что…», «исправь: теперь 100 тысяч», «удали факт про…»);
            - audit — просит проверить, почистить, провести ревизию или аудит фактов на актуальность и нужность.
            """;
        var schema = Schema("""{"type":"object","properties":{"intent":{"type":"string","enum":["answer","edit","audit"]}},"required":["intent"],"additionalProperties":false}""");
        var o = await _llm.ChatJson(system, q, schema, 20, 0);
        return o?["intent"]?.GetValue<string>() ?? "answer";
    }

    /// <summary>Прямая просьба изменить факты — выполняем сразу.</summary>
    private async Task EditFacts(string q, ChatLine reply)
    {
        var pool = Facts.ToList();
        if (pool.Count > 30)
        {
            var qv = await EmbedFact(q);
            pool = Facts.OrderByDescending(f => TextTools.Cosine(f.Vector, qv)).Take(20).ToList();
        }
        const string system = """
            Пользователь просит изменить базу фактов. Выполни просьбу операциями:
            - add — добавить новый факт (text; id = 0);
            - update — заменить текст существующего факта (id и новый text целиком);
            - delete — удалить факт (id; text пустой).
            Каждый факт — одно самостоятельное предложение с названиями и числами. Меняй только то, о чём просят. Если непонятно, какой факт имеется в виду, ничего не меняй и спроси в reply.
            reply — одна-две фразы: что сделано.
            """;
        var user = "Факты в базе:\n" + (pool.Count == 0 ? "(пусто)" : string.Join("\n", pool.Select(f => $"[{f.Id}] {f.Text}"))) + $"\n\nПросьба: {q}";
        var schema = Schema("""{"type":"object","properties":{"reply":{"type":"string"},"ops":{"type":"array","items":{"type":"object","properties":{"op":{"type":"string","enum":["add","update","delete"]},"id":{"type":"integer"},"text":{"type":"string"}},"required":["op","id","text"],"additionalProperties":false}}},"required":["reply","ops"],"additionalProperties":false}""");
        var o = await _llm.ChatJson(system, user, schema, 700);
        if (o is null)
        {
            reply.Text = "Не получилось разобрать просьбу — попробуйте сформулировать иначе.";
            return;
        }
        var ops = new List<FactOp>();
        foreach (var x in o["ops"] as JsonArray ?? [])
        {
            var op = x?["op"]?.GetValue<string>();
            long fid = x?["id"]?.GetValue<long>() ?? 0;
            if (op is null || (op != "add" && pool.All(f => f.Id != fid))) continue;
            ops.Add(new FactOp { Op = op, FactId = fid, Text = x?["text"]?.GetValue<string>() ?? "", Old = pool.FirstOrDefault(f => f.Id == fid)?.Text ?? "" });
        }
        var done = await ApplyOps(ops);
        reply.Text = o["reply"]?.GetValue<string>() is { Length: > 0 } r ? r : done.Count == 0 ? "Ничего не изменил." : "Готово.";
        foreach (var d in done) reply.Ops.Add(d);
    }

    /// <summary>Ревизия фактов: модель только предлагает, применяет пользователь кнопкой.
    /// Идём в два прохода: по каждому факту — нужен ли он вообще, затем по похожим парам — дубль или устаревшее.</summary>
    private async Task AuditFacts(ChatLine reply)
    {
        if (Facts.Count == 0) { reply.Text = "В базе пока нет фактов — проверять нечего."; return; }
        var ops = new List<FactOp>();
        var dropped = new HashSet<long>();

        // 1. Нужность. Вердикт требуем по каждому факту — иначе маленькая модель отвечает «всё хорошо», не вчитываясь
        var system = $"""
            Ты проверяешь базу знаний рабочих встреч. Сегодня {DateTime.Now:dd.MM.yyyy}. Для КАЖДОГО факта из списка вынеси вердикт:
            - keep — полезно помнить через недели и месяцы: цифры и метрики, решения, сроки, ответственные, договорённости, параметры проектов;
            - drop — не нужно хранить: погода, настроение, бытовое и сиюминутное, мнение вместо факта, обрывок без смысла, непонятное без контекста, срок, который давно прошёл.
            reason — причина в нескольких словах.
            """;
        var schema = Schema("""{"type":"object","properties":{"items":{"type":"array","items":{"type":"object","properties":{"id":{"type":"integer"},"verdict":{"type":"string","enum":["keep","drop"]},"reason":{"type":"string"}},"required":["id","verdict","reason"],"additionalProperties":false}}},"required":["items"],"additionalProperties":false}""");
        var sorted = Facts.OrderBy(f => f.UpdatedAt).ToList();
        for (int start = 0; start < sorted.Count; start += 20)
        {
            var batch = sorted.Skip(start).Take(20).ToList();
            reply.Text = $"Проверяю нужность: {start + batch.Count} из {sorted.Count}…";
            var user = string.Join("\n", batch.Select(f => $"[{f.Id}] ({f.UpdatedAt:dd.MM.yyyy}) {f.Text}"));
            var o = await _llm.ChatJson(system, user, schema, 1500);
            foreach (var it in o?["items"] as JsonArray ?? [])
            {
                if (it?["verdict"]?.GetValue<string>() != "drop") continue;
                long fid = it["id"]?.GetValue<long>() ?? 0;
                var f = batch.FirstOrDefault(x => x.Id == fid);
                if (f is null || !dropped.Add(fid)) continue;
                ops.Add(new FactOp { Op = "delete", FactId = fid, Old = f.Text, Reason = "Не нужен: " + (it["reason"]?.GetValue<string>() ?? "") });
            }
        }

        // 2. Дубли и устаревшее: сравниваем только похожие по смыслу пары
        const string pairSystem = """
            Сравни два факта из базы знаний:
            - same — говорят одно и то же разными словами;
            - conflict — об одном и том же, но значения расходятся (разные числа, даты, ответственные);
            - different — о разном, оба нужны.
            """;
        var pairSchema = Schema("""{"type":"object","properties":{"relation":{"type":"string","enum":["same","conflict","different"]}},"required":["relation"],"additionalProperties":false}""");
        var alive = sorted.Where(f => !dropped.Contains(f.Id)).ToList();
        var pairs = new List<(Fact Older, Fact Newer)>();
        for (int i = 0; i < alive.Count; i++)
            for (int j = i + 1; j < alive.Count; j++)
                if (TextTools.Cosine(alive[i].Vector, alive[j].Vector) > 0.72) pairs.Add((alive[i], alive[j]));
        int total = Math.Min(pairs.Count, 40);
        for (int n = 0; n < total; n++)
        {
            var (older, newer) = pairs[n];
            if (dropped.Contains(older.Id) || dropped.Contains(newer.Id)) continue;
            reply.Text = $"Ищу дубли: {n + 1} из {total}…";
            var user = $"Факт А ({older.UpdatedAt:dd.MM.yyyy}): {older.Text}\nФакт Б ({newer.UpdatedAt:dd.MM.yyyy}): {newer.Text}";
            var rel = (await _llm.ChatJson(pairSystem, user, pairSchema, 20, 0))?["relation"]?.GetValue<string>();
            if (rel != "same" && rel != "conflict") continue;
            dropped.Add(older.Id);
            ops.Add(new FactOp { Op = "delete", FactId = older.Id, Old = older.Text, Reason = rel == "same" ? $"Дубль факта: «{newer.Text}»" : $"Устарел: есть более свежий факт «{newer.Text}»" });
        }

        reply.Text = $"Проверил фактов: {Facts.Count}." + (ops.Count == 0
            ? " Лишнего, дублей и устаревшего не нашёл."
            : $" Предлагаю удалить: {ops.Count}. Посмотрите список и подтвердите — без этого база не изменится.");
        foreach (var op in ops) reply.Ops.Add(op);
        reply.OpsPending = ops.Count > 0;
    }

    // MARK: Итог и поиск

    public async Task Summarize(Meeting m)
    {
        if (!LlmReady || Summarizing) return;
        var text = Transcript(m.Id);
        if (text.Split('\n').Length < 2) return;
        Summarizing = true;
        try
        {
            // Длинную встречу сжимаем по частям, затем собираем итог
            var parts = TextTools.SplitLines(text, _budget);
            if (parts.Count > 1)
            {
                var digests = new List<string>();
                foreach (var p in parts)
                    digests.Add(await _llm.Chat([
                        new("system", "Сожми фрагмент расшифровки встречи в 5–8 пунктов: факты, решения, задачи, вопросы. Только по тексту, на русском."),
                        new("user", p),
                    ], null, 500));
                parts = [TextTools.Head(string.Join("\n", digests), _budget)];
            }
            const string system = """
                Ты составляешь итог встречи по расшифровке (в ней возможны ошибки распознавания). «Я» — владелец приложения. Пиши на русском, только по тексту, ничего не выдумывай. Формат Markdown:
                **Коротко** — 2–3 предложения.
                **Решения** — список.
                **Задачи** — список «кто — что».
                **Открытые вопросы** — список.
                Пустые разделы пропускай.
                """;
            var user = "Расшифровка:\n" + parts[0];
            if (m.Notes.Length > 0) user += "\n\nЗаметки владельца:\n" + m.Notes;
            // Итог пишем на глазах: на слабом компьютере он составляется долго, и видно, что работа идёт
            var acc = new StringBuilder();
            string before = m.Summary;
            try
            {
                await foreach (var piece in _llm.ChatStream([new("system", system), new("user", user)], 900, 0.2))
                {
                    acc.Append(piece);
                    m.Summary = acc.ToString();
                }
            }
            catch { m.Summary = before; throw; }
            m.Summary = acc.ToString().Trim();
            if (m.Title.StartsWith("Встреча "))
            {
                var title = await _llm.Chat([
                    new("system", "Придумай название встречи: 3–6 слов на русском, без кавычек и точки в конце. Верни только название."),
                    new("user", m.Summary),
                ], null, 30);
                var t = title.Trim(' ', '\n', '"', '«', '»', '.', '*', '#');
                if (t.Length > 0 && t.Length < 80 && !t.Contains('\n')) m.Title = t;
            }
            _store.Update(m);
        }
        catch (Exception ex) { ErrorText = "Итог не составился: " + ex.Message; }
        finally { Summarizing = false; }
    }

    private async Task Index(Meeting m)
    {
        if (!EmbedReady) return;
        var head = $"Встреча «{m.Title}», {m.StartedAt.ToString("d MMMM yyyy", Ru.Culture)}\n";
        var pieces = TextTools.SplitLines(Transcript(m.Id), 700).Select(p => head + p).ToList();
        if (m.Summary.Length > 0) pieces.Add(head + "Итог:\n" + m.Summary);
        if (m.Notes.Length > 0) pieces.Add(head + "Заметки:\n" + m.Notes);
        if (pieces.Count == 0) return;
        try { _store.ReplaceChunks(m.Id, await EmbedAll(pieces, null)); }
        catch (Exception ex) { Log("индекс встречи: " + ex.Message); }
    }

    private async Task<List<(string, float[])>> EmbedAll(List<string> pieces, Action<int>? progress)
    {
        var rows = new List<(string, float[])>();
        for (int start = 0; start < pieces.Count; start += 8)
        {
            progress?.Invoke(start * 100 / pieces.Count);
            var batch = pieces.Skip(start).Take(8).ToList();
            // Модель поиска читает не больше 2048 токенов — длинные куски подрезаем
            var vecs = await _llm.Embed(batch.Select(t => "title: none | text: " + TextTools.Head(t, 1800)).ToList());
            for (int i = 0; i < batch.Count && i < vecs.Count; i++) rows.Add((batch[i], vecs[i]));
        }
        return rows;
    }

    /// <summary>Поиск по базе: документы, прошлые встречи и факты. Возвращает фрагмент и название источника.</summary>
    private async Task<List<(string Text, string Source)>> Retrieve(string query, int limit)
    {
        if (!EmbedReady) return [];
        float[] qv;
        try { qv = (await _llm.Embed(["task: search result | query: " + query])).FirstOrDefault() ?? []; } catch { return []; }
        if (qv.Length == 0) return [];
        var chunks = await Task.Run(() => _store.AllChunks().Select(c => (c.Text, c.Source, Sim: TextTools.Cosine(c.Vector, qv))).ToList());
        var all = chunks.Concat(Facts.Select(f => (Text: "Факт: " + f.Text, Source: "Факты", Sim: TextTools.Cosine(f.Vector, qv) + 0.05f)));
        return all.Where(x => x.Sim > 0.3).OrderByDescending(x => x.Sim).Take(limit).Select(x => (x.Text, x.Source)).ToList();
    }

    // MARK: База знаний

    public async Task AddDocuments(IEnumerable<string> paths)
    {
        if (!EmbedReady) { ErrorText = "Модель поиска ещё загружается — попробуйте через несколько секунд."; return; }
        foreach (var path in paths)
        {
            var title = Path.GetFileName(path);
            KbStatus = $"Читаю «{title}»…";
            var text = await Task.Run(() => Documents.ExtractText(path));
            if (text is null || text.Trim().Length <= 20)
            {
                ErrorText = $"Не удалось прочитать текст из «{title}». Подходят PDF, Word (.docx), текст, Markdown, HTML.";
                continue;
            }
            var pieces = TextTools.Chunk(text, 900).Select(p => $"Документ «{title}»\n" + p).ToList();
            List<(string, float[])> rows;
            try { rows = await EmbedAll(pieces, pct => KbStatus = $"Индексирую «{title}»: {pct}%"); }
            catch (Exception ex)
            {
                ErrorText = $"Не удалось проиндексировать «{title}»: " + ex.Message;
                continue;
            }
            var doc = _store.AddDocument(title, path, text.Length);
            _store.AddDocChunks(doc.Id, rows);
            Docs.Insert(0, doc);
        }
        KbStatus = "";
    }

    public void DeleteDocument(Doc d)
    {
        _store.DeleteDocument(d.Id);
        Docs.Remove(d);
    }

    // MARK: Чат

    public async Task Ask(string text)
    {
        Count("chat_questions");
        var q = text.Trim();
        if (!LlmReady || q.Length == 0 || ChatBusy) return;
        Chat.Add(new ChatLine { Role = "user", Text = q });
        var reply = new ChatLine { Role = "assistant" };
        Chat.Add(reply);
        ChatBusy = true;
        try
        {
            // В базе знаний чат умеет не только отвечать, но и править факты и проводить их ревизию
            if (ShowKb)
            {
                var intent = await KbIntent(q);
                if (intent == "edit") { await EditFacts(q, reply); return; }
                if (intent == "audit") { await AuditFacts(reply); return; }
            }
            string system;
            if (!ShowKb && Selected is { } m)
            {
                // Чат внутри встречи отвечает только по ней самой — по всей расшифровке, итогу и заметкам.
                // Уточняющий вопрос («и что решили?») сам по себе ни о чём: ищем по нему вместе с предыдущим обменом
                var before = string.Join(" ", Chat.Take(Chat.Count - 2).TakeLast(2).Select(l => TextTools.Head(l.Text, 300)));
                var ctx = await MeetingContext(before.Length == 0 ? q : before + " " + q, m);
                system = "Ты помощник по одной встрече владельца приложения. «Я» в расшифровке — владелец. Отвечай на русском, кратко и по делу, опираясь только на расшифровку, итог и заметки этой встречи ниже. Расшифровка автоматическая, в ней бывают ошибки распознавания. Если ответа во встрече нет — так и скажи. Это продолжающийся разговор: короткий уточняющий вопрос («и что обсудили?», «а кто?») относится к теме твоего предыдущего ответа, а не ко всей встрече.\n\n" + ctx + InterviewContext();
            }
            else
            {
                var found = await Retrieve(q, _budget >= 7000 ? 8 : 5);
                foreach (var src in found.Select(x => x.Source).Where(s => s.Length > 0).Distinct().Take(4)) reply.Sources.Add(src);
                var ctx = found.Count > 0 ? "Найдено в базе знаний и прошлых встречах:\n" + string.Join("\n---\n", found.Select(x => x.Text)) : "";
                system = "Ты помощник владельца приложения по его документам и встречам. Отвечай на русском, кратко и по делу, опираясь только на данные ниже; где уместно, называй документ или встречу, откуда взят факт. Если в данных ответа нет — так и скажи.\n\n" + ctx;
            }
            var msgs = new List<ChatMessage> { new("system", system) };
            foreach (var line in Chat.Take(Chat.Count - 1).TakeLast(8)) msgs.Add(new(line.Role, line.Text));
            var acc = new StringBuilder();
            await foreach (var piece in _llm.ChatStream(msgs))
            {
                acc.Append(piece);
                reply.Text = acc.ToString();
            }
        }
        catch (Exception ex) { reply.Text = "Ошибка: " + ex.Message; }
        finally
        {
            if (reply.Text.Length == 0) reply.Text = "Не получилось ответить — попробуйте ещё раз.";
            ChatBusy = false;
        }
    }

    /// <summary>Что показать модели для вопроса по встрече. Короткая встреча уходит целиком;
    /// из длинной берём куски, подходящие к вопросу, и самый конец разговора.</summary>
    private async Task<string> MeetingContext(string q, Meeting m)
    {
        var ctx = new StringBuilder($"Встреча «{m.Title}», {m.StartedAt.ToString("d MMMM yyyy, HH:mm", Ru.Culture)}.\n");
        if (m.Summary.Length > 0) ctx.Append($"\nИтог:\n{TextTools.Head(m.Summary, 2500)}\n");
        if (m.Notes.Length > 0) ctx.Append($"\nЗаметки владельца:\n{TextTools.Head(m.Notes, 1500)}\n");
        var full = string.Join("\n", Turns.Select(t => $"{t.Label}: {t.Text}"));
        if (full.Length == 0) return ctx + "\nРасшифровки пока нет.";
        if (full.Length <= _budget) return ctx + "\nПолная расшифровка:\n" + full;

        // Сколько кусков расшифровки поместится в окно модели вместе с концом разговора
        int take = Math.Max(3, (_budget - 2200) / 900);
        var tail = TextTools.Tail(full, 2200);
        var pieces = TextTools.Chunk(full, 800);
        var picked = new List<string>();
        if (EmbedReady)
        {
            try
            {
                // Последний кусок ещё растёт во время записи — его не кэшируем
                var missing = pieces.Take(pieces.Count - 1).Where(p => !_meetingVectors.ContainsKey(p)).ToList();
                for (int start = 0; start < missing.Count; start += 8)
                {
                    var batch = missing.Skip(start).Take(8).ToList();
                    var vecs = await _llm.Embed(batch.Select(t => "title: none | text: " + t).ToList());
                    for (int i = 0; i < batch.Count && i < vecs.Count; i++) _meetingVectors[batch[i]] = vecs[i];
                }
                var qv = (await _llm.Embed(["task: search result | query: " + q])).FirstOrDefault();
                if (qv is not null)
                    picked = pieces.Select((t, i) => (Index: i, Text: t)).Where(x => _meetingVectors.ContainsKey(x.Text))
                        .OrderByDescending(x => TextTools.Cosine(_meetingVectors[x.Text], qv)).Take(take).OrderBy(x => x.Index).Select(x => x.Text).ToList();
            }
            catch { }
        }
        if (picked.Count == 0) return ctx + "\nКонец расшифровки (встреча длинная, начало не поместилось):\n" + TextTools.Tail(full, _budget - 500);
        return ctx + "\nФрагменты расшифровки, подходящие к вопросу (по порядку):\n" + string.Join("\n…\n", picked) + "\n\nКонец расшифровки:\n" + tail;
    }

    // MARK: Итог: копирование и экспорт

    /// <summary>Итог встречи простым текстом, с названием — для буфера обмена.</summary>
    public string SummaryForClipboard() => Selected is { Summary.Length: > 0 } m ? m.Title + "\n\n" + TextTools.PlainSummary(m.Summary) : "";
}
