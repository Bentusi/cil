

(* Implements nodes in a graph representing the pointer locations in a 
 * program *)
open Cil
open Pretty

module H = Hashtbl
module E = Errormsg

(* If defaultIsNotWild then pointers without a qualifier are SAFE and only 
 * the arrays that are specfically SIZED contain a size field and only the 
 * variables that are specifically TAGGED contain tags *)
let defaultIsWild  = ref false


(* If allPoly is true then all un-defined functions are treated 
 * polymorphically *)
let allPoly = ref false


let externPoly = ref false

(* A place where a pointer type can occur *)
type place = 
    PGlob of string  (* A global variable or a global function *)
  | PType of string  (* A global typedef *)
  | PStatic of string * string (* A static variable or function. First is  
                                * the filename in which it occurs *)
  | PLocal of string * string * string (* A local varialbe. The name of the 
                                        * file, the function and the name of 
                                        * the local itself *)
  | POffset of int * string             (* An offset node, give the host node 
                                         * id and a field name *)
  | PField of fieldinfo                 (* A field of a composite type *)

  | PAnon of int                        (* Anonymous. This one must use a 
                                         * fresh int every time. Use 
                                         * anonPlace() to create one of these 
                                         * *)

let anonId = ref (-1) 
let anonPlace () : place = 
  incr anonId;
  PAnon !anonId

(* Each node corresponds to a place in the program where a qualifier for a 
 * pointer type could occur. As a special case we also add qualifiers for 
 * variables in expectation that their address might be taken *)
type node = 
    {         id: int;                  (* A program-wide unique identifier *)
              where: place * int;       (* A way to identify where is this 
                                         * coming from. We use this to make 
                                         * sure we do not create duplicate 
                                         * nodes. The integer is an index 
                                         * within a place, such as if the 
                                         * type of a global contains several 
                                         * pointer types (nested) *)

              btype: typ;               (* The base type of this pointer *)
      mutable attr: attribute list;     (* The attributes of this pointer 
                                         * type *)

      mutable onStack: bool;            (* Whether might contain stack 
                                         * addresses *)
      mutable updated: bool;            (* Whether it is used in a write 
                                         * operation *)
      mutable posarith: bool;           (* Whether this is used as an array 
                                         * base address in a [e] operation or 
                                         * obviously positive things are 
                                         * added to it. We assume that the 
                                         * programmer uses the notation [e] 
                                         * to indicate positive indices e. *)
      mutable arith: bool;              (* Whenever things are added to this 
                                         * pointer, but we don't know that 
                                         * they are positive *)
      mutable null: bool;               (* The number 0 might be stored in 
                                         * this pointer  *)
      mutable intcast: bool;            (* Some integer other than 0 is 
                                         * stored in this pointer *)
      mutable succ: edge list;          (* All edges with "from" = this node *)
      mutable pred: edge list;          (* All edges with "to" = this node *)

      mutable pointsto: node list;      (* A list of nodes whose types are 
                                         * pointed to by this pointer type. 
                                         * This is needed because we cannot 
                                         * have wild pointers to memory 
                                         * containing safe pointers. *)
      mutable interface: bool;          (* Is part of the interface *)
      
      (* The rest are the computed results of constraint resolution *)
      mutable kind: pointerkind;
      mutable why_kind : whykind;
      mutable sized : bool ;            (* An array may be SIZED at which
                                         * point it has a length field
                                         * stored right before it. This
                                         * leads to INDEX pointers. *)
      
      mutable mark: bool;               (* For mark-and-sweep GC of nodes. 
                                         * Most of the time is false *)
    }       
   

and pointerkind = 
    Safe
  | Scalar (* not actually a pointer *)
  | Seq    (* A three word pointer, like Index but with the length in the 
            * pointer itself *)
  | FSeq

  | SeqN   (* A sequence in a null-terminated char array *)
  | FSeqN  (* A FSeq in a null-terminated char array *)

  | String (* fseq <= string <= fseq *)

  | Index
  | Wild
  | Unknown

