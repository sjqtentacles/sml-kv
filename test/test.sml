(* Tests for sml-kv: log replay (last write wins), delete tombstones, minimal
   compaction equivalent under replay, length-prefixed encode/decode round
   trips (including special characters), sorted views, and SSTable binary
   search. Reference values are computed by hand. *)

structure Tests =
struct
  open Harness
  structure K = Kv

  (* render a log compactly for assertions *)
  fun opStr (K.Put (k, v)) = "P(" ^ k ^ "," ^ v ^ ")"
    | opStr (K.Delete k) = "D(" ^ k ^ ")"
  fun logStr l = "[" ^ String.concatWith ";" (List.map opStr l) ^ "]"

  fun pairStr (k, v) = k ^ "=" ^ v
  fun mapStr m = "{" ^ String.concatWith "," (List.map pairStr (K.toList m)) ^ "}"

  fun runAll () =
    let
      (* -------------------- replay: last write wins -------------------- *)
      val () = section "replay: last write wins"
      val m1 = K.replay [K.Put ("a", "1"), K.Put ("a", "2")]
      val () = check "overwrite -> 2" (K.get m1 "a" = SOME "2")
      val m2 = K.replay [K.Put ("a", "1"), K.Put ("b", "2"), K.Put ("a", "9")]
      val () = check "a overwritten -> 9" (K.get m2 "a" = SOME "9")
      val () = check "b intact -> 2" (K.get m2 "b" = SOME "2")
      val () = check "missing key -> NONE" (K.get m2 "z" = NONE)
      val () = checkInt "size" (2, K.size m2)

      val () = section "replay: delete tombstone"
      val d1 = K.replay [K.Put ("a", "1"), K.Delete "a"]
      val () = check "deleted -> NONE" (K.get d1 "a" = NONE)
      val () = check "not a member" (not (K.member d1 "a"))
      val () = checkInt "size 0 after delete" (0, K.size d1)
      val d2 = K.replay [K.Put ("a", "1"), K.Delete "a", K.Put ("a", "3")]
      val () = check "re-put after delete -> 3" (K.get d2 "a" = SOME "3")
      val d3 = K.replay [K.Delete "ghost"]
      val () = check "delete of absent key is a no-op" (K.size d3 = 0)

      val () = section "sorted views"
      val sm = K.replay [K.Put ("banana", "y"), K.Put ("apple", "x"),
                         K.Put ("cherry", "z"), K.Put ("apple", "x2")]
      val () = checkStringList "keys sorted" (["apple", "banana", "cherry"], K.keys sm)
      val () = checkString "toList sorted"
                 ("{apple=x2,banana=y,cherry=z}", mapStr sm)

      (* -------------------- compaction -------------------- *)
      val () = section "compact: minimal equivalent log"
      val bigLog = [K.Put ("a", "1"), K.Put ("b", "2"), K.Put ("a", "9"),
                    K.Delete "b", K.Put ("c", "3"), K.Put ("d", "4"),
                    K.Delete "d"]
      val comp = K.compact bigLog
      val () = checkString "compact result (sorted Puts, no tombstones)"
                 ("[P(a,9);P(c,3)]", logStr comp)
      val () = check "replay(compact L) = replay L"
                 (K.toList (K.replay comp) = K.toList (K.replay bigLog))
      val () = checkInt "compact length" (2, List.length comp)
      val () = check "compact of empty log" (K.compact [] = [])
      (* compaction is idempotent *)
      val () = check "compact idempotent" (K.compact comp = comp)

      (* -------------------- encode / decode round trips -------------------- *)
      val () = section "encode / decode round trip"
      val () = check "empty log round trips" (K.decode (K.encode []) = SOME [])
      val rt1 = [K.Put ("a", "1"), K.Delete "b", K.Put ("c", "hello")]
      val () = check "simple log round trips" (K.decode (K.encode rt1) = SOME rt1)
      (* special characters: ':' , newlines, quotes, empty strings *)
      val rt2 = [K.Put ("k:1", "v\nwith\nnewlines"),
                 K.Put ("quote\"d", "co:lon:s"),
                 K.Put ("", "empty-key"),
                 K.Put ("empty-val", ""),
                 K.Delete "to:mb"]
      val () = check "special-char log round trips" (K.decode (K.encode rt2) = SOME rt2)
      val () = checkString "encode is deterministic framing"
                 ("P1:a1:1D1:bP1:c5:hello", K.encode rt1)
      val () = check "decode rejects garbage" (K.decode "X garbage" = NONE)
      val () = check "decode rejects truncated length" (K.decode "P3:ab" = NONE)
      val () = check "decode rejects bad tag" (K.decode "Q1:a" = NONE)

      (* the log survives a full round trip back to the same live view *)
      val () = check "encode->decode->replay preserves view"
                 (K.toList (K.replay (valOf (K.decode (K.encode bigLog))))
                  = K.toList (K.replay bigLog))

      (* -------------------- SSTable binary search -------------------- *)
      val () = section "Sstable: sorted block + binary search"
      val st = K.Sstable.fromLog bigLog   (* live: a=9, c=3 *)
      val () = checkInt "sstable size" (2, K.Sstable.size st)
      val () = check "sstable get a" (K.Sstable.get st "a" = SOME "9")
      val () = check "sstable get c" (K.Sstable.get st "c" = SOME "3")
      val () = check "sstable get missing (deleted b)" (K.Sstable.get st "b" = NONE)
      val () = check "sstable member" (K.Sstable.member st "a")
      val () = check "sstable non-member" (not (K.Sstable.member st "zzz"))
      val big = List.tabulate (100, fn i =>
                  K.Put ("key" ^ (if i < 10 then "0" else "") ^ Int.toString i,
                         "val" ^ Int.toString i))
      val st2 = K.Sstable.fromLog big
      val () = checkInt "sstable 100 entries" (100, K.Sstable.size st2)
      val () = check "binary search finds key42" (K.Sstable.get st2 "key42" = SOME "val42")
      val () = check "binary search finds key00" (K.Sstable.get st2 "key00" = SOME "val0")
      val () = check "binary search finds key99" (K.Sstable.get st2 "key99" = SOME "val99")
      val () = check "binary search misses" (K.Sstable.get st2 "key100" = NONE)
      val () = checkStringList "sstable keys sorted"
                 (["a", "c"], K.Sstable.keys st)
    in
      Harness.run ()
    end

  val run = runAll
end
