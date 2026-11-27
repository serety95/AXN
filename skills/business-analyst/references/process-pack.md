# Process pack template

Copy this shape per status / process. Keep labels quoted in mermaid.

## Chapter header

```markdown
### N.M `STATUS_CODE` — English / العربية

**المعنى.** One sentence: who works it and why it exists.

**منطق العمل / Business logic**

| | |
|---|---|
| **بيانات الملف** | Fields written (`status`, `channel_type`, SLA timestamps, flags). |
| **الدخول** | How a case arrives here (segmentation, outcome, scheduler, Log Action). |
| **قائمة العمل** | Endpoint + included? Sort key. Tabs. |
| **التواصل** | Window, attempt cap, blocked/ack, channels. |
| **SLA** | What happens on breach (flag vs reassign). Owner unchanged? |
| **مين يتصرف** | موظف التحصيل / المشرف / متخصص / وظيفة. |
| **الظهور** | قائمة التحصيل الهاتفي / ملفاتي الميدان / بحث بيانات / كانبان / محفظة / تقارير. |
| **التالي** | Allowed next statuses (from code, not guessed). |
```

## Process graph

Use a fenced `mermaid` block:

    flowchart TD
      actor["موظف: action"] --> gate{"قرار؟"}
      gate -->|"نعم"| ok["STATUS_CODE وصف"]
      gate -->|"لا"| block["403 كود الخطأ"]

Rules: quote `["…"]` / `{"…"}` / `|"…"|`. Never node ids `call`, `end`, `click`. Actors in the label (`موظف:` / `المشرف:`). Status AR from glossary (قيد التحقق، وعد متعثر، مُسند للميدان — never تحقيق / منتهك / مُحال).

## Drift findings

```markdown
## Findings
- [code] `Symbol` in `path` does X
- [doc] `docs/…` says Y
- [gap] mismatch / missing edge / stale label
```

## Queue visibility (optional matrix)

Columns: Call Queue · Field My-cases · specialist queue · Case Status Board · Portfolio · Reports. Mark **Yes** / listed+blocked / —.
