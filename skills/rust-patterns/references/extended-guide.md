# rust-patterns — Extended Reference

## Tooling Integration

### Essential Commands

```bash
# Build and check
cargo build
cargo check              # Fast type checking without codegen
cargo clippy             # Lints and suggestions
cargo fmt                # Format code

# Testing
cargo test
cargo test -- --nocapture    # Show println output
cargo test --lib             # Unit tests only
cargo test --test integration # Integration tests only

# Dependencies
cargo audit              # Security audit
cargo tree               # Dependency tree
cargo update             # Update dependencies

# Performance
cargo bench              # Run benchmarks
```

## Quick Reference: Rust Idioms

| Idiom | Description |
|-------|-------------|
| Borrow, don't clone | Pass `&T` instead of cloning unless ownership is needed |
| Make illegal states unrepresentable | Use enums to model valid states only |
| `?` over `unwrap()` | Propagate errors, never panic in library/production code |
| Parse, don't validate | Convert unstructured data to typed structs at the boundary |
| Newtype for type safety | Wrap primitives in newtypes to prevent argument swaps |
| Prefer iterators over loops | Declarative chains are clearer and often faster |
| `#[must_use]` on Results | Ensure callers handle return values |
| `Cow` for flexible ownership | Avoid allocations when borrowing suffices |
| Exhaustive matching | No wildcard `_` for business-critical enums |
| Minimal `pub` surface | Use `pub(crate)` for internal APIs |

## Anti-Patterns to Avoid

```rust
// Bad: .unwrap() in production code
let value = map.get("key").unwrap();

// Bad: .clone() to satisfy borrow checker without understanding why
let data = expensive_data.clone();
process(&original, &data);

// Bad: Using String when &str suffices
fn greet(name: String) { /* should be &str */ }

// Bad: Box<dyn Error> in libraries (use thiserror instead)
fn parse(input: &str) -> Result<Data, Box<dyn std::error::Error>> { todo!() }

// Bad: Ignoring must_use warnings
let _ = validate(input); // Silently discarding a Result

// Bad: Blocking in async context
async fn bad_async() {
    std::thread::sleep(Duration::from_secs(1)); // Blocks the executor!
    // Use: tokio::time::sleep(Duration::from_secs(1)).await;
}
```

**Remember**: If it compiles, it's probably correct — but only if you avoid `unwrap()`, minimize `unsafe`, and let the type system work for you.
