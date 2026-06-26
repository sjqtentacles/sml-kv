# sml-kv

[![CI](https://github.com/sjqtentacles/sml-kv/actions/workflows/ci.yml/badge.svg)](https://github.com/sjqtentacles/sml-kv/actions/workflows/ci.yml)

A pure, **log-structured key/value store model** in Standard ML: an append-only
command log is the single source of truth, the live map is a fold over the log
(last write wins, deletes tombstone), and the log can be compacted, serialized
to a deterministic byte framing, and queried through an SSTable-style
binary-search block.

This library is **data only — there is no file IO anywhere in it**, which keeps
it fully pure and dual-compiler reproducible. The same inputs always produce the
same outputs under **MLton** and **Poly/ML**. A real deployment writes the
string from `encode` to an append-only file and rebuilds state with
`decode` + `replay`; that IO tool lives outside this library.

- **`Kv.oper` / `log`** — `Put (key, value) | Delete key`; a `log` is an
  `oper list`.
- **`replay` / `get` / `keys` / `toList` / `size`** — fold the log into a live
  map (key-sorted); reads, sorted key listing, and sorted entry dump.
- **`put` / `delete`** — cheap incremental edits on a live map (no full
  re-replay), keeping keys sorted.
- **`fold` / `foldRange`** — fold live entries in ascending key order, optionally
  restricted to a half-open key range `[lo, hi)`.
- **`compact`** — rewrite a log into the minimal equivalent log: one `Put` per
  live key, no tombstones, ascending key order. `replay (compact l) = replay l`.
- **`merge`** — combine two logs (the second is newer); tombstone-aware
  newer-wins, returning a compacted log. `replay (merge a b) = replay (a @ b)`.
- **`encode` / `decode`** — deterministic, reversible, length-prefixed framing
  of a log (the on-disk format), modelled as a `string`. Handles any bytes in
  keys/values (`:`, newlines, quotes, empties) without escaping.
- **`Kv.Sstable`** — an immutable sorted block built from a log, with O(log n)
  binary-search `get`, plus binary-searched `range`/`prefix` scans, newer-wins
  `merge`, and `toLog`.

## Serialization format

Each record is length-prefixed, so no byte ever needs escaping:

```
record = 'P' field field    (* Put key value *)
       | 'D' field          (* Delete key    *)
field  = <decimal length> ':' <bytes>
```

For example `[Put("c","hello"), Delete("b")]` encodes to `P1:c5:helloD1:b`.

## API

```sml
structure Kv : sig
  datatype oper = Put of string * string | Delete of string
  type log = oper list

  type map
  val empty  : map
  val replay : log -> map
  val put    : map -> string -> string -> map
  val delete : map -> string -> map
  val get    : map -> string -> string option
  val member : map -> string -> bool
  val keys   : map -> string list               (* sorted *)
  val toList : map -> (string * string) list      (* sorted by key *)
  val size   : map -> int
  val fold      : (string * string * 'a -> 'a) -> 'a -> map -> 'a
  val foldRange : string * string -> (string * string * 'a -> 'a) -> 'a -> map -> 'a

  val compact : log -> log
  val merge   : log -> log -> log
  val encode  : log -> string
  val decode  : string -> log option

  structure Sstable : sig
    type t
    val fromLog  : log -> t
    val fromList : (string * string) list -> t
    val get      : t -> string -> string option   (* binary search *)
    val member   : t -> string -> bool
    val toList   : t -> (string * string) list
    val keys     : t -> string list
    val size     : t -> int
    val range    : t -> string * string -> (string * string) list
    val prefix   : t -> string -> (string * string) list
    val merge    : t -> t -> t
    val toLog    : t -> log
  end
end
```

## Example

```sml
val log = [ Kv.Put ("user:1", "alice"), Kv.Put ("user:1", "alice2"),
            Kv.Put ("user:2", "bob"),   Kv.Delete "user:2" ]

val live = Kv.replay log
val SOME "alice2" = Kv.get live "user:1"     (* last write wins *)
val NONE          = Kv.get live "user:2"     (* tombstoned       *)

val comp  = Kv.compact log                    (* [Put("user:1","alice2")] *)
val bytes = Kv.encode comp
val SOME comp' = Kv.decode bytes
val true = (Kv.toList (Kv.replay comp') = Kv.toList live)

(* incremental edits, range folds, and log merges *)
val m  = Kv.put (Kv.put Kv.empty "a" "1") "b" "2"
val m  = Kv.delete m "a"                       (* {b=2} *)
val bs = Kv.foldRange ("a", "c") (fn (k,_,acc) => k :: acc) [] (Kv.replay log)
val combined = Kv.merge log [Kv.Put ("user:5","erin")]  (* newer wins, compacted *)

(* SSTable range/prefix scans (binary-searched) *)
val sst   = Kv.Sstable.fromList [("apple","1"),("apricot","2"),("banana","3")]
val aps   = Kv.Sstable.prefix sst "ap"         (* [("apple","1"),("apricot","2")] *)
val band  = Kv.Sstable.range sst ("b", "c")    (* [("banana","3")] *)
```

Running [`examples/demo.sml`](examples/demo.sml) with `make example` prints:

```
Append-only log:
  [Put(user:1,alice), Put(user:2,bob), Put(user:1,alice2), Put(user:3,carol), Delete(user:2), Put(user:4,dave)]
  log entries          = 6

Live view (replay, last write wins):
  {user:1=alice2, user:3=carol, user:4=dave}
  live keys            = 3
  get user:1           = alice2
  get user:2 (deleted) = <none>

Compacted log (one Put per live key, sorted):
  [Put(user:1,alice2), Put(user:3,carol), Put(user:4,dave)]
  compacted entries    = 3
  replay(compact)==replay(log)? true

Serialized (length-prefixed framing):
  encoded              = P6:user:16:alice2P6:user:35:carolP6:user:44:dave
  encoded size (bytes) = 48
  decode == original?  = true
  decoded->replay view = {user:1=alice2, user:3=carol, user:4=dave}

SSTable (sorted block, binary search):
  get user:3           = carol
  get user:2 (deleted) = <none>
```

## Build & test

Requires [MLton](http://mlton.org/) and/or [Poly/ML](https://polyml.org/).

```sh
make test        # build + run the suite under MLton
make test-poly   # run the suite under Poly/ML
make all-tests   # both
make example     # build + run the demo
make clean
```

## Installing with smlpkg

```sh
smlpkg add github.com/sjqtentacles/sml-kv
smlpkg sync
```

Reference `lib/github.com/sjqtentacles/sml-kv/kv.mlb` from your own `.mlb`
(MLton / MLKit), or feed `sources.mlb` to `tools/polybuild` (Poly/ML).

## Layout

```
sml.pkg                                  smlpkg manifest
Makefile                                 MLton + Poly/ML targets
.github/workflows/ci.yml                 CI: MLton + Poly/ML
lib/github.com/sjqtentacles/sml-kv/
  kv.sig    KV signature
  kv.sml    log/replay/compact/encode/decode + SSTable
  sources.mlb
  kv.mlb
examples/
  demo.sml  put/overwrite/delete/compact/encode/decode walkthrough
test/
  harness.sml
  test.sml  replay, tombstones, compaction, framing, SSTable (68 checks)
  entry.sml / main.sml
tools/polybuild
```

## Tests

68 deterministic checks: last-write-wins replay, delete tombstones (and
re-puts), sorted `keys`/`toList`, incremental `put`/`delete` matching `replay`,
`fold`/`foldRange` in key order, minimal `compact` (verified `replay (compact
l) = replay l` and idempotent), tombstone-aware `merge` (`replay (merge a b) =
replay (a @ b)`), length-prefixed `encode`/`decode` round trips including
special characters (`:`, newlines, quotes, empty keys/values), framing
byte-stability, malformed-input rejection, SSTable binary search over 100 keys,
and SSTable `range`/`prefix`/`merge`/`toLog`. Run `make all-tests` to verify
identical output under both compilers.

## License

MIT. See [LICENSE](LICENSE).
