# perl-patterns — Extended Reference

## Tooling

### perltidy Configuration (.perltidyrc)

```text
-i=4        # 4-space indent
-l=100      # 100-char line length
-ci=4       # continuation indent
-ce         # cuddled else
-bar        # opening brace on same line
-nolq       # don't outdent long quoted strings
```

### perlcritic Configuration (.perlcriticrc)

```ini
severity = 3
theme = core + pbp + security

[InputOutput::RequireCheckedSyscalls]
functions = :builtins
exclude_functions = say print

[Subroutines::ProhibitExplicitReturnUndef]
severity = 4

[ValuesAndExpressions::ProhibitMagicNumbers]
allowed_values = 0 1 2 -1
```

### Dependency Management (cpanfile + carton)

```bash
cpanm App::cpanminus Carton   # Install tools
carton install                 # Install deps from cpanfile
carton exec -- perl bin/myapp  # Run with local deps
```

```perl
# cpanfile
requires 'Moo', '>= 2.005';
requires 'Path::Tiny';
requires 'JSON::MaybeXS';
requires 'Try::Tiny';

on test => sub {
    requires 'Test2::V0';
    requires 'Test::MockModule';
};
```

## Quick Reference: Modern Perl Idioms

| Legacy Pattern | Modern Replacement |
|---|---|
| `use strict; use warnings;` | `use v5.36;` |
| `my ($x, $y) = @_;` | `sub foo($x, $y) { ... }` |
| `@{ $ref }` | `$ref->@*` |
| `%{ $ref }` | `$ref->%*` |
| `open FH, "< $file"` | `open my $fh, '<:encoding(UTF-8)', $file` |
| `blessed hashref` | `Moo` class with types |
| `$1, $2, $3` | `$+{name}` (named captures) |
| `eval { }; if ($@)` | `Try::Tiny` or native `try/catch` (5.40+) |
| `BEGIN { require Exporter; }` | `use Exporter 'import';` |
| Manual file ops | `Path::Tiny` |
| `blessed($o) && $o->isa('X')` | `$o isa 'X'` (5.32+) |
| `builtin::true / false` | `use builtin 'true', 'false';` (5.36+, experimental) |

## Anti-Patterns

```perl
# 1. Two-arg open (security risk)
open FH, $filename;                     # NEVER

# 2. Indirect object syntax (ambiguous parsing)
my $obj = new Foo(bar => 1);            # Bad
my $obj = Foo->new(bar => 1);           # Good

# 3. Excessive reliance on $_
map { process($_) } grep { validate($_) } @items;  # Hard to follow
my @valid = grep { validate($_) } @items;           # Better: break it up
my @results = map { process($_) } @valid;

# 4. Disabling strict refs
no strict 'refs';                        # Almost always wrong
${"My::Package::$var"} = $value;         # Use a hash instead

# 5. Global variables as configuration
our $TIMEOUT = 30;                       # Bad: mutable global
use constant TIMEOUT => 30;              # Better: constant
# Best: Moo attribute with default

# 6. String eval for module loading
eval "require $module";                  # Bad: code injection risk
eval "use $module";                      # Bad
use Module::Runtime 'require_module';    # Good: safe module loading
require_module($module);
```

**Remember**: Modern Perl is clean, readable, and safe. Let `use v5.36` handle the boilerplate, use Moo for objects, and prefer CPAN's battle-tested modules over hand-rolled solutions.