and whykind = (* why did we give it this kind? *)
    BadCast of edge
  | PolyCast of edge
  | SpreadFromEdge of node 
  | SpreadPointsTo of node
  | BoolFlag
  | Default
  | UserSpec
  | Unconstrained

and edge = 
    { mutable efrom:    node;
      mutable eto:      node;
      mutable ekind:    edgekind;
      mutable ecallid:   int;(* Normnally -1. Except if this edge is added 
                              * because of a call to a function (either 
                              * passing arguments or getting a result) then 
                              * we put a program-unique callid, to make it 
                              * possible later to do push-down verification *)

      (* It would be nice to add some reason why this edge was added, to 
       * explain later to the programmer.  *)
    } 
      

and edgekind = 
    ECast                    (* T_from ref q_from <= T_to ref q_to *)
  | ESafe                    (* q_to = if q_from = wild then wild else safe *)
  | EIndex                   (* q_to = if q_from = wild then wild else index *)
  | ENull                    (* a NULL flows in the direction of the edge *)

(* Print the graph *)
let d_place () = function
    PGlob s -> dprintf "Glob(%s)" s
  | PType s -> dprintf "Type(%s)" s
  | PStatic (f, s) -> dprintf "Static(%s.%s)" f s
  | PLocal (f, func, s) -> dprintf "Local(%s.%s.%s)" f func s
  | POffset (nid, fld) -> dprintf "Offset(%d, %s)" nid fld
  | PField(fi) -> dprintf "Field(%s)" fi.fname
  | PAnon id -> dprintf "Anon(%d)" id

let d_placeidx () (p, idx) = 
  dprintf "%a.%d" d_place p idx

let d_pointerkind () = function
    Safe -> text "SAFE"
  | Scalar -> text "SCALAR"
  | FSeq -> text "FSEQ" 
  | FSeqN -> text "FSEQN" 
  | String -> text "STRING" 
  | Index -> text "INDEX"
  | Seq -> text "SEQ"
  | SeqN -> text "SEQN"
  | Wild -> text "WILD" 
  | Unknown -> text "UNKNOWN" 

let d_ekind () = function
    ECast -> text "Cast"
  | ESafe -> text "Safe"
  | EIndex -> text "Index"
  | ENull -> text "Null"

let d_whykind () = function
(*    BadCast(t1,t2) -> dprintf "cast(%a<= %a)" d_type t1 d_type t2
  | PolyCast(t1,t2) -> dprintf "polymorphic(%a<= %a)" d_type t1 d_type t2
*)
  | BadCast e -> 
      dprintf "cast(%a(%d) <= %a(%d))" 
        d_type e.eto.btype e.eto.id d_type e.efrom.btype e.efrom.id 
  | PolyCast e -> 
      dprintf "polymorphic(%a (%d) <= %a(%d))" 
        d_type e.eto.btype e.eto.id d_type e.efrom.btype e.efrom.id
  | BoolFlag -> text "from_flag"
  | SpreadFromEdge(n) -> dprintf "spread_from_edge(%d)" n.id
  | SpreadPointsTo(n) -> dprintf "spread_points_to(%d)" n.id
  | Default -> text "by_default"
  | UserSpec -> text "user_spec"
  | Unconstrained -> text "unconstrained"

let d_node () n = 
  dprintf "%d : %a (%s%s%s%s%s%s%s%s) (@[%a@])@! K=%a/%a T=%a@!  S=@[%a@]@!  P=@[%a@]@!" 
    n.id d_placeidx n.where
    (if n.onStack then "stack," else "")
    (if n.updated then "upd," else "")
    (if n.posarith then "posarith," else "")
    (if n.arith then "arith," else "")
    (if n.null  then "null," else "")
    (if n.intcast  then "int," else "")
    (if n.interface  then "interf," else "")
    (if n.sized  then "sized," else "")
    (docList (chr ',' ++ break)
       (fun n -> num n.id)) n.pointsto
    d_pointerkind n.kind
    d_whykind n.why_kind
    d_type n.btype
    (docList (chr ',' ++ break)
       (fun e -> dprintf "%d:%a%a" e.eto.id
           d_ekind e.ekind
           insert (if e.ecallid >= 0 then dprintf "(%d)" e.ecallid else nil)))
    n.succ
    (docList (chr ',' ++ break)
       (fun e -> dprintf "%d:%a%a" e.efrom.id
           d_ekind e.ekind
           insert (if e.ecallid >= 0 then dprintf "(%d)" e.ecallid else nil)))
    n.pred
    

