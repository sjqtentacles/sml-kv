(* demo.sml - a log-structured key/value store walkthrough: build an
   append-only log with puts, overwrites and deletes; show the live view;
   compact; encode to the on-disk framing; decode; and confirm equality.
   Deterministic: identical output on every run and on both compilers. *)

structure K = Kv

fun pairStr (k, v) = k ^ "=" ^ v
fun showMap m = "{" ^ String.concatWith ", " (List.map pairStr (K.toList m)) ^ "}"
fun opStr (K.Put (k, v)) = "Put(" ^ k ^ "," ^ v ^ ")"
  | opStr (K.Delete k) = "Delete(" ^ k ^ ")"
fun showLog l = "[" ^ String.concatWith ", " (List.map opStr l) ^ "]"

(* an append-only command log *)
val log =
  [ K.Put ("user:1", "alice"),
    K.Put ("user:2", "bob"),
    K.Put ("user:1", "alice2"),     (* overwrite *)
    K.Put ("user:3", "carol"),
    K.Delete "user:2",              (* tombstone *)
    K.Put ("user:4", "dave") ]

val () = print "Append-only log:\n"
val () = print ("  " ^ showLog log ^ "\n")
val () = print ("  log entries          = " ^ Int.toString (List.length log) ^ "\n")

val live = K.replay log
val () = print "\nLive view (replay, last write wins):\n"
val () = print ("  " ^ showMap live ^ "\n")
val () = print ("  live keys            = " ^ Int.toString (K.size live) ^ "\n")
val () = print ("  get user:1           = "
                ^ (case K.get live "user:1" of SOME v => v | NONE => "<none>") ^ "\n")
val () = print ("  get user:2 (deleted) = "
                ^ (case K.get live "user:2" of SOME v => v | NONE => "<none>") ^ "\n")

(* compaction: minimal equivalent log *)
val comp = K.compact log
val () = print "\nCompacted log (one Put per live key, sorted):\n"
val () = print ("  " ^ showLog comp ^ "\n")
val () = print ("  compacted entries    = " ^ Int.toString (List.length comp) ^ "\n")
val () = print ("  replay(compact)==replay(log)? "
                ^ Bool.toString (K.toList (K.replay comp) = K.toList live) ^ "\n")

(* serialization: encode -> string -> decode *)
val bytes = K.encode comp
val () = print "\nSerialized (length-prefixed framing):\n"
val () = print ("  encoded              = " ^ bytes ^ "\n")
val () = print ("  encoded size (bytes) = " ^ Int.toString (String.size bytes) ^ "\n")

val decoded = K.decode bytes
val () = print ("  decode == original?  = "
                ^ Bool.toString (decoded = SOME comp) ^ "\n")
val () = print ("  decoded->replay view = "
                ^ (case decoded of SOME l => showMap (K.replay l) | NONE => "<decode failed>")
                ^ "\n")

(* SSTable binary-search lookup over the sorted block *)
val st = K.Sstable.fromLog log
val () = print "\nSSTable (sorted block, binary search):\n"
val () = print ("  get user:3           = "
                ^ (case K.Sstable.get st "user:3" of SOME v => v | NONE => "<none>") ^ "\n")
val () = print ("  get user:2 (deleted) = "
                ^ (case K.Sstable.get st "user:2" of SOME v => v | NONE => "<none>") ^ "\n")
