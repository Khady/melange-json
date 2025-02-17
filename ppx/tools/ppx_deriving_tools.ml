open Printf
open Ppxlib
open Ast_builder.Default
open StdLabels
open Expansion_helpers

exception Error of location * string

let error ~loc what = raise (Error (loc, what))

let not_supported ~loc what =
  raise (Error (loc, sprintf "%s are not supported" what))

let pexp_error ~loc msg =
  pexp_extension ~loc (Location.error_extensionf ~loc "%s" msg)

let stri_error ~loc msg = [%stri [%%ocaml.error [%e estring ~loc msg]]]
let map_loc f a_loc = { a_loc with txt = f a_loc.txt }

let gen_bindings ~loc prefix n =
  List.split
    (List.init ~len:n ~f:(fun i ->
         let id = sprintf "%s_%i" prefix i in
         let patt = ppat_var ~loc { loc; txt = id } in
         let expr = pexp_ident ~loc { loc; txt = lident id } in
         patt, expr))

let gen_tuple ~loc prefix n =
  let ps, es = gen_bindings ~loc prefix n in
  ps, pexp_tuple ~loc es

let gen_record ~loc prefix fs =
  let ps, es =
    List.split
      (List.map fs ~f:(fun (n, _attrs, _t) ->
           let id = sprintf "%s_%s" prefix n.txt in
           let patt = ppat_var ~loc { loc = n.loc; txt = id } in
           let expr = pexp_ident ~loc { loc = n.loc; txt = lident id } in
           (map_loc lident n, patt), expr))
  in
  let ns, ps = List.split ps in
  ps, pexp_record ~loc (List.combine ns es) None

let gen_pat_tuple ~loc prefix n =
  let patts, exprs = gen_bindings ~loc prefix n in
  ppat_tuple ~loc patts, exprs

let gen_pat_list ~loc prefix n =
  let patts, exprs = gen_bindings ~loc prefix n in
  let patt =
    List.fold_left (List.rev patts)
      ~init:[%pat? []]
      ~f:(fun prev patt -> [%pat? [%p patt] :: [%p prev]])
  in
  patt, exprs

let gen_pat_record ~loc prefix ns =
  let xs =
    List.map ns ~f:(fun n ->
        let id = sprintf "%s_%s" prefix n.txt in
        let patt = ppat_var ~loc { loc = n.loc; txt = id } in
        let expr = pexp_ident ~loc { loc = n.loc; txt = lident id } in
        (map_loc lident n, patt), expr)
  in
  ppat_record ~loc (List.map xs ~f:fst) Closed, List.map xs ~f:snd

let ( --> ) pc_lhs pc_rhs = { pc_lhs; pc_rhs; pc_guard = None }
let derive_of_label name = mangle (Suffix name)
let derive_of_longident name = mangle_lid (Suffix name)

let ederiver name (lid : Longident.t loc) =
  pexp_ident ~loc:lid.loc (map_loc (derive_of_longident name) lid)

type deriver =
  | As_fun of (expression -> expression)
  | As_val of expression

let as_val ~loc deriver x =
  match deriver with As_fun f -> f x | As_val f -> [%expr [%e f] [%e x]]

let as_fun ~loc deriver =
  match deriver with
  | As_fun f -> [%expr fun x -> [%e f [%expr x]]]
  | As_val f -> f

class virtual deriving =
  object
    method virtual name : label

    method virtual extension
        : loc:location -> path:label -> core_type -> expression

    method virtual generator
        : ctxt:Expansion_context.Deriver.t ->
          rec_flag * type_declaration list ->
          structure
  end