(* A mapping from place , index to ids. This will help us avoid creating 
 * duplicate nodes *)
let placeId: (place * int, node) H.t = H.create 1111

(* A mapping from ids to nodes. Rarely we need to find a node based on its 
 * index. *)
let idNode: (int, node) H.t = H.create 1111

(* Next identifier *)
let nextId = ref (-1)

let initialize () = 
  H.clear placeId;
  H.clear idNode;
  nextId := -1


let printGraph (c: out_channel) = 
  (* Get the nodes ordered by ID *)
  let all : node list ref = ref [] in
  H.iter (fun id n -> all := n :: !all) idNode;
  let allsorted = 
    List.sort (fun n1 n2 -> compare n1.id n2.id) !all in
  printShortTypes := true;
  List.iter (fun n -> fprint c 80 (d_node () n)) allsorted;
  printShortTypes := false
       
(* Add a new points-to to the node *)
let addPointsTo n n' = 
  n.pointsto <- n' :: n.pointsto

let nodeOfAttrlist al = 
  let findnode n =
    try Some (H.find idNode n)
    with Not_found -> E.s (E.bug "Cannot find node with id = %d\n" n)
  in
  match filterAttributes "_ptrnode" al with
    [] -> None
  | [ACons(_, [AInt n])] -> findnode n
  | (ACons(_, [AInt n]) :: _) as filtered -> 
      ignore (E.warn "nodeOfAttrlist(%a)" (d_attrlist true) filtered);
      findnode n
  | _ -> E.s (E.bug "nodeOfAttrlist")



let k2attr = function
    Safe -> AId("safe")
  | Index -> AId("index")
  | Wild -> AId("wild")
  | Seq -> AId("seq")
  | FSeq -> AId("fseq")
  | SeqN -> AId("seqn")
  | FSeqN -> AId("fseqn")
  | String -> AId("string")
  | _ -> E.s (E.unimp "k2attr")

let attr2k = function
    AId("safe") -> Safe
  | AId("wild") -> Wild
  | AId("index") -> Index
  | AId("fseq") -> FSeq
  | AId("seq") -> Seq
  | AId("fseqn") -> FSeqN
  | AId("seqn") -> SeqN
  | AId("string") -> String
  | _ -> Unknown
    

let kindOfAttrlist al = 
  let rec loop = function
      [] -> Unknown, Default
    | a :: al -> begin
        match a with
          AId "safe" -> Safe, UserSpec
        | AId "index" -> Index, UserSpec
        | AId "seq" -> Seq, UserSpec
        | AId "fseq" -> FSeq, UserSpec
        | AId "seqn" -> SeqN, UserSpec
        | AId "fseqn" -> FSeqN, UserSpec
        | AId "wild" -> Wild, UserSpec
        | AId "sized" -> Index, UserSpec
        | AId "tagged" -> Wild, UserSpec
        | AId "string" -> String, UserSpec
        | AId "nullterm" -> String, UserSpec
        | _ -> loop al
    end    
  in
  loop al
    

(* Replace the ptrnode attribute with the actual qualifier attribute *)
type whichAttr = 
    AtPtr  (* In a pointer type *)
  | AtArray  (* In an array type *)
  | AtVar (* For a variable *)
  | AtOther (* Anything else *)


