(* kv.sml - a pure log-structured key/value store model.

   Pure and deterministic: no file IO, FFI, threads, clock or randomness, so
   results are identical under MLton and Poly/ML. The live map is kept as a
   key-sorted association list, so `keys`/`toList` are sorted by construction
   and `compact`/`encode` are byte-deterministic. *)

structure Kv :> KV =
struct

  datatype oper = Put of string * string | Delete of string
  type log = oper list

  (* live map: an association list kept sorted ascending by key *)
  type map = (string * string) list

  val empty : map = []

  (* insert or overwrite, preserving ascending key order *)
  fun put ((k, v), m) =
    case m of
        [] => [(k, v)]
      | (k', v') :: rest =>
          (case String.compare (k, k') of
               LESS    => (k, v) :: m
             | EQUAL   => (k, v) :: rest
             | GREATER => (k', v') :: put ((k, v), rest))

  fun del (k, m) =
    case m of
        [] => []
      | (k', v') :: rest =>
          (case String.compare (k, k') of
               LESS    => m                  (* not present; list is sorted *)
             | EQUAL   => rest
             | GREATER => (k', v') :: del (k, rest))

  fun apply (Put (k, v), m) = put ((k, v), m)
    | apply (Delete k, m) = del (k, m)

  fun replay l = List.foldl apply empty l

  fun get m k =
    case List.find (fn (k', _) => k' = k) m of
        SOME (_, v) => SOME v
      | NONE => NONE

  fun member m k = Option.isSome (get m k)
  fun keys m = List.map (fn (k, _) => k) m
  fun toList m = m
  fun size m = List.length m

  (* ---- compaction: minimal equivalent log, sorted Puts only ---- *)
  fun compact l = List.map Put (replay l)

  (* ---- serialization: length-prefixed framing ---- *)
  (*   record  = 'P' field field | 'D' field
       field   = <decimal length> ':' <bytes>                         *)
  fun encField s = Int.toString (String.size s) ^ ":" ^ s

  fun encOp (Put (k, v)) = "P" ^ encField k ^ encField v
    | encOp (Delete k)   = "D" ^ encField k

  fun encode l = String.concat (List.map encOp l)

  fun decode s =
    let
      val n = String.size s

      (* read a decimal length terminated by ':'; returns (len, nextIndex) *)
      fun readLen i =
        let
          fun go (j, acc, seen) =
            if j >= n then NONE
            else
              let val c = String.sub (s, j)
              in if c = #":" then (if seen then SOME (acc, j + 1) else NONE)
                 else if Char.isDigit c
                      then go (j + 1, acc * 10 + (Char.ord c - Char.ord #"0"), true)
                 else NONE
              end
        in go (i, 0, false) end

      (* read a length-prefixed field; returns (string, nextIndex) *)
      fun readField i =
        case readLen i of
            NONE => NONE
          | SOME (len, j) =>
              if len < 0 orelse j + len > n then NONE
              else SOME (String.substring (s, j, len), j + len)

      fun go (i, acc) =
        if i >= n then SOME (List.rev acc)
        else
          case String.sub (s, i) of
              #"P" =>
                (case readField (i + 1) of
                     NONE => NONE
                   | SOME (k, j) =>
                       (case readField j of
                            NONE => NONE
                          | SOME (v, j2) => go (j2, Put (k, v) :: acc)))
            | #"D" =>
                (case readField (i + 1) of
                     NONE => NONE
                   | SOME (k, j) => go (j, Delete k :: acc))
            | _ => NONE
    in go (0, []) end

  (* ---- SSTable-style sorted block with binary search ---- *)
  structure Sstable =
  struct
    type t = (string * string) vector

    fun fromList xs = Vector.fromList (replay (List.map Put xs))
    fun fromLog l = Vector.fromList (replay l)

    fun size (t : t) = Vector.length t
    fun toList (t : t) = Vector.foldr (op ::) [] t
    fun keys (t : t) = List.map (fn (k, _) => k) (toList t)

    fun get (t : t) k =
      let
        fun search (lo, hi) =      (* search [lo, hi) *)
          if lo >= hi then NONE
          else
            let
              val mid = lo + (hi - lo) div 2
              val (k', v') = Vector.sub (t, mid)
            in
              case String.compare (k, k') of
                  EQUAL => SOME v'
                | LESS  => search (lo, mid)
                | GREATER => search (mid + 1, hi)
            end
      in search (0, Vector.length t) end

    fun member t k = Option.isSome (get t k)
  end
end
