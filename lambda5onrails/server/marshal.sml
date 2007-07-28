
structure Marshal :> MARSHAL =
struct

  infixr 9 `
  fun a ` b = a b

  open Bytecode
  structure SM = StringMap

  exception Marshal of string

  fun unmarshal (dict : exp) (bytes : string) : exp =
    let
      val G = SM.empty

      (* this code imperatively consumes b from the head *)
      val b = ref bytes
      fun tok () =
        case StringUtil.token (fn #" " => true | _ => false) ` !b of
          ("", "") => raise Marshal "um expected token; empty"
        | (t, b') => let in b := b' ; t end

      fun int () =
        case IntConst.fromstring ` tok () of
          NONE => raise Marshal "um expected int"
        | SOME i => i

      fun string () =
        let val t = tok ()
        in
          case StringUtil.urldecode ` String.substring(t, 1, size t - 1) of
            NONE => raise Marshal "um expected urlencoded string"
          | SOME s => s
        end

      fun addr () =
        case StringUtil.urldecode ` tok () of
          NONE => raise Marshal "um expected urlencoded addr"
        | SOME s => s

      fun um G loc (Dlookup s) =
        (case SM.find (G, s) of
           NONE => raise Marshal "um dlookup not found"
         | SOME d => um G loc d)
        | um G _   (Dat { d, a = String w }) = um G w d
        | um _ _   (Dat _) = raise Marshal "malformed Dat dictionary"
        | um G loc (Dp Dint) = Int ` int ()
        | um G loc (Dp Dconts) = Int ` int ()
        | um G loc (Dp Dcont) = Record [("g", Int ` int ()),
                                        ("f", Int ` int ())]

        | um G loc (Dp Dstring) = String ` string ()
        | um G loc (Dp Daddr) = String ` addr ()
        | um G loc (Dp Dw) = String ` addr ()

        | um G loc (Dp Daa) = Int ` int ()
        | um G loc (Dall _) = raise Marshal "Dall unimplemented (unmarshal)"

        | um G loc (Dp Dref) =
           (* when unmarshaling, we reconstitute the ref only
              when it belongs to us. *)
           let val r = int ()
           in
             if loc = Worlds.server
             then raise Marshal "ref reconstitution unimplemented"
             else Int r
           end
           
        | um G loc (Dexists {d,a}) =
           let
             val () = print ("dex get dict:\n")
             val thed = um G loc (Dp Ddict)
             val G = SM.insert(G, d, thed)
           in
             print ("dex got dict, now " ^ Int.toString (length a) ^ "\n");
             Record (("d", thed) ::
                     (* then 'n' expressions ... *)
                     ListUtil.mapi (fn (ad, i) =>
                                    ("v" ^ Int.toString i,
                                     um G loc ad)) a)
           end
        | um G loc (Dp Dvoid) = raise Marshal "can't unmarshal at void"
        | um G loc (Dp Ddict) =
          (case tok () of
             "DP" => Dp (case tok () of
                           "c" => Dcont
                         | "C" => Dconts
                         | "a" => Daddr
                         | "d" => Ddict
                         | "i" => Dint
                         | "s" => Dstring
                         | "v" => Dvoid
                         | "A" => Daa
                         | "r" => Dref
                         | "w" => Dw
                         | _ => raise Marshal "um bad primdict?")
           | "D@" =>
               let
                 val d = um G loc ` Dp Ddict
                 val w = String ` addr ()
               in
                 Dat { d = d, a = w }
               end
           | "DL" => Dlookup (tok ())
           | "DR" =>
               let val n = IntConst.toInt ` int ()
               in
                 print ("um dr: " ^ Int.toString n ^ "\n");
                 (* then n, then n lab/dict pairs *)
                 Drec ` List.tabulate(n,
                                      fn i =>
                                      (tok (), um G loc (Dp Ddict)))
               end
           | "DE" =>
               let
                 val d = tok ()
                 val n = IntConst.toInt ` int ()
               in
                 Dexists { d = d, a = List.tabulate(n, fn i => um G loc ` Dp Ddict) }
               end
           | s => raise Marshal ("um unimplemented " ^ s))

        | um G loc (Drec sel) =
             Record ` map (fn (s, d) =>
                           let
                             val s' = tok ()
                           in
                             (* the format is redundant *)
                             print ("unmarshal label " ^ s ^ "\n");
                             if s' = s
                             then (s', um G loc d)
                             else raise Marshal "unmarshal drec label mismatch"
                           end) sel

        | um G loc (Dsum _) = raise Marshal "unmarshal dsum unimplemented"

        | um _ _ (Record _) = raise Marshal "um: not dict"
        | um _ _ (Project _) = raise Marshal "um: not dict"
        | um _ _ (Primcall _) = raise Marshal "um: not dict"
        | um _ _ (Var _) = raise Marshal "um: dict not closed"
        | um _ _ (Int _) = raise Marshal "um: not dict"
        | um _ _ (String _) = raise Marshal "um: not dict"
        | um _ _ (Inj _) = raise Marshal "um: not dict"
        | um _ _ (Bytecode.Marshal _) = raise Marshal "um: not dict"
        
    in
      um G Worlds.server dict
    end

  fun marshal (dict : exp) (value : exp) : string = 
    let
      (* always start with an empty dict context *)
      val G = SM.empty

      fun mar G loc (Dlookup s) v =
        (case SM.find (G, s) of
           NONE => raise Marshal "dlookup not bound"
             (* hmm, the dicts in the context could be closures,
                holding the context we saw at the point we
                inserted them? But this is only an issue if
                we have shadowing... *)
         | SOME d => mar G loc d v)
        | mar G loc (Dp Dint) (Int i) = IntConst.toString i
        | mar G loc (Dp Dint) _ = raise Marshal "dint"
        | mar G loc (Dp Dconts) (Int i) = IntConst.toString i
        | mar G loc (Dp Dconts) _ = raise Marshal "dconts"
        | mar G loc (Dp Dcont) (Record [("g", Int g), ("f", Int f)]) =
                IntConst.toString g ^ " " ^ IntConst.toString f
        | mar G loc (Dp Dcont) _ = raise Marshal "dcont"
        | mar G loc (Dp Dstring) (String s) = "." ^ StringUtil.urlencode s
        | mar G loc (Dp Dstring) _ = raise Marshal "dstring"
        | mar G loc (Dp Dw) (String s) = StringUtil.urlencode s
        | mar G loc (Dp Dw) _ = raise Marshal "dw"
        | mar G loc (Dp Daddr) (String s) = StringUtil.urlencode s
        | mar G loc (Dp Daddr) _ = raise Marshal "daddr"
        | mar G loc (Dsum seol) (Inj (s, eo)) =
        (case (ListUtil.Alist.find op= seol s, eo) of
           (NONE, _) => raise Marshal "dsum/inj mismatch : missing label"
         | (SOME NONE, NONE) => s ^ " -"
         | (SOME (SOME d), SOME v) => s ^ " + " ^ mar G loc d v
         | _ => raise Marshal "dsum/inj arity mismatch")
        | mar G loc (Dsum _) _ = raise Marshal "dsum"
        | mar G loc (Drec sel) (Record lel) =
        StringUtil.delimit " "
                      (map (fn (s, d) =>
                            case ListUtil.Alist.find op= lel s of
                              NONE => raise Marshal 
                                       ("drec/rec mismatch : missing label " ^ s ^ 
                                        " among: " ^ StringUtil.delimit ", "
                                        (map #1 lel))
                            | SOME v => s ^ " " ^ mar G loc d v) sel)
        | mar G loc (Drec _) _ = raise Marshal "drec"
        | mar G loc (Dexists {d, a}) (Record lel) =
        (case ListUtil.Alist.extract op= lel "d" of
           NONE => raise Marshal "no dict in supposed e-package"
         | SOME (thed, lel) =>
             let
             (* need to bind d; it might appear in a! *)
               val G' = SM.insert (G, d, thed)
             in
               mar G loc (Dp Ddict) thed ^ " " ^
               (StringUtil.delimit " " `
                ListUtil.mapi (fn (ad, i) =>
                               (case ListUtil.Alist.find op= lel 
                                          ("v" ^ Int.toString i) of
                                  NONE => raise Marshal 
                                    "missing val in supposed e-package"
                                | SOME v => mar G' loc ad v)) a)
             end)
        | mar G loc (Dexists _) _ = raise Marshal "dexists"
        | mar G loc (Dp Dvoid) _ = raise Marshal "can't actually marshal at dvoid"

        | mar G loc (Dat {d, a = String a}) v = mar G a d v
        | mar G loc (Dat _) _ = raise Marshal "dat"

        | mar G loc (Dp Daa) (Int i) = IntConst.toString i
        | mar G loc (Dp Daa) _ = raise Marshal "daa"

        | mar G loc (Dall _) _ = raise Marshal "unimplemented Dall"

        | mar G loc (Dp Dref) d =
           let
             val i = if loc = Worlds.server
                     then raise Marshal "unimplemented server ref desiccation"
                     else (case d of
                             Int i => i
                           | _ => raise Marshal "remote ref wasn't int!")
           in
             IntConst.toString i
           end
        | mar G loc (Dp Ddict) d = 
           (case d of
              Dp pd => "DP " ^ (case pd of
                                  Dcont   => "c"
                                | Dconts  => "C"
                                | Daddr   => "a"
                                | Ddict   => "d"
                                | Dint    => "i"
                                | Dstring => "s"
                                | Daa     => "A"
                                | Dref    => "r"
                                | Dw      => "w"
                                | Dvoid   => "v")
            | Dat {d, a} => "D@ " ^ mar G loc (Dp Ddict) d ^ " " ^
                                    mar G loc (Dp Dw) a
            | Dlookup s => "DL " ^ s
            | Dexists {d, a} => "DE " ^ d ^ " " ^ Int.toString (length a) ^ " " ^
                   StringUtil.delimit " " (map (mar G loc (Dp Ddict)) a)
            | Drec sdl => 
                   let
                     val n = length sdl
                   in
                     print ("in drect there are " ^ Int.toString n ^ "\n");
                     "DR " ^ Int.toString n ^ " " ^
                     StringUtil.delimit " " (map (fn (s,d) => s ^ " " ^ mar G loc (Dp Ddict) d) sdl)
                   end
            | Dsum sdl => "DS " ^ Int.toString (length sdl) ^ " " ^
                   StringUtil.delimit " " (map (fn (s,NONE) => s ^ " -"
                                                 | (s,SOME d) => s ^ " + " ^ mar G loc (Dp Ddict) d) sdl)
            | Dall _ => raise Marshal "unimplemented marshal dall dict"
            | Record _ => raise Marshal "not ddict"
            | Project _ => raise Marshal "not ddict"
            | Primcall _ => raise Marshal "not ddict"
            | Var _ => raise Marshal "ddict not closed"
            | Int _ => raise Marshal "not ddict"
            | String _ => raise Marshal "not ddict"
            | Inj _ => raise Marshal "not ddict"
            | Bytecode.Marshal _ => raise Marshal "not ddict")
          (* for completeness. we require the first argument to be a
             dictionary, of course! *)
        | mar _ _ (Record _) _ = raise Marshal "not dict"
        | mar _ _ (Project _) _ = raise Marshal "not dict"
        | mar _ _ (Primcall _) _ = raise Marshal "not dict"
        | mar _ _ (Var _) _ = raise Marshal "dict not closed"
        | mar _ _ (Int _) _ = raise Marshal "not dict"
        | mar _ _ (String _) _ = raise Marshal "not dict"
        | mar _ _ (Inj _) _ = raise Marshal "not dict"
        | mar _ _ (Bytecode.Marshal _) _ = raise Marshal "not dict"

      val res = mar G Worlds.server dict value
    in
      print ("Result of marshaling: " ^ res ^ "\n");
      res
    end

end
