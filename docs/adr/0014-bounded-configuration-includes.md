# ADR 0014: Bound Configuration Include Resolution

## Status

Accepted.

## Context

Configuration includes make a large configuration maintainable, but unrestricted
paths and glob syntax can escape the selected configuration root, traverse a
large filesystem tree, create platform-dependent results, or hide the same file
behind multiple symlinks.

## Decision

Resolve includes relative to the directory containing the top-level
configuration file. Version 1 patterns use portable ASCII path characters and
support only non-recursive `*` globs. Reject absolute paths, `..`, recursive
globs, extended glob operators, non-file targets, symlink loops, and canonical
targets outside the configuration root.

Allow no more than 64 include patterns, 256 resolved files, or 512 bytes per
pattern. Require every declared pattern to match at least one regular file.
Return unique canonical paths in lexical order so filesystem enumeration order
has no semantic effect.

## Consequences

Configuration discovery remains deterministic and bounded, and projected-volume
symlinks continue to work when their targets remain inside the selected root.
Operators cannot use recursive globs, Unicode filenames, or configuration files
outside that root and must list additional directories explicitly.