let register ?deps deriving =
  Deriving.add deriving#name
    ~str_type_decl:
      (Deriving.Generator.V2.make ?deps Deriving.Args.empty
         deriving#generator)
    ~extension:deriving#extension

let register_combined ?deps name derivings =
  let generator ~ctxt bindings =
    List.fold_left derivings ~init:[] ~f:(fun str d ->
        d#generator ~ctxt bindings @ str)
  in
  Deriving.add name
    ~str_type_decl:
      (Deriving.Generator.V2.make ?deps Deriving.Args.empty generator)

module Schema = struct
  let repr_row_field field =
    match field.prf_desc with
    | Rtag (id, _, ts) -> `Rtag (id, ts)
    | Rinherit { ptyp_desc = Ptyp_constr (id, ts); _ } ->
        `Rinherit (id, ts)
    | Rinherit _ ->
        not_supported ~loc:field.prf_loc "this polyvariant inherit"

  let repr_core_type ty =
    let loc = ty.ptyp_loc in
    match ty.ptyp_desc with
    | Ptyp_tuple ts -> `Ptyp_tuple ts
    | Ptyp_constr (id, ts) -> `Ptyp_constr (id, ts)
    | Ptyp_var txt -> `Ptyp_var { txt; loc = ty.ptyp_loc }
    | Ptyp_variant (fs, Closed, None) -> `Ptyp_variant fs
    | Ptyp_variant _ -> not_supported ~loc "non closed polyvariants"
    | Ptyp_arrow _ -> not_supported ~loc "function types"
    | Ptyp_any -> not_supported ~loc "type placeholders"
    | Ptyp_object _ -> not_supported ~loc "object types"
    | Ptyp_class _ -> not_supported ~loc "class types"
    | Ptyp_poly _ -> not_supported ~loc "polymorphic type expressions"
    | Ptyp_package _ -> not_supported ~loc "packaged module types"
    | Ptyp_extension _ -> not_supported ~loc "extension nodes"
    | Ptyp_alias _ -> not_supported ~loc "type aliases"

  let repr_type_declaration td =
    let loc = td.ptype_loc in
    match td.ptype_kind, td.ptype_manifest with
    | Ptype_abstract, None -> not_supported ~loc "abstract types"
    | Ptype_abstract, Some t -> `Ptype_core_type t
    | Ptype_variant ctors, _ -> `Ptype_variant ctors
    | Ptype_record fs, _ -> `Ptype_record fs
    | Ptype_open, _ -> not_supported ~loc "open types"

  let repr_type_declaration_is_poly td =
    match repr_type_declaration td with
    | `Ptype_core_type ({ ptyp_desc = Ptyp_variant _; _ } as t) ->
        `Ptyp_variant t
    | _ -> `Other

  let gen_type_ascription (td : type_declaration) =
    let loc = td.ptype_loc in
    ptyp_constr ~loc
      { loc; txt = lident td.ptype_name.txt }
      (List.map td.ptype_params ~f:(fun (p, _) ->
           match p.ptyp_desc with
           | Ptyp_var name -> ptyp_var ~loc name
           | _ -> failwith "this cannot be a type parameter"))

  class virtual deriving0 =
    object (self)
      inherit deriving

      method virtual t
          : loc:location -> label loc -> core_type -> core_type

      method derive_of_tuple
          : loc:location -> core_type list -> expression =
        not_supported "tuple types"

      method derive_of_record
          : loc:location -> label_declaration list -> expression =
        not_supported "record types"

      method derive_of_variant
          : loc:location -> constructor_declaration list -> expression =
        not_supported "variant types"

      method derive_of_polyvariant
          : loc:location -> row_field list -> expression =
        not_supported "polyvariant types"

      method private derive_type_ref_name
          : label -> longident loc -> expression =
        fun name n -> ederiver name n

      method derive_type_ref ~loc name n ts =
        let f = self#derive_type_ref_name name n in
        let args =
          List.fold_left (List.rev ts) ~init:[] ~f:(fun args a ->
              let a = self#derive_of_core_type a in
              (Nolabel, a) :: args)
        in
        pexp_apply ~loc f args

      method derive_of_core_type ty =
        let loc = ty.ptyp_loc in
        match repr_core_type ty with
        | `Ptyp_tuple ts -> self#derive_of_tuple ~loc ts
        | `Ptyp_constr (id, ts) ->
            self#derive_type_ref self#name ~loc id ts
        | `Ptyp_var label -> ederiver self#name (map_loc lident label)
        | `Ptyp_variant fs -> self#derive_of_polyvariant ~loc fs

      method derive_of_type_declaration td =
        let loc = td.ptype_loc in
        let name = td.ptype_name in
        let params =
          List.map td.ptype_params ~f:(fun (t, _) ->
              match t.ptyp_desc with
              | Ptyp_var txt -> { txt; loc = t.ptyp_loc }
              | _ -> failwith "type variable is not a variable")
        in
        let expr =
          match repr_type_declaration td with
          | `Ptype_core_type t -> self#derive_of_core_type t
          | `Ptype_variant ctors -> self#derive_of_variant ~loc ctors
          | `Ptype_record fs -> self#derive_of_record ~loc fs
        in
        let t = gen_type_ascription td in
        let expr = [%expr ([%e expr] : [%t self#t ~loc name t])] in
        let expr =
          List.fold_left params ~init:expr ~f:(fun body name ->
              pexp_fun ~loc Nolabel None
                (ppat_var ~loc (map_loc (derive_of_label self#name) name))
                body)
        in
        [
          value_binding ~loc
            ~pat:(ppat_var ~loc (self#derive_type_decl_label name))
            ~expr;
        ]

      method private derive_type_decl_label name =
        map_loc (derive_of_label self#name) name

      method extension
          : loc:location -> path:label -> core_type -> expression =
        fun ~loc:_ ~path:_ ty -> self#derive_of_core_type ty

      method generator
          : ctxt:Expansion_context.Deriver.t ->
            rec_flag * type_declaration list ->
            structure =
        fun ~ctxt (_rec_flag, type_decls) ->
          let loc = Expansion_context.Deriver.derived_item_loc ctxt in
          let bindings =
            List.concat_map type_decls ~f:(fun decl ->
                self#derive_of_type_declaration decl)
          in
          [%str
            [@@@ocaml.warning "-39-11-27"]

            [%%i pstr_value ~loc Recursive bindings]]
    end

  class virtual deriving1 =
    object (self)
      inherit deriving

      method virtual t
          : loc:location -> label loc -> core_type -> core_type

      method derive_of_tuple
          : core_type -> core_type list -> expression -> expression =
        fun t _ _ ->
          let loc = t.ptyp_loc in
          not_supported "tuple types" ~loc

      method derive_of_record
          : type_declaration ->
            label_declaration list ->
            expression ->
            expression =
        fun td _ _ ->
          let loc = td.ptype_loc in
          not_supported "record types" ~loc

      method derive_of_variant
          : type_declaration ->
            constructor_declaration list ->
            expression ->
            expression =
        fun td _ _ ->
          let loc = td.ptype_loc in
          not_supported "variant types" ~loc

      method derive_of_polyvariant
          : core_type -> row_field list -> expression -> expression =
        fun t _ _ ->
          let loc = t.ptyp_loc in
          not_supported "polyvariant types" ~loc

      method private derive_type_ref_name
          : label -> longident loc -> expression =
        fun name n -> ederiver name n

      method private derive_type_ref' ~loc name n ts =
        let f = self#derive_type_ref_name name n in
        let args =
          List.fold_left (List.rev ts) ~init:[] ~f:(fun args a ->
              let a = as_fun ~loc (self#derive_of_core_type' a) in
              (Nolabel, a) :: args)
        in
        As_val (pexp_apply ~loc f args)

      method derive_type_ref ~loc name n ts x =
        as_val ~loc (self#derive_type_ref' ~loc name n ts) x

      method private derive_of_core_type' t =
        let loc = t.ptyp_loc in
        match repr_core_type t with
        | `Ptyp_tuple ts -> As_fun (self#derive_of_tuple t ts)
        | `Ptyp_var label ->
            As_val (ederiver self#name (map_loc lident label))
        | `Ptyp_constr (id, ts) ->
            self#derive_type_ref' self#name ~loc id ts
        | `Ptyp_variant fs -> As_fun (self#derive_of_polyvariant t fs)

      method derive_of_core_type t x =
        let loc = x.pexp_loc in
        as_val ~loc (self#derive_of_core_type' t) x

      method private derive_type_decl_label name =
        map_loc (derive_of_label self#name) name

      method derive_of_type_declaration td =
        let loc = td.ptype_loc in
        let name = td.ptype_name in
        let rev_params =
          List.rev_map td.ptype_params ~f:(fun (t, _) ->
              match t.ptyp_desc with
              | Ptyp_var txt -> { txt; loc = t.ptyp_loc }
              | _ -> failwith "type variable is not a variable")
        in
        let x = [%expr x] in
        let expr =
          match repr_type_declaration td with
          | `Ptype_core_type t -> self#derive_of_core_type t x
          | `Ptype_variant ctors -> self#derive_of_variant td ctors x
          | `Ptype_record fs -> self#derive_of_record td fs x
        in
        let expr =
          [%expr
            (fun x -> [%e expr]
              : [%t self#t ~loc name (gen_type_ascription td)])]
        in
        let expr =
          List.fold_left rev_params ~init:expr ~f:(fun body param ->
              pexp_fun ~loc Nolabel None
                (ppat_var ~loc
                   (map_loc (derive_of_label self#name) param))
                body)
        in
        [
          value_binding ~loc
            ~pat:(ppat_var ~loc (self#derive_type_decl_label name))
            ~expr;
        ]

      method extension
          : loc:location -> path:label -> core_type -> expression =
        fun ~loc:_ ~path:_ ty ->
          let loc = ty.ptyp_loc in
          as_fun ~loc (self#derive_of_core_type' ty)

      method generator
          : ctxt:Expansion_context.Deriver.t ->
            rec_flag * type_declaration list ->
            structure =
        fun ~ctxt (_rec_flag, tds) ->
          let loc = Expansion_context.Deriver.derived_item_loc ctxt in
          let bindings =
            List.concat_map tds ~f:self#derive_of_type_declaration
          in
          [%str
            [@@@ocaml.warning "-39-11-27"]

            [%%i pstr_value ~loc Recursive bindings]]
    end
end

module Conv = struct
  type 'ctx tuple = {
    tpl_loc : location;
    tpl_types : core_type list;
    tpl_ctx : 'ctx;
  }

  type 'ctx record = {
    rcd_loc : location;
    rcd_fields : label_declaration list;
    rcd_ctx : 'ctx;
  }

  type variant_case =
    | Vcs_tuple of label loc * variant_case_ctx tuple
    | Vcs_record of label loc * variant_case_ctx record
    | Vcs_enum of label loc * variant_case_ctx

  and variant_case_ctx =
    | Vcs_ctx_variant of constructor_declaration
    | Vcs_ctx_polyvariant of row_field

  type variant = {
    vrt_loc : location;
    vrt_cases : variant_case list;
    vrt_ctx : variant_ctx;
  }

  and variant_ctx =
    | Vrt_ctx_variant of type_declaration
    | Vrt_ctx_polyvariant of core_type

  let repr_polyvariant_cases cs =
    let cases =
      List.rev cs |> List.map ~f:(fun c -> c, Schema.repr_row_field c)
    in
    let is_enum =
      List.for_all cases ~f:(fun (_, r) ->
          match r with
          | `Rtag (_, ts) -> (
              match ts with [] -> true | _ :: _ -> false)
          | `Rinherit _ -> false)
    in
    is_enum, cases

  let repr_variant_cases cs =
    let cs = List.rev cs in
    let is_enum =
      List.for_all cs ~f:(fun (c : constructor_declaration) ->
          match c.pcd_args with
          | Pcstr_record [] -> true
          | Pcstr_tuple [] -> true
          | Pcstr_record _ | Pcstr_tuple _ -> false)
    in
    is_enum, cs

  let deriving_of ~name ~of_t ~error ~derive_of_tuple ~derive_of_record
      ~derive_of_variant ~derive_of_variant_case () =
    let poly_name = sprintf "%s_poly" name in
    let poly =
      object (self)
        inherit Schema.deriving1
        method name = name
        method t ~loc _name t = [%type: [%t of_t ~loc] -> [%t t] option]

        method! derive_type_decl_label name =
          map_loc (derive_of_label poly_name) name

        method! derive_of_tuple t ts x =
          let t = { tpl_loc = t.ptyp_loc; tpl_types = ts; tpl_ctx = t } in
          derive_of_tuple self#derive_of_core_type t x

        method! derive_of_record _ _ _ = assert false
        method! derive_of_variant _ _ _ = assert false

        method! derive_of_polyvariant t (cs : row_field list) x =
          let loc = t.ptyp_loc in
          let is_enum, cases = repr_polyvariant_cases cs in
          let body, cases =
            List.fold_left cases
              ~init:([%expr None], [])
              ~f:(fun (next, cases) (c, r) ->
                match r with
                | `Rtag (n, ts) ->
                    let make arg =
                      [%expr Some [%e pexp_variant ~loc:n.loc n.txt arg]]
                    in
                    let ctx = Vcs_ctx_polyvariant c in
                    let case =
                      if is_enum then Vcs_enum (n, ctx)
                      else
                        let t =
                          { tpl_loc = loc; tpl_types = ts; tpl_ctx = ctx }
                        in
                        Vcs_tuple (n, t)
                    in
                    let next =
                      derive_of_variant_case self#derive_of_core_type make
                        case next
                    in
                    next, case :: cases
                | `Rinherit (id, ts) ->
                    let x = self#derive_type_ref ~loc poly_name id ts x in
                    let t = ptyp_variant ~loc cs Closed None in
                    let next =
                      [%expr
                        match [%e x] with
                        | Some x -> (Some x :> [%t t] option)
                        | None -> [%e next]]
                    in
                    next, cases)
          in
          let t =
            {
              vrt_loc = loc;
              vrt_cases = cases;
              vrt_ctx = Vrt_ctx_polyvariant t;
            }
          in
          derive_of_variant self#derive_of_core_type t body x
      end
    in
    (object (self)
       inherit Schema.deriving1 as super
       method name = name
       method t ~loc _name t = [%type: [%t of_t ~loc] -> [%t t]]

       method! derive_of_tuple t ts x =
         let t = { tpl_loc = t.ptyp_loc; tpl_types = ts; tpl_ctx = t } in
         derive_of_tuple self#derive_of_core_type t x

       method! derive_of_record td fs x =
         let t =
           { rcd_loc = td.ptype_loc; rcd_fields = fs; rcd_ctx = td }
         in
         derive_of_record self#derive_of_core_type t x

       method! derive_of_variant td cs x =
         let loc = td.ptype_loc in
         let is_enum, cs = repr_variant_cases cs in
         let body, cases =
           List.fold_left cs
             ~init:(error ~loc, [])
             ~f:(fun (next, cases) c ->
               let make (n : label loc) arg =
                 pexp_construct (map_loc lident n) ~loc:n.loc arg
               in
               let ctx = Vcs_ctx_variant c in
               let n = c.pcd_name in
               match c.pcd_args with
               | Pcstr_record fs ->
                   let t =
                     if is_enum then Vcs_enum (n, ctx)
                     else
                       let t =
                         { rcd_loc = loc; rcd_fields = fs; rcd_ctx = ctx }
                       in
                       Vcs_record (n, t)
                   in
                   let next =
                     derive_of_variant_case self#derive_of_core_type
                       (make n) t next
                   in
                   next, t :: cases
               | Pcstr_tuple ts ->
                   let case =
                     if is_enum then Vcs_enum (n, ctx)
                     else
                       let t =
                         { tpl_loc = loc; tpl_types = ts; tpl_ctx = ctx }
                       in
                       Vcs_tuple (n, t)
                   in
                   let next =
                     derive_of_variant_case self#derive_of_core_type
                       (make n) case next
                   in
                   next, case :: cases)
         in
         let t =
           {
             vrt_loc = loc;
             vrt_cases = cases;
             vrt_ctx = Vrt_ctx_variant td;
           }
         in
         derive_of_variant self#derive_of_core_type t body x

       method! derive_of_polyvariant t (cs : row_field list) x =
         let loc = t.ptyp_loc in
         let is_enum, cases = repr_polyvariant_cases cs in
         let body, cases =
           List.fold_left cases
             ~init:(error ~loc, [])
             ~f:(fun (next, cases) (c, r) ->
               let ctx = Vcs_ctx_polyvariant c in
               match r with
               | `Rtag (n, ts) ->
                   let make arg = pexp_variant ~loc:n.loc n.txt arg in
                   let case =
                     if is_enum then Vcs_enum (n, ctx)
                     else
                       let t =
                         { tpl_loc = loc; tpl_types = ts; tpl_ctx = ctx }
                       in
                       Vcs_tuple (n, t)
                   in
                   let next =
                     derive_of_variant_case self#derive_of_core_type make
                       case next
                   in
                   next, case :: cases
               | `Rinherit (n, ts) ->
                   let maybe_e =
                     poly#derive_type_ref ~loc poly_name n ts x
                   in
                   let t = ptyp_variant ~loc cs Closed None in
                   let next =
                     [%expr
                       match [%e maybe_e] with
                       | Some e -> (e :> [%t t])
                       | None -> [%e next]]
                   in
                   next, cases)
         in
         let t =
           {
             vrt_loc = loc;
             vrt_cases = cases;
             vrt_ctx = Vrt_ctx_polyvariant t;
           }
         in
         derive_of_variant self#derive_of_core_type t body x

       method! derive_of_type_declaration td =
         match Schema.repr_type_declaration_is_poly td with
         | `Ptyp_variant _ ->
             let str =
               let loc = td.ptype_loc in
               let decl_name = td.ptype_name in
               let params =
                 List.map td.ptype_params ~f:(fun (t, _) ->
                     match t.ptyp_desc with
                     | Ptyp_var txt -> t, { txt; loc = t.ptyp_loc }
                     | _ -> assert false)
               in
               let expr =
                 let x = [%expr x] in
                 let init =
                   poly#derive_type_ref ~loc poly_name
                     (map_loc lident decl_name)
                     (List.map params ~f:fst) x
                 in
                 let init =
                   [%expr
                     (fun x ->
                        match [%e init] with
                        | Some x -> x
                        | None -> [%e error ~loc]
                       : [%t
                           self#t ~loc decl_name
                             (Schema.gen_type_ascription td)])]
                 in
                 List.fold_left params ~init ~f:(fun body (_, param) ->
                     pexp_fun ~loc Nolabel None
                       (ppat_var ~loc
                          (map_loc (derive_of_label name) param))
                       body)
               in
               [
                 value_binding ~loc
                   ~pat:
                     (ppat_var ~loc
                        (map_loc (derive_of_label self#name) decl_name))
                   ~expr;
               ]
             in
             poly#derive_of_type_declaration td @ str
         | `Other -> super#derive_of_type_declaration td
     end
      :> deriving)

  let deriving_of_match ~name ~of_t ~error ~derive_of_tuple
      ~derive_of_record ~derive_of_variant_case () =
    let poly_name = sprintf "%s_poly" name in
    let poly =
      object (self)
        inherit Schema.deriving1
        method name = name
        method t ~loc _name t = [%type: [%t of_t ~loc] -> [%t t] option]

        method! derive_type_decl_label name =
          map_loc (derive_of_label poly_name) name

        method! derive_of_tuple t ts x =
          let t = { tpl_loc = t.ptyp_loc; tpl_types = ts; tpl_ctx = t } in
          derive_of_tuple self#derive_of_core_type t x

        method! derive_of_record _ _ _ = assert false
        method! derive_of_variant _ _ _ = assert false

        method! derive_of_polyvariant t (cs : row_field list) x =
          let loc = t.ptyp_loc in
          let is_enum, cases = repr_polyvariant_cases cs in
          let ctors, inherits =
            List.partition_map cases ~f:(fun (c, r) ->
                let ctx = Vcs_ctx_polyvariant c in
                match r with
                | `Rtag (n, ts) ->
                    if is_enum then Left (n, Vcs_enum (n, ctx))
                    else
                      let t =
                        { tpl_loc = loc; tpl_types = ts; tpl_ctx = ctx }
                      in
                      Left (n, Vcs_tuple (n, t))
                | `Rinherit (n, ts) -> Right (n, ts))
          in
          let catch_all =
            [%pat? x]
            --> List.fold_left (List.rev inherits) ~init:[%expr None]
                  ~f:(fun next (n, ts) ->
                    let maybe =
                      self#derive_type_ref ~loc poly_name n ts [%expr x]
                    in
                    let t = ptyp_variant ~loc cs Closed None in
                    [%expr
                      match [%e maybe] with
                      | Some x -> (Some x :> [%t t] option)
                      | None -> [%e next]])
          in
          let cases =
            List.fold_left ctors ~init:[ catch_all ]
              ~f:(fun next (n, case) ->
                let make arg =
                  [%expr Some [%e pexp_variant ~loc:n.loc n.txt arg]]
                in
                derive_of_variant_case self#derive_of_core_type make case
                :: next)
          in
          pexp_match ~loc x cases
      end
    in
    (object (self)
       inherit Schema.deriving1 as super
       method name = name
       method t ~loc _name t = [%type: [%t of_t ~loc] -> [%t t]]

       method! derive_of_tuple t ts x =
         let t = { tpl_loc = t.ptyp_loc; tpl_types = ts; tpl_ctx = t } in
         derive_of_tuple self#derive_of_core_type t x

       method! derive_of_record td fs x =
         let t =
           { rcd_loc = td.ptype_loc; rcd_fields = fs; rcd_ctx = td }
         in
         derive_of_record self#derive_of_core_type t x

       method! derive_of_variant td cs x =
         let loc = td.ptype_loc in
         let is_enum, cs = repr_variant_cases cs in
         let cases =
           List.fold_left cs
             ~init:[ [%pat? _] --> error ~loc ]
             ~f:(fun next (c : constructor_declaration) ->
               let ctx = Vcs_ctx_variant c in
               let make (n : label loc) arg =
                 pexp_construct (map_loc lident n) ~loc:n.loc arg
               in
               let n = c.pcd_name in
               match c.pcd_args with
               | Pcstr_record fs ->
                   let t =
                     if is_enum then Vcs_enum (n, ctx)
                     else
                       let r =
                         { rcd_loc = loc; rcd_fields = fs; rcd_ctx = ctx }
                       in
                       Vcs_record (n, r)
                   in
                   derive_of_variant_case self#derive_of_core_type
                     (make n) t
                   :: next
               | Pcstr_tuple ts ->
                   let t =
                     if is_enum then Vcs_enum (n, ctx)
                     else
                       let t =
                         { tpl_loc = loc; tpl_types = ts; tpl_ctx = ctx }
                       in
                       Vcs_tuple (n, t)
                   in
                   derive_of_variant_case self#derive_of_core_type
                     (make n) t
                   :: next)
         in
         pexp_match ~loc x cases

       method! derive_of_polyvariant t (cs : row_field list) x =
         let loc = t.ptyp_loc in
         let is_enum, cases = repr_polyvariant_cases cs in
         let ctors, inherits =
           List.partition_map cases ~f:(fun (c, r) ->
               let ctx = Vcs_ctx_polyvariant c in
               match r with
               | `Rtag (n, ts) ->
                   if is_enum then Left (n, Vcs_enum (n, ctx))
                   else
                     let t =
                       { tpl_loc = loc; tpl_types = ts; tpl_ctx = ctx }
                     in
                     Left (n, Vcs_tuple (n, t))
               | `Rinherit (n, ts) -> Right (n, ts))
         in
         let catch_all =
           [%pat? x]
           --> List.fold_left (List.rev inherits) ~init:(error ~loc)
                 ~f:(fun next (n, ts) ->
                   let maybe =
                     poly#derive_type_ref ~loc poly_name n ts x
                   in
                   let t = ptyp_variant ~loc cs Closed None in
                   [%expr
                     match [%e maybe] with
                     | Some x -> (x :> [%t t])
                     | None -> [%e next]])
         in
         let cases =
           List.fold_left ctors ~init:[ catch_all ]
             ~f:(fun next ((n : label loc), t) ->
               let make arg = pexp_variant ~loc:n.loc n.txt arg in
               derive_of_variant_case self#derive_of_core_type make t
               :: next)
         in
         pexp_match ~loc x cases

       method! derive_of_type_declaration td =
         match Schema.repr_type_declaration_is_poly td with
         | `Ptyp_variant _ ->
             let str =
               let loc = td.ptype_loc in
               let decl_name = td.ptype_name in
               let params =
                 List.map td.ptype_params ~f:(fun (t, _) ->
                     match t.ptyp_desc with
                     | Ptyp_var txt -> t, { txt; loc = t.ptyp_loc }
                     | _ -> assert false)
               in
               let expr =
                 let x = [%expr x] in
                 let init =
                   poly#derive_type_ref ~loc poly_name
                     (map_loc lident decl_name)
                     (List.map params ~f:fst) x
                 in
                 let init =
                   [%expr
                     (fun x ->
                        match [%e init] with
                        | Some x -> x
                        | None -> [%e error ~loc]
                       : [%t
                           self#t ~loc decl_name
                             (Schema.gen_type_ascription td)])]
                 in
                 List.fold_left params ~init ~f:(fun body (_, param) ->
                     pexp_fun ~loc Nolabel None
                       (ppat_var ~loc
                          (map_loc (derive_of_label name) param))
                       body)
               in
               [
                 value_binding ~loc
                   ~pat:
                     (ppat_var ~loc
                        (map_loc (derive_of_label self#name) decl_name))
                   ~expr;
               ]
             in
             poly#derive_of_type_declaration td @ str
         | `Other -> super#derive_of_type_declaration td
     end
      :> deriving)

  let deriving_to ~name ~t_to ~derive_of_tuple ~derive_of_record
      ~derive_of_variant_case () =
    (object (self)
       inherit Schema.deriving1
       method name = name
       method t ~loc _name t = [%type: [%t t] -> [%t t_to ~loc]]

       method! derive_of_tuple t ts x =
         let loc = t.ptyp_loc in
         let t = { tpl_loc = loc; tpl_types = ts; tpl_ctx = t } in
         let n = List.length ts in
         let p, es = gen_pat_tuple ~loc "x" n in
         pexp_match ~loc x
           [ p --> derive_of_tuple self#derive_of_core_type t es ]

       method! derive_of_record td fs x =
         let t =
           { rcd_loc = td.ptype_loc; rcd_fields = fs; rcd_ctx = td }
         in
         let loc = td.ptype_loc in
         let p, es =
           gen_pat_record ~loc "x" (List.map fs ~f:(fun f -> f.pld_name))
         in
         pexp_match ~loc x
           [ p --> derive_of_record self#derive_of_core_type t es ]

       method! derive_of_variant td cs x =
         let loc = td.ptype_loc in
         let ctor_pat (n : label loc) pat =
           ppat_construct ~loc:n.loc (map_loc lident n) pat
         in
         let is_enum, cs = repr_variant_cases cs in
         pexp_match ~loc x
           (List.rev_map cs ~f:(fun c ->
                let n = c.pcd_name in
                let ctx = Vcs_ctx_variant c in
                match c.pcd_args with
                | Pcstr_record fs ->
                    let p, es =
                      gen_pat_record ~loc "x"
                        (List.map fs ~f:(fun f -> f.pld_name))
                    in
                    let t =
                      if is_enum then Vcs_enum (n, ctx)
                      else
                        let t =
                          {
                            rcd_loc = loc;
                            rcd_fields = fs;
                            rcd_ctx = ctx;
                          }
                        in
                        Vcs_record (n, t)
                    in
                    ctor_pat n (Some p)
                    --> derive_of_variant_case self#derive_of_core_type t
                          es
                | Pcstr_tuple ts ->
                    let arity = List.length ts in
                    let t =
                      if is_enum then Vcs_enum (n, ctx)
                      else
                        let t =
                          { tpl_loc = loc; tpl_types = ts; tpl_ctx = ctx }
                        in
                        Vcs_tuple (n, t)
                    in
                    let p, es = gen_pat_tuple ~loc "x" arity in
                    ctor_pat n (if arity = 0 then None else Some p)
                    --> derive_of_variant_case self#derive_of_core_type t
                          es))

       method! derive_of_polyvariant t (cs : row_field list) x =
         let loc = t.ptyp_loc in
         let is_enum, cases = repr_polyvariant_cases cs in
         let cases =
           List.rev_map cases ~f:(fun (c, r) ->
               let ctx = Vcs_ctx_polyvariant c in
               match r with
               | `Rtag (n, []) ->
                   let t =
                     if is_enum then Vcs_enum (n, ctx)
                     else
                       let t =
                         { tpl_loc = loc; tpl_types = []; tpl_ctx = ctx }
                       in
                       Vcs_tuple (n, t)
                   in
                   ppat_variant ~loc n.txt None
                   --> derive_of_variant_case self#derive_of_core_type t
                         []
               | `Rtag (n, ts) ->
                   assert (not is_enum);
                   let t =
                     { tpl_loc = loc; tpl_types = ts; tpl_ctx = ctx }
                   in
                   let ps, es = gen_pat_tuple ~loc "x" (List.length ts) in
                   ppat_variant ~loc n.txt (Some ps)
                   --> derive_of_variant_case self#derive_of_core_type
                         (Vcs_tuple (n, t))
                         es
               | `Rinherit (n, ts) ->
                   assert (not is_enum);
                   [%pat? [%p ppat_type ~loc n] as x]
                   --> self#derive_of_core_type
                         (ptyp_constr ~loc:n.loc n ts)
                         [%expr x])
         in
         pexp_match ~loc x cases
     end
      :> deriving)
end

include Schema