let replacePtrNodeAttrList where al = 
  let foundNode : string ref = ref "" in
  let rec loop = function
      [] -> []
    | a :: al -> begin
        match a with
          ACons("_ptrnode", [AInt n]) -> begin
              try 
                let nd = H.find idNode n in
                let found = 
                  if nd.kind = Unknown then begin
                    ignore (E.warn "Found node %d with kind Unkown\n" n);
                    ""
                  end else 
                    match k2attr nd.kind with
                      AId s -> s
                    | _ -> E.s (E.bug "replacePtrNodeAttrList")
                in
                foundNode := found;
                loop al
              with Not_found -> begin
                ignore (E.warn "Cannot find node %d\n" n);
                loop al
              end
          end
        | AId "safe" -> foundNode := "safe"; loop al
        | AId "index" -> foundNode := "index"; loop al
        | AId "seq" -> foundNode := "seq"; loop al
        | AId "fseq" -> foundNode := "fseq"; loop al
        | AId "seqn" -> foundNode := "seqn"; loop al
        | AId "fseqn" -> foundNode := "fseqn"; loop al
        | AId "wild" -> foundNode := "wild"; loop al
        | AId "sized" -> foundNode := "sized"; loop al
        | AId "tagged" -> foundNode := "tagged"; loop al
        | AId "string" -> foundNode := "string"; loop al
        | _ -> a :: loop al
    end
  in 
  let al' = loop al in (* Get the filtered attributes *)
  let kres = 
    match where with
      AtPtr -> 
        if !foundNode <> "" then !foundNode 
        else if !defaultIsWild then "wild" else "safe" 
    | AtArray -> 
        if !foundNode = "index" then "sized" 
        else if !foundNode = "seqn" then "nullterm" 
        else if !foundNode = "fseqn" then "nullterm" 
        else if !foundNode = "string" then "nullterm" 
        else !foundNode
    | AtVar ->
        if !foundNode = "wild" then "tagged" 
          (* wes: for some reason, these don't work in the AtArray slot
           * above *) 
        else if !foundNode = "seqn" then "nullterm" 
        else if !foundNode = "fseqn" then "nullterm" 
        else if !foundNode = "string" then "nullterm" 
        else !foundNode
    | AtOther -> !foundNode
  in
  if kres <> "" then 
    addAttribute (AId(kres)) al' 
  else 
    al'

  
(* Make a new node *)
let newNode (p: place) (idx: int) (bt: typ) (a: attribute list) : node =
  let where = p, idx in
  incr nextId;
  let kind,why_kind = kindOfAttrlist a in
  let n = { id = !nextId;
            btype   = bt;
            attr    = addAttribute (ACons("_ptrnode", [AInt !nextId])) a;
            where   = where;
            onStack = false;
            updated = false;
            arith   = false;
            posarith= false;
            null    = false;
            intcast = false;
            interface = false;
            succ = [];
            kind = kind;
            why_kind = why_kind; 
            sized = false ;
            pointsto = [];
            mark = false;
            pred = []; } in
(*  ignore (E.log "Created new node(%d) at %a\n" n.id d_placeidx where); *)
  H.add placeId where n;
  H.add idNode n.id n;
  (* Now set the pointsto nodes *)
  let _ =
    let doOneType = function
        TPtr (_, a) as t -> 
          (match nodeOfAttrlist a with
            Some n' -> addPointsTo n n'
          | None -> ());
          ExistsFalse

      | _ -> ExistsMaybe
    in
    existsType doOneType n.btype
  in
  n
    
  
let dummyNode = newNode (PGlob "@dummy") 0 voidType []

(* Get a node for a place and an index. Give also the base type and the 
 * attributes *)
let getNode (p: place) (idx: int) (bt: typ) (a: attribute list) : node = 
  (* See if exists already *)
  let where = (p, idx) in
  try
    H.find placeId where
  with Not_found -> newNode p idx bt a


let nodeExists (p: place) (idx: int) = 
  H.mem placeId (p, idx)


let addEdge (start: node) (dest: node) (kind: edgekind) (callid: int) = 
  if start != dummyNode && dest != dummyNode then begin
    let nedge = 
      { efrom = start; eto= dest; ekind = kind; ecallid = callid; } in
    start.succ <- nedge :: start.succ;
    dest.pred <- nedge :: dest.pred
  end


let removeSucc n sid = 
  n.succ <- List.filter (fun e -> e.eto.id <> sid) n.succ

let removePred n pid = 
  n.pred <- List.filter (fun e -> e.efrom.id <> pid) n.pred

