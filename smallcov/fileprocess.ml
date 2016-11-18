open Global
open Cil

let preprocess_command = ref ""
let compiler_command = ref ""
let compiler_name = ref "gcc" 
let compiler_options = ref "" 

let _ = options := !options @ 
[
  "--compcmd", Arg.Set_string compiler_command, "X use X as compiler command";
  "--prepcmd", Arg.Set_string preprocess_command, "X preprocessing command.";
]
let cil_parse fname = Frontc.parse fname () 

let from_source (filename : string) = begin

  let _,ext = split_ext filename in 
    match ext with
      "txt" ->
        lfoldl 
          (fun map fname ->
            StringMap.add fname (cil_parse fname) map)
          (StringMap.empty) (get_lines filename)
    | "c" | "i" ->
      let parsed = cil_parse filename in
        StringMap.add filename parsed (StringMap.empty)
    | _  ->  abort "Unexpected file extension %s in CilRep#from_source.  Permitted: .c, .i, .cu, .cu, .txt" ext
end


exception MissingDefinition of string

(**
 * Determine the namespace and name for a global. The boolean indicates whether
 * the global represents a full definition (true) or just a declaration (false).
 *
 * There are three namespaces for globals defined in C: one for typedefs
 * (`DType), one for tagged types (structs, unions and enums: `DTag), and one
 * for variables and functions (`DVar). For example, you can have a struct and
 * a typedef with the same name since they are in different namespaces;
 * however, attempting to have a struct and an enum with the same name will
 * cause a compile error.
 *)
let get_dependency_tag g =
  match g with
  | GType(ti,_)        -> Some(`DType, false, ti.tname)
  | GCompTag(ci,_)     -> Some(`DTag,  true,  ci.cname)
  | GCompTagDecl(ci,_) -> Some(`DTag,  false, ci.cname)
  | GEnumTag(ei,_)     -> Some(`DTag,  true,  ei.ename)
  | GEnumTagDecl(ei,_) -> Some(`DTag,  false, ei.ename)
  | GVarDecl(vi,_)     -> Some(`DVar,  false, vi.vname)
  | GVar(vi,_,_)       -> Some(`DVar,  true,  vi.vname)
  | GFun(fd,_)         -> Some(`DVar,  true,  fd.svar.vname)
  | _                  -> None

(**
 * Generates a human-readable string form of the tag for debugging and error
 * messages.
 *)
let string_of_tag tag =
  match tag with
  | (`DType, true,  n) -> "typedef " ^ n ^ " (def)"
  | (`DType, false, n) -> "typedef " ^ n ^ " (decl)"
  | (`DTag,  true,  n) -> "tag " ^ n ^ " (def)"
  | (`DTag,  false, n) -> "tag " ^ n ^ " (decl)"
  | (`DVar,  true,  n) -> "var " ^ n ^ " (def)"
  | (`DVar,  false, n) -> "var " ^ n ^ " (decl)"

(**
 * [toposort instantiation_table visited globals tag] inserts the global
 * represented by [tag] into the list of globals, followed by the definitions
 * it requires, and returns the updated list of globals. Note that this list is
 * in the reverse order that the compiler expects. The [instantiation_table] is
 * a Hashtbl mapping dependency tags to the globals they represent. The
 * [visited] argument is a Hashtable allowing quick determination of whether a
 * global is in the list, in order to avoid multiple definitions and infinite
 * loops.
 *)
let rec toposort_one instantiations visited gs ((d,b,n) as tag) =
  let root = Hashtbl.find instantiations tag in
  if Hashtbl.mem visited tag then
    gs
  else begin
    let use_array_type = ref false in
    let children = ref [] in
    let enable_recursion = ref false in
    let visitor = object (self)
      inherit nopCilVisitor

      (**
       * Implements the dependency between the current [tag] (passed to
       * [toposort_one]) and the [tag'] passed to this method. Recursively
       * calls [toposort_one] to ensure that all the depdendencies for [tag']
       * are recorded in [gs] before the global represented by [tag'].
       *
       * Returns [SkipChildren] as a convenience to the calling visitation
       * method.
       *)
      method private add_deps ((d',b',n') as tag') : ('a visitAction) =
        (* Find the tag for a global satisfying this dependency. This could be
           the actual tag requested, if it exists, or a tag for a definition
           when we depend on a declaration. *)
        let tag'' =
          if Hashtbl.mem instantiations tag' then
            tag'
          else if Hashtbl.mem instantiations (d', true, n') then
            (d', true, n')
          else
            raise (MissingDefinition (string_of_tag tag'))
        in
        (* Guard that we do not depend on ourselves. *)
        if !enable_recursion && (d <> d' || n <> n') then
          children := toposort_one instantiations visited !children tag'';
        SkipChildren

      method vtype t =
        (* We always need the definition of a type in an array, but only need
           the declaration of a type that is only pointed to. *)
        let depended_type, b' =
          match t with
          | TArray(t',_,_) -> use_array_type := true; t', true
          | TPtr(t',_)     -> t', false
          | t'             -> t', b
        in

        (* Make sure the type we depend on has its dependencies met. *)
        match depended_type with
        | TNamed(ti,_) -> self#add_deps (`DType, b', ti.tname)
        | TComp(ci,_)  -> self#add_deps (`DTag, b', ci.cname)
        | TEnum(ei,_)  -> self#add_deps (`DTag, b', ei.ename)
        | _ -> DoChildren

      method vexpr e =
        match e with
        (* We are dependent on the definitions of types that the program takes
           the size or alignment of. Since we can only take the size or
           alignment when processing a definition, the current tag boolean is
           correct when accessed in [vtype]. *)

        | SizeOf(t)   -> ignore (self#vtype t); SkipChildren
        | AlignOf(t)  -> ignore (self#vtype t); SkipChildren

        (* We also need the definitions of p ointed-to types when doing pointer
           match since incrementing a pointer adjusts it by a multiple of the
           size of the data type. *)

        | BinOp((PlusPI|IndexPI|MinusPI),e1,_,_) ->
          ignore (self#vtype (typeOf (Lval(Mem(e1),NoOffset))));
          DoChildren
        | BinOp(MinusPP,e1,e2,_) ->
          ignore (self#vtype (typeOf (Lval(Mem(e1),NoOffset))));
          ignore (self#vtype (typeOf (Lval(Mem(e2),NoOffset))));
          DoChildren

        (* For everything else, we depend on the type of the expression itself
           since the compiler needs to know how to represent the result. *)

        | _ ->
          ignore (self#vtype (typeOf e));
          DoChildren

      (* We depend on the types of the hosts of all lvals since the compiler
         needs to know the layout of structures before it can access their
         fields. *)

      method vlval (host,off) =
        let _ = self#vtype (typeOfLval (host, NoOffset)) in
        DoChildren

      (* We also depend on declarations for any global variables used. *)

      method vvrbl vi =
        if vi.vglob then
          ignore (self#add_deps (`DVar, false, vi.vname));
        SkipChildren
    end in

    (* Although there is only one way to make a typedef, other code may depend
       on the typedef as a "declaration" or as a "definition". Usually, the
       typedef "declaration" depends on the declaration of the renamed type
       while the typedef "definition" depends on the definition of the renamed
       type. But even a "declaration" of a typedef of an array type requires
       the full definition of the renamed type. (Actually a typedef
       "declaration" may not even require a declaration of the named type at
       all, but this approach is usually good enough.) *)
 
    let b =
      match d with
      | `DType ->
        let _ = visitCilGlobal visitor root in
        b || !use_array_type
      | _ -> b
    in

    (* Visit the global, which will ensure our dependencies are in the list. *)

    children := gs;
    enable_recursion := true;
    let _ = visitCilGlobal visitor root in

    (* Check that visiting the dependencies didn't insert anything that would
       satisfy a dependency on us before inserting. *)

    if not (Hashtbl.mem visited (d,b,n))
        && not (d = `DType && (Hashtbl.mem visited (d, not b, n))) then
      children := root :: !children;

    (* Mark this as visited. If it is a definition, mark the declaration as
       well. *)

    Hashtbl.replace visited (d,b,n) true;
    if b then
      Hashtbl.replace visited (d, false, n) true;
    !children
  end

(**
 * Sorts the given globals so that all declarations and definitions appear
 * before their first use. If the optional ~roots argument it given, only
 * returns the dependencies (drawn from the other list) needed to compile those
 * globals. Otherwise, treats all globals as the roots.
 *)
let toposort_globals ?roots:((roots: global list) = []) (globals: global list) =
  let filter_map f xs =
    List.rev (List.fold_left (fun ys x ->
      match f x with
      | Some(y) -> y :: ys
      | None    -> ys
    ) [] xs)
  in
  let roots =
    match roots with
    | [] -> filter_map get_dependency_tag globals
    | _  -> filter_map get_dependency_tag roots
  in

  (* Build the instantiations and visited table for [toposort_one] *)
  let instantiations = Hashtbl.create (List.length globals) in
  List.iter (fun g ->
    match get_dependency_tag g with
    | Some(`DType,_,n) ->
      Hashtbl.replace instantiations (`DType,false,n) g;
      Hashtbl.replace instantiations (`DType,true,n) g;
    | Some(d,true,n) ->
      if not (Hashtbl.mem instantiations (d,false,n)) then begin
        match g with
        | GCompTag(ci,loc) ->
          Hashtbl.replace instantiations (d,false,n) (GCompTagDecl(ci,loc))
        | GEnumTag(ei,loc) ->
          Hashtbl.replace instantiations (d,false,n) (GEnumTagDecl(ei,loc))
        | GVar(vi,_,loc) ->
          Hashtbl.replace instantiations (d,false,n) (GVarDecl(vi,loc))
        | GFun(fd,loc) ->
          Hashtbl.replace instantiations (d,false,n) (GVarDecl(fd.svar,loc))
        | _ -> ()
      end;
      Hashtbl.replace instantiations (d,true,n) g
    | Some(tag) -> Hashtbl.add instantiations tag g
    | None      -> ()
  ) globals;

  let visited = Hashtbl.create (List.length globals) in

  (* Toposort each of the roots, using the same instantiations and visited
     tables. The result is reversed, so reverse it before returning. *)

  let deps =
    List.fold_left (toposort_one instantiations visited) [] roots
  in
  List.rev deps

(* Only instrument functions in the actual file under consideration. *)
let should_instrument_loc fname loc = 
(*debug "actual fname is: %s, current loc fname is: %s\n" fname loc.file;*)
true (* fixme *)


let va_table = Hashtbl.create 10

let fill_va_table = ref 
  ((fun () -> failwith "fill_va_table uninitialized") : unit -> 
   (string -> (Global.StringMap.key * Cil.formatArg) list -> Cil.stmt) *
    Cil.global list Global.StringMap.t)

class instrumentVisitor prototypes fname instr_outname = object
  inherit nopCilVisitor
  val cstmt = fst (!fill_va_table ())
  val mutable declared = false

  method vglob g =
    let missing_proto n vtyp =
      match vtyp with
      | TFun(_,_,_,tattrs) ->
        List.exists (fun tattr ->
          match tattr with
          | Attr("missingproto",_) -> true
          | _ -> false
        ) tattrs
      | _ -> false
    in
      if not declared then begin
        declared <- true;
        prototypes := snd (!fill_va_table ());
      end;
      (* Replace CIL-provided prototypes (which are probably wrong) with the
         ones we extracted from the system headers; but keep user-provided
         prototypes, since the user may have had a reason for specifying them *)
      match g with
      | GVarDecl(vi,_) when (StringMap.mem vi.vname !prototypes) ->
        if missing_proto vi.vname vi.vtype then begin
          ChangeDoChildrenPost([], fun gs -> gs)
        end else begin
          prototypes := StringMap.remove vi.vname !prototypes;
          ChangeDoChildrenPost([g], fun gs -> gs)
        end
      | _ -> ChangeDoChildrenPost([g], fun gs -> gs)

  method vfunc fd = 
    if should_instrument_loc fname fd.svar.vdecl then begin
      let print_str = "if (fout == 0) {\n fout = fopen(%g:fout_g,%g:wb_arg);\n}\n fprintf(fout, %g:str);\nfflush(fout);\n"
      in
      let newstmt = cstmt print_str 
        [("fout_g",Fg instr_outname);("str",Fg(fname)); ]
      in
        ChangeDoChildrenPost(fd,
                             (fun fd ->
                               fd.sbody.bstmts <- newstmt :: fd.sbody.bstmts;
                               fd))
    end else SkipChildren
end

let output_cil_file fname cfile = 
  let fout = open_out fname in
  let old_directive_style = !Cil.lineDirectiveStyle in
    Cil.lineDirectiveStyle := None ; 
    iterGlobals cfile (dumpGlobal defaultCilPrinter fout);
    Cil.lineDirectiveStyle := old_directive_style;
    close_out fout

let instrument_files (fmap) coverage_outname source_dir = begin
  let prototypes = ref StringMap.empty in
  let instrv = new instrumentVisitor prototypes in
  StringMap.fold
    (fun fname cfile accum ->  
      let outname = Filename.concat source_dir fname  in
        visitCilFile (instrv fname coverage_outname) cfile;
        cfile.globals <- 
          StringMap.fold (fun _ protos accum ->
            protos @ accum
          ) !prototypes cfile.globals;
        begin
          try
            cfile.globals <- toposort_globals cfile.globals;
          with MissingDefinition(s) ->
            debug "fileprocess: toposorting failure (%s)!\n" s;
      end;
      ensure_directories_exist outname;
      output_cil_file outname cfile;
      outname :: accum
    ) fmap []
end


let compile src_outname exec_outname =
debug "compiling: %s, %s\n" src_outname exec_outname; 
  let base_command = 
    match !compiler_command with
    | "" -> 
      "__COMPILER_NAME__ -o __EXE_NAME__ __SOURCE_NAME__ __COMPILER_OPTIONS__ "^
        "2>/dev/null >/dev/null"
    |  x -> x
  in
    let cmd = Global.replace_in_string base_command
      [
        "__COMPILER_NAME__", !compiler_name ;
        "__COMPILER_OPTIONS__", !compiler_options ;
        "__SOURCE_NAME__", src_outname ;
	"__EXE_NAME__", exec_outname
      ]
    in
    debug "compile cmd: %s\n" cmd;
    let result = match Unix.system cmd with
      | Unix.WEXITED(0) -> true
      | _ ->
        debug "\t%s %s fails to compile\n" src_outname exec_outname ;
        false
    in
    result

let void_t = Formatcil.cType "void *" [] 

let preprocess src_outname exec_outname =
  let base_command = 
    match !preprocess_command with
    | "" ->
      "__COMPILER_NAME__ -E __SOURCE_NAME__ __COMPILER_OPTIONS__ > __OUT_NAME__"
    | x -> x
  in
    let cmd = Global.replace_in_string base_command
      [
        "__COMPILER_NAME__", !compiler_name ;
        "__COMPILER_OPTIONS__", !compiler_options ;
        "__OUT_NAME__", exec_outname ;
        "__SOURCE_NAME__", src_outname ;
      ]
    in
    let result = match Unix.system cmd with
      | Unix.WEXITED(0) -> true
      | _ ->
        debug "\t%s %s fails to preprocess\n" src_outname exec_outname ;
        false
    in
    result

(* For most functions, we would like to use the prototypes as defined in the
   standard library used for this compiler. We do this by preprocessing a simple
   C file and extracting the prototypes from there. Since this should only
   happen when actually computing fault localization, the prototypes are lazily
   cached in the va_table. fill_va_table is called by the coverage visitor to
   fill the cache (if necessary) and retrieve the cstmt function along with the
   list of function declarations. *) 
let _ = 
  fill_va_table := (fun () -> 
  let vnames =
    [ "fclose"; "fflush"; "fopen"; "fprintf"; "memset"; "_coverage_fout" ]
  in
  if Hashtbl.length va_table = 0 then begin
    let source_file, chan = Filename.open_temp_file "tmp" ".c" in
    Printf.fprintf chan "#include <stdio.h>\n";
    Printf.fprintf chan "#include <string.h>\n";
    Printf.fprintf chan "FILE * _coverage_fout;\n";
    Printf.fprintf chan "int main() { return 0; }\n"; 
    close_out chan;

    let preprocessed = Filename.temp_file "tmp" ".c" in
    debug "fileprocess: preprocessing IO function signatures: %s %s\n" 
      source_file preprocessed;
    let cleanup () =
      if Sys.file_exists source_file then
        Sys.remove source_file;
      if Sys.file_exists preprocessed then
        Sys.remove preprocessed
    in
    if preprocess source_file preprocessed  then begin
      try
        let cilfile = 
          try cil_parse preprocessed 
          with e -> 
            debug "fileprocess: fill_va_table: Frontc.parse: %s\n" 
              (Printexc.to_string e) ; raise e 
        in
        if !Errormsg.hadErrors then
          Errormsg.parse_error
            "fileprocess: fill_va_table: failure while preprocessing stdio header file declarations\n";
        iterGlobals cilfile (fun g ->
          match g with
          | GVarDecl(vi,_) | GVar(vi,_,_) when lmem vi.vname vnames ->
            let decls = ref [] in
            let visitor = object (self)
              inherit nopCilVisitor

              method private depend t =
                match t with
                | TComp(ci,_) -> decls := GCompTagDecl(ci,locUnknown) :: !decls
                | TEnum(ei,_) -> decls := GEnumTagDecl(ei,locUnknown) :: !decls
                | _ -> ()

              method vtype t =
                match t with
                | TNamed(_) ->
                  ChangeDoChildrenPost(unrollType t, fun t -> self#depend t; t)
                | _ ->
                  self#depend t; DoChildren
            end in
            let _ = visitCilGlobal visitor g in
            let decls = g :: !decls in
            Hashtbl.add va_table vi.vname (vi,decls,true)
          | _ -> ()
        )
      with Frontc.ParseError(msg) ->
      begin
        debug "fileprocess: fill_va_table: %s\n" msg;
        Errormsg.hadErrors := false
      end
    end;
    debug "fileprocess: done preprocessing IO function signatures\n";
    cleanup()
  end;
  let static_args = lfoldl (fun lst x ->
      let is_fout = x = "_coverage_fout" in
      if not (Hashtbl.mem va_table x) then begin
        let vi = makeVarinfo true x void_t in
        Hashtbl.add va_table x (vi, [GVarDecl(vi,locUnknown)], is_fout)
      end;
      let name = if is_fout then "fout" else x in
      let vi, _, _ = Hashtbl.find va_table x in
      (name, Fv vi) :: lst
    ) [("wb_arg", Fg("wb")); ("a_arg", Fg("a"));] vnames
  in
  let cstmt stmt_str args = 
    Formatcil.cStmt ("{"^stmt_str^"}") (fun _ -> failwith "no new varinfos!")  !currentLoc 
    (args@static_args)
  in
  let global_decls = lfoldl (fun decls x ->
    match Hashtbl.find va_table x with
    | (_, gs, true) -> StringMap.add x gs decls
    | _             -> decls
    ) StringMap.empty vnames
  in
  cstmt, global_decls
  ) 
