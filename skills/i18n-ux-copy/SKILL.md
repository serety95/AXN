---
name: i18n-ux-copy
description: Writes operator-facing localized UX copy from business meaning and a canonical glossary rather than literal English translation. Use when editing i18n translation files, nav labels, statuses, dispositions, diagram labels, or when the user asks for localized UX wording or glossary alignment.
---

# Glossary-Driven i18n UX Copy

**Business meaning -> operator copy.** Never literal-translate English UI strings word-for-word.

## Workflow

1. **Locate canonical glossary & catalogs**: Check the repository for `docs/*glossary*.md`, i18n locale files (e.g., `translations.ts`, `locales/*.json`), status catalogs, and diagram sources.
2. **Match surface length**:
   - Keep badges, navigation items, and diagram node labels concise.
   - Reserve longer explanatory phrasing for tooltips, helper text, and confirmation modals.
3. **Update all linked surfaces together**: When changing a status or disposition label, update the locale file, status catalog, diagram labels, and any generated label maps in one atomic change, then run the repo's sync/codegen command if present. Never hand-edit generated files.
4. **Enforce glossary consistency**: Never invent ad-hoc synonyms for established domain terms. If a term is missing, add it to the project glossary first.

## Example: Arabic / RTL Operator Copy Pattern

When authoring Arabic operator copy (e.g., for operations/collections workflows):
- Prefer concise domain-accurate forms (e.g., `قيد التحقق`, `وعد متعثر`, `سداد معلّق`, `مُسند للميدان`, `بحث بيانات`, `عجز مؤكد`, `شطب معلّق`) over literal word-for-word English calques.
- Keep graph actor prefixes short (`موظف:`, `المشرف:`, `جامع:`, `المحقق:`) while using full role titles in product UI copy.
