(* kv.sig

   A pure, log-structured key/value store *model* in Standard ML.

   This is data only: there is no file IO anywhere in the library, which keeps
   it fully pure and dual-compiler reproducible. (A real deployment would write
   the byte string produced by `encode` to an append-only file and rebuild state
   with `decode` + `replay`; that IO tool lives outside this library.)

   The design follows a log-structured store:

     - An append-only command `log` is a list of `Put`/`Delete` operations and
       is the single source of truth.
     - The live `map` is a fold over the log (`replay`): last write wins, and a
       `Delete` tombstones a key.
     - `compact` rewrites a log into the minimal equivalent log (one `Put` per
       live key, no tombstones, deterministic key order).
     - `encode`/`decode` are a deterministic, reversible, length-prefixed framing
       of a log — the on-disk format, modelled as a `string`.
     - `Sstable` is a sorted, immutable block built from a log, with O(log n)
       binary-search lookup.

   Keys and values are arbitrary strings (any bytes, including `:`, newlines and
   quotes); the framing is length-prefixed so it never needs escaping. *)

signature KV =
sig
  (* append-only log entries *)
  datatype oper = Put of string * string | Delete of string
  type log = oper list

  (* ---- live map: a fold over the log ---- *)
  type map

  val empty  : map
  val replay : log -> map               (* fold the log; last write wins *)

  val get    : map -> string -> string option
  val member : map -> string -> bool
  val keys   : map -> string list                (* sorted, ascending *)
  val toList : map -> (string * string) list      (* sorted by key *)
  val size   : map -> int

  (* ---- compaction ---- *)
  (* Minimal log equivalent under `replay`: exactly one `Put` per live key,
     no tombstones, keys in ascending order. replay (compact l) = replay l. *)
  val compact : log -> log

  (* ---- serialization (length-prefixed framing) ---- *)
  val encode : log -> string
  val decode : string -> log option     (* NONE on malformed input *)

  (* ---- SSTable-style sorted block with binary search ---- *)
  structure Sstable :
  sig
    type t
    val fromLog  : log -> t                          (* via replay, sorted *)
    val fromList : (string * string) list -> t         (* re-sorted by key *)
    val get      : t -> string -> string option         (* binary search *)
    val member   : t -> string -> bool
    val toList   : t -> (string * string) list
    val keys     : t -> string list
    val size     : t -> int
  end
end
