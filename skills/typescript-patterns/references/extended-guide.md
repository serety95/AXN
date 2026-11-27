# typescript-patterns — Extended Reference

## Null and Undefined Discipline

Prefer a discriminated approach over mixing sentinel values. Where "not found" or "absent" is a legitimate state, use `T | undefined` and check explicitly; avoid deeply nesting `?.` chains followed by silent fallbacks that hide bugs.

```typescript
function findUser(id: string): User | undefined {
  return users.get(id)
}

const user = findUser('u_1')
if (user === undefined) {
  return notFound()
}
// from here on, `user` is narrowed to User
```

Avoid truthiness checks that silently accept wrong types (`if (result)` when `result` may be `0` or `''`). Compare against `undefined`/`null` explicitly.

## Module Boundaries and Exports

### Small, Named Modules

Expose a deliberate surface at each module's boundary. Prefer explicit named exports over default exports, and re-export at the public edge so consumers import from the module that owns the type — not from deep internals that can be refactored.

```typescript
// user/model.ts — internal types
export interface UserAccount {
  id: string
  email: string
  role: UserRole
}

// user/index.ts — public surface
export { type UserAccount, type UserRole } from './model'
export { createUser, findUser, updateUser } from './service'
```

### Avoid Barrel Bloat and Circular Imports

Do not create barrels that import everything at module load (they defeat tree-shaking and grow cold-start). Import concrete paths. Circular imports signal a submission boundary that should fold upward; the type that both sides need belongs in a shared module neither imports.

### Split by Dependency Direction

Let the type graph point the way: types that cross boundaries go in a contract module; implementations import the contract; nothing imports implementations from contracts. In a node/backend codebase that means roughly: `domain` (pure types and rules) → `application` (use cases) → `infrastructure` (adapters), with dependencies pointing only inward.

## Dependencies and Build

### Diagnose, Then Add Dependencies

Prefer built-in `Array`, `Map`, `Promise`, and `Intl` over pulling in utilities for every small operation. A tiny inline function beats a dependency that must be upgraded, audited, and kept compatible. (The Go idiom "a little copying is better than a little dependency" applies to TypeScript too.)

### Runtime Validation, Not Type-of-Trust

Schemas that validate at runtime (Zod, validators, or hand-written guards) are the bridge between untrusted data and compile-time types. Library approaches differ (Zod and other schema-first libraries derive the type from the schema; validators in some ecosystem patterns are type-first with the runtime check derived). Pick one model and be consistent across the codebase.

### Keep the Compiler Incremental and Fast

Large codebases benefit from `composite: true` with project references, an `incremental` build cache, and `moduleResolution: bundler` where the bundler supports it. Slow type-checking is a workflow problem that pushes developers off the type system — invest in narrowing the checked surface over relaxing it.

## Performance

### Types Are Free, Structures Are Not

Type-level gymnastics (mapped types, conditional types, template literal types) cost nothing at runtime but can cost a lot of developer clarity. Keep complex type machinery inside boundary modules; do not export type circus acts as the public API.

### Avoid Unnecessary Object Renaming

Copying and spreading large nested objects repeatedly has real cost in hot paths. Prefer immutable updates with spread at the point of change, but avoid defensive re-copying of unchanged structures (for example, in render paths or per-message handlers).

### Memoize Idempotent Computation

Pure, expensive derivations belong behind a cache if they repeat with the same inputs. Use `Map`-based caches with explicit lifetime instead of ad-hoc global caches that never clear.

## Type-Level Testing

### Assert the Types, Not Just the Runtime

Behavior tests prove runtime behavior; dedicated type tests lock in the public API contract. A type that silently loosens is a regression.

```typescript
import { expectTypeOf } from 'vitest'

expectTypeOf<Result<User, ValidationIssue[]>>().toEqualTypeOf<
  | { ok: true; value: User }
  | { ok: false; error: ValidationIssue[] }
>()
```

### Use `satisfies` to Preserve Intent

`satisfies` checks a value against a shape without widening it to that shape — the ideal way to keep literal types while still validating structure.

```typescript
const statusByAction = {
  new: 'open',
  reopen: 'open',
  close: 'closed'
} as const satisfies Record<Action, Status>
```

## TypeScript Tooling Integration

### Essential Commands

```bash
# Type-check the whole project
npx tsc --noEmit

# Watch mode for fast feedback
npx tsc --noEmit --watch

# Run tests (Vitest)
npx vitest run

# Lint with types-aware rules (typescript-eslint)
npx eslint .

# Formatting
npx prettier --write .
```

### Recommended Linter Baseline

The `typescript-eslint` recommended-type-checked ruleset is the practical default: it promotes `no-unsafe-assignment`, `no-unsafe-member-access`, `no-unsafe-argument`, and `no-unsafe-call` from style noise to compiler-like guarantees. Keep the type-aware config; if it is slow, that is a project-structure signal, not a reason to disable it.

## Anti-Patterns to Avoid

- **`any` as a speed hack** — it converts the compiler's proof into a runtime guess. Reach for `unknown` + narrowing instead.
- **`as` casts that lie** — a cast that bypasses a check you did not actually perform is where null-pointer and shape bugs are born. Validate, then cast, and keep the cast inside the module that validates.
- **Deeply nested callbacks / promise chains** — prefer async/await; flat code is narrowable code.
- **`enum` coercion bugs** — string-literal unions give you the same safety without runtime artifacts or reverse-mapping footguns.
- **Giant god types** — a single interface that models several unrelated shapes should be a discriminated union or several interfaces.
- **Optional-only option objects** — `allOptional` config types silently swallow typos at the call site; prefer required fields for the ones the function genuinely depends on.
- **Silent catch** — `catch {}` or `catch (e) { /* nothing */ }` hides failures the caller assumed were handled.
- **Mixing sync and async error paths** — an `async` function always surfaces throws as rejections, even before the first `await`. Only a non-`async` function returning a promise can throw synchronously (before returning it), forcing callers to handle two error shapes. Prefer `async` throughout so every failure is a rejection:

```typescript
async function asyncFails(): Promise<never> {
  throw new Error('becomes a rejection, never a sync throw')
}

function lazyFails(): Promise<never> {
  throw new Error('throws synchronously — needs try/catch AND .catch')
}
```

**Remember**: the type system is a proof tool, not a paperwork burden. When a type error resists a reasonable annotation, the design — not the compiler — is usually the thing to change. Prefer boring, explicit, well-scoped TypeScript over clever type engines.

## Related Skills

- `nestjs-patterns` — NestJS architecture patterns for TypeScript backends (modules, controllers, providers, DTO validation)
- `frontend-patterns` — React and Next.js component and state patterns
- TypeScript rules (`rules/typescript/`, installed as `rules/ecc/typescript/`) — the "what" and "when" this skill implements as the "how"
- `prisma-patterns` — database access patterns used in TypeScript applications