let ptrAttrCustom printnode = function
      ACons("_ptrnode", [AInt n]) -> 
        if printnode then
          Some (dprintf "NODE(%d)" n)
        else begin
          try
            let nd = H.find idNode n in
            if nd.kind = Unknown && nd.why_kind = Default then
              Some nil (* Do not print these nodes *)
            else
              Some (d_pointerkind () nd.kind)
          with Not_found -> Some nil (* Do not print these nodes *)
        end
    | AId("ronly") -> Some (text "RONLY")
    | AId("safe") -> Some (text "SAFE")
    | AId("seq") -> Some (text "SEQ")
    | AId("fseq") -> Some (text "FSEQ")
    | AId("seqn") -> Some (text "SEQN")
    | AId("fseqn") -> Some (text "FSEQN")
    | AId("index") -> Some (text "INDEX")
    | AId("stack") -> Some (text "STACK")
    | AId("opt") -> Some (text "OPT")
    | AId("wild") -> Some (text "WILD")
    | AId("string") -> Some (text "STRING")
    | AId("sized") -> Some (text "SIZED")
    | AId("tagged") -> Some (text "TAGGED")
    | AId("nullterm") -> Some (text "NULLTERM")
    | a -> None



(**** Garbage collection of nodes ****)
(* I guess it is safe to call this even if you are not done with the whole 
 * program. Some not-yet-used globals will be collected but they will be 
 * regenerated later if needed *)
let gc () = 
  (* A list of all the nodes *)
  let all : node list ref = ref [] in
  H.iter (fun id n -> all := n :: !all) idNode;
  (* Scan all the nodes. The roots are globals with successors or 
   * predecessors *)
  let rec scanRoots n = 
    match n.where with
      (PGlob _, _) | (PStatic _, _) 
        when n.succ <> [] || n.pred <> [] -> scanOneNode n
    | _ -> ()
  and scanOneNode n = 
    if n.mark then ()
    else begin
      (* Do not mark the Offset nodes that have no successor and their only 
       * predecessor is the parent *)
      let keep =
        match n.where with
          (POffset (pid, _), _) -> 
            (match n.succ, n.pred with 
              [], [p] when p.efrom.id = pid -> false
            | _ -> true)
        | _ -> true
      in
      if keep then begin
        n.mark <- true;
        List.iter (fun se -> scanOneNode se.eto) n.succ;
        List.iter (fun se -> scanOneNode se.efrom) n.pred;
        List.iter scanOneNode n.pointsto
      end
    end
  in
  List.iter scanRoots !all;
  (* Now go over all nodes and delete those that are not marked *)
  List.iter 
    (fun n -> 
      if not n.mark then begin
        H.remove idNode n.id;
        H.remove placeId n.where;
        (* Remove this edge from all predecessors that are kept *)
        List.iter 
          (fun ep -> 
            let p = ep.efrom in 
            if p.mark then removeSucc p n.id) n.pred;
        List.iter
          (fun es -> 
            let s = es.eto in
            if s.mark then removePred s n.id) n.succ;
      end) !all;
  (* Now clear the mark *)
  List.iter (fun n -> n.mark <- false) !all
        
      
(** Graph Simplification **)
(* Collapse nodes which:
 *  (1) have only 1 predecessor edge
 *  (2) have only 1 successor edge
 *  (3) successor edge type = predecessor edge type
 *  (4) are the 0th node of a Local
 *)
let simplify () = 
  (* A list of all the nodes *)
  let examine_node id n = begin
    match n.where with
      (PAnon(_),0) | 
      (PLocal(_,_,_),1) -> if ((List.length n.succ) = 1) && 
                          ((List.length n.pred) = 1) && 
                          ((List.hd n.succ).ekind = (List.hd n.pred).ekind)
                          then begin
        (* we can remove this node *)
        let s = (List.hd n.succ).eto in
        let p = (List.hd n.pred).efrom in
        let k = (List.hd n.succ).ekind in
        removePred s id ;
        removeSucc p id ;
        addEdge p s k (-1) ;
        H.remove idNode n.id;
        H.remove placeId n.where;
      end
    | _ -> ()
  end in
  H.iter examine_node idNode 


(* Type names, computed in such a way that compatible types have the same id, 
 * even if they are syntactically different. Right now we flatten structures 
 * but we do not pull common subcomponents out of unions and we do not unroll 
 * arrays. *)


(* Some structs (those involved in recursive types) are named. This hash maps 
 * their name to the ID *)
let namedStructs : (string, string) H.t = H.create 110


(* Keep track of the structs in which we are (to detect loops). When we 
 * detect a loop we remember that *)
let inStruct : (string, bool ref) H.t = H.create 110


let rec typeIdentifier (t: typ) : string = 
  let res = typeId t in
  H.clear inStruct;  (* Start afresh next time *)
  res

and typeId = function
    TInt(ik, a) -> ikId ik ^ attrsId a
  | TVoid a -> "V" ^ attrsId a
  | TBitfield (ik, w, a) ->  "B" ^ ikId ik ^ 
                             string_of_int w ^ attrsId a
  | TFloat (fk, a) -> fkId fk ^ attrsId a
  | TEnum _ -> ikId IInt (* !!! *)
  | TNamed (_, t, a) -> typeId (typeAddAttributes a t)
  | TComp comp when comp.cstruct -> begin
      let hasPrefix s p = 
        let pl = String.length p in
        (String.length s >= pl) && String.sub s 0 pl = p
      in
      (* See if we are in a loop *)
      try
        let inloop = H.find inStruct comp.cname in
        inloop := true; (* Part of a recursive type *)
        "t" ^ prependLength comp.cname (* ^ attrsId comp.cattr *)
      with Not_found -> 
        let inloop = ref false in
        let isanon = hasPrefix comp.cname "__anon" in
        if not isanon then H.add inStruct comp.cname inloop;
        let fieldsids = 
          List.fold_left (fun acc f -> acc ^ typeId f.ftype) "" comp.cfields in
        (* If it is in a loop then keep its name *)
        let res = fieldsids (* ^ attrsId comp.cattr *) in
        if not isanon then H.remove inStruct comp.cname;
        if !inloop && not (H.mem namedStructs comp.cname) then begin
          H.add namedStructs comp.cname res;
          "t" ^ prependLength comp.cname (* ^ attrsId comp.cattr *)
        end else
          res
  end
  | TComp comp when not comp.cstruct -> 
      "N" ^ (string_of_int (List.length comp.cfields)) ^
      (List.fold_left (fun acc f -> acc ^ typeId f.ftype ^ "n") 
         "" comp.cfields) ^
      attrsId comp.cattr 
  | TForward (comp, a) -> typeId (typeAddAttributes a (TComp comp))
  | TPtr (t, a) -> "P" ^ typeId t ^ "p" ^ attrsId a
  | TArray (t, lo, a) -> 
      let thelen = "len" in
      "A" ^ typeId t ^ "a" ^ prependLength thelen ^ attrsId a
  | TFun (tres, args, va, a) -> 
      "F" ^ typeId tres ^ "f" ^ (string_of_int (List.length args)) ^ 
      (List.fold_left (fun acc arg -> acc ^ typeId arg.vtype ^ "f") 
         "" args) ^ (if va then "V" else "v") ^ attrsId a
  | _ -> E.s (E.bug "typeId")
      
and ikId = function
    IChar -> "C"
  | ISChar -> "c"
  | IUChar -> "b"
  | IInt -> "I"
  | IUInt -> "U"
  | IShort -> "S"
  | IUShort -> "s"
  | ILong -> "L"
  | IULong -> "l"
  | ILongLong -> "W"
  | IULongLong -> "w"

and fkId = function
    FFloat -> "O"
  | FDouble -> "D"
  | FLongDouble -> "T"

and attrId a = 
  let an = match a with
    AId s -> s
  | _ -> E.s (E.unimp "attrId: %a" d_attr a)
  in
  prependLength an

and prependLength s = 
  let l = String.length s in
  if s = "" || (s >= "0" && s <= "9") then
    E.s (E.unimp "String %s starts with a digit\n" s);
  string_of_int l ^ s

and attrsId al = 
  match al with
    [] -> "_"
  | _ -> "r" ^ List.fold_left (fun acc a -> acc ^ attrId a) "" al ^ "r"


