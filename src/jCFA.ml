open Javalib_pack
open JBasics
open JBir
open Javalib

open JCFADom
open JCFAOptions
open Safe


module AbField = AbFSet
module AbVar = AbVSet
module CFASolver = Solver.Make(CFAConstraints) 


  (* This is a 'virtual' field that we use to represent abstraction of array
  * elements as a field abstraction. *)
let array_field_fs = 
  make_fs "array_elements" (TObject (TClass (java_lang_object)))

let vtype_is_primitive vt =
  match vt with 
    | TBasic _ -> true
    |_ -> false

let expr_is_primitive e = 
  match e with 
    | Const `ANull -> false
    | Const _ -> true
    | Var (vt,_) -> vtype_is_primitive vt
    | Unop (Cast _, _) -> false
    | Unop _ -> true
    | Binop (ArrayLoad vt,_,_) -> vtype_is_primitive vt
    | Binop _ -> true
    | StaticField (_,fs) 
    | Field (_,_,fs) -> vtype_is_primitive (fs_type fs)


let expr_dep expr prog = 
  let field_dep cn fs = 
    let fcl = JControlFlow.resolve_field fs (JControlFlow.resolve_class prog cn) in
      List.map 
        (fun fc ->`Field ((),JProgram.get_name fc,fs)) 
        fcl 
  in
  let rec expr_dep' expr = 
    match expr with
      | Unop (Cast _,expr) -> expr_dep' expr (*TODO: Maybe we can reduce dep, taking cast type into account*)
      | Binop (ArrayLoad _,e1,_e2) -> (expr_dep' e1)
      | Field (exprv, cn, fs) ->
          (field_dep cn fs) @ (expr_dep' exprv)
      | StaticField (cn, fs) ->
          (field_dep cn fs)
      | _ -> []
  in expr_dep' expr

let cast_set prog objt set = 
  match objt with
    | TArray _ -> set (*TODO*) 
    | TClass cn -> AbVSet.filter_with_compatible prog set cn


let pp_var_from_PP pp = 
  let (cn,ms) = 
    cms_split ((JBirPP.get_meth pp).cm_class_method_signature)
  in
  let pc = JBirPP.get_pc pp in
    `PP ((),cn,ms,pc)


let set_from_expr prog e abSt pp =
  let rec set_from_expr' e =
    let pp_var = pp_var_from_PP pp in
    let localvar = CFAState.get_PP abSt pp_var in
      match e with 
        | Const `ANull -> AbVar.empty
        | Var (_vt, v) -> AbLocals.get_var (index v) localvar 
        | Unop (Cast objtype , e ) -> 
            cast_set prog objtype (set_from_expr' e )
        | Binop (ArrayLoad _vt, e_obj, _e_idx) ->
            let f_var = `Field ((), java_lang_object, array_field_fs) in
            let abf = CFAState.get_field abSt f_var in
              AbField.fSet2var abf (set_from_expr' e_obj )
        | StaticField (cn, fs) ->
            let f_var = `Field ((),cn,fs) in
            let abf = CFAState.get_field abSt f_var in
              AbField.fSet2var abf AbField.static_field_dom

        | Field (e, cn, fs) -> 
            let f_var = `Field ((),cn,fs) in
            let abf = CFAState.get_field abSt f_var in
              AbField.fSet2var abf (set_from_expr' e )
        | _ -> assert false (*is primitive*)
  in set_from_expr' e



let abstract_instruction opt prog pp opcode succs csts =
  let pp_var = pp_var_from_PP pp in
  let propagate_locals ?(f=fun abSt -> CFAState.get_PP abSt pp_var) =  
    (fun abSt -> `PPDomain (f abSt))
  in
  let is_dead abSt  =
    let l = CFAState.get_PP abSt pp_var in
    AbLocals.isBot l 
  in

 let if_alive_meth abSt f = 
    match is_dead abSt with
      | true -> AbMethod.bot
      | false -> f
  in


  let make_csts ?(cstsl=csts) ?(other_dep=[]) ?(prop_locals_f=fun abSt -> CFAState.get_PP abSt pp_var) _ =
    List.fold_right 
      (fun target csts ->
         let pp_targ = pp_var_from_PP target in
           {CFAConstraints.dependencies = pp_var::other_dep;
            CFAConstraints.target = pp_targ;
            CFAConstraints.transferFun = propagate_locals ~f:prop_locals_f
           }::csts
      )
      succs 
      cstsl
  in
  let handle_invoke opt_ret cn_lst ms args =
    match opt_ret with 
      | None -> csts
      | Some ret_v ->
          (*Constraint on the method arguments.*)
          let csts_arg = 
            let deps = 
              List.fold_left 
                (fun odep arg -> (expr_dep arg prog)@odep)
                [pp_var;]
                args
            in
              List.fold_left
                (fun csts cn -> 
                   let m_var = `Method ((),cn,ms) in
                   let cst = 
                     {
                       CFAConstraints.dependencies = m_var::deps;
                       CFAConstraints.target = m_var;
                       CFAConstraints.transferFun =
                         (fun abSt ->
                            `MethodDomain
                              (let ab_m = CFAState.get_method abSt m_var in
                                 if_alive_meth abSt
                                   (
                                     let pos = ref (-1) in
                                     let set_args = 
                                       List.fold_left 
                                         (fun nl arg ->
                                            pos := !pos +1; 
                                            AbLocals.set_var !pos 
                                              (set_from_expr prog arg abSt pp) nl
                                         ) AbLocals.init args
                                     in
                                       AbMethod.join_args ab_m set_args
                                   )
                              )
                         )
                     }
                   in cst::csts
                )
                []
                cn_lst
          in
          (*constraint on the local variables*)
          let csts_ret = 
            List.fold_left
              (fun csts cn -> 
                 let m_var = `Method ((),cn,ms) in
                   List.fold_left 
                     (fun csts  target ->
                        let cst = 
                          let pp_targ = pp_var_from_PP target in
                            {
                              CFAConstraints.dependencies = [pp_var;m_var];
                              CFAConstraints.target = pp_targ;
                              CFAConstraints.transferFun =
                                (fun abSt ->
                                   let l = CFAState.get_PP abSt pp_var in
                                   let ab_m = CFAState.get_method abSt m_var in
                                     `PPDomain (AbLocals.set_var (index ret_v) 
                                       (AbMethod.get_return ab_m) l)
                                )
                            }
                        in 
                          cst::csts
                     )
                     csts
                     succs
              )
              []
              cn_lst
          in
            csts_arg@csts_ret@csts
  in
    match opcode with
      | Ifd _ (*TODO there is some interesting things to do*)
      | Goto _ 
      | MonitorEnter _
      | Check _
      | Formula _
      | MonitorExit _
      | Nop -> make_csts ()
      | AffectVar (v,e) ->
          let dep = expr_dep e prog in
            make_csts ~other_dep:dep ~prop_locals_f:
              (fun abSt -> 
                 Printf.printf "run affect\n";
                 let l = CFAState.get_PP abSt pp_var in
                   AbLocals.set_var (index v) (set_from_expr prog e abSt pp) l
              ) ()
      | AffectArray (e1, _e2, e3) (*e1[e2] = e3*) ->
          let dep = expr_dep e3 prog in
          let f_var = `Field ((),java_lang_object,array_field_fs) in
          let af_const = 
            {CFAConstraints.dependencies= pp_var::dep;
             CFAConstraints.target = f_var;
             CFAConstraints.transferFun= 
               (fun abSt -> `FieldDomain (AbField.var2fSet 
                                            (set_from_expr prog e1 abSt pp) 
                                            (set_from_expr prog e3 abSt pp)))
            }
          in
            make_csts ~cstsl:(af_const::csts) ()
      | AffectField (e1, cn, fs, e2) (*e1.<cn:fs> = e2*) -> 
          let dep = expr_dep e2 prog in
          let f_var = `Field ((),cn,fs) in
          let af_const = 
            {CFAConstraints.dependencies= pp_var::dep;
             CFAConstraints.target = f_var;
             CFAConstraints.transferFun= 
               (fun abSt -> `FieldDomain (AbField.var2fSet 
                                            (set_from_expr prog e1 abSt pp) 
                                            (set_from_expr prog e2 abSt pp)))
            }
          in
            make_csts ~cstsl:(af_const::csts) ()
      | AffectStaticField (cn, fs, e) -> (*<cn:fs> = e *)
          let dep = expr_dep e prog in
          let f_var = `Field ((),cn,fs) in
          let af_const = 
            {CFAConstraints.dependencies= pp_var::dep;
             CFAConstraints.target = f_var;
             CFAConstraints.transferFun= 
               (fun abSt -> `FieldDomain (AbField.var2fSet AbField.static_field_dom
                                            (set_from_expr prog e abSt pp)))
            }
          in
            make_csts ~cstsl:(af_const::csts) ()
      | Throw _e -> make_csts () (*TODO ??*)
      | Return opt_retexpr ->
          let c = JBirPP.get_class pp in
          let ms = 
            let m = JBirPP.get_meth pp in m.cm_signature in
          let m_var = `Method ((),JProgram.get_name c,ms) in
          let cstreturn = 
            (match opt_retexpr with 
              | None -> csts
              | Some ret_expr ->
                  let deps = (expr_dep ret_expr prog) @ [pp_var; m_var] in
                    { CFAConstraints.dependencies = deps;
                      CFAConstraints.target = m_var;
                      CFAConstraints.transferFun =
                        (fun abSt ->
                           `MethodDomain(
                             if_alive_meth abSt
                               (let vexpr = 
                                  set_from_expr prog ret_expr abSt pp
                                in
                                  AbMethod.join_return
                                    (CFAState.get_method abSt m_var) vexpr)))
                    }::csts)
	  in
            make_csts ~cstsl:(cstreturn) ()
            | New (v, cn, _vt_args, _args) ->
      make_csts ~prop_locals_f: 
        (fun abSt -> 
           let l = CFAState.get_PP abSt pp_var in
           AbLocals.set_var (index v) (AbVSet.singleton [pp] cn) l
        ) ()
      | NewArray (v, vt, _args) ->
          let rec gen_ar_cn vt =
            (match vt with
               | TBasic `Int -> make_cn "Sawja_array.Int"
               | TBasic `Short-> make_cn "Sawja_array.Short"
               | TBasic `Char -> make_cn "Sawja_array.Char"
               | TBasic `Byte -> make_cn "Sawja_array.Byte"
               | TBasic `Bool -> make_cn "Sawja_array.Bool"
               | TBasic `Long -> make_cn "Sawja_array.Long"
               | TBasic `Float -> make_cn "Sawja_array.Float"
               | TBasic `Double -> make_cn "Sawja_array.Double"
               | TObject (TClass cn) -> make_cn ("Sawja_array."^(cn_name cn))
               | TObject (TArray vt) -> make_cn ("Sawja_array."^
                                                 (cn_name (gen_ar_cn vt))))
          in
            make_csts ~prop_locals_f:
              (fun abSt -> 
                 let ar_cn = gen_ar_cn vt in
                 let l = CFAState.get_PP abSt pp_var in
                   AbLocals.set_var (index v) (AbVSet.singleton [pp] ar_cn) l
              ) ()
      | InvokeStatic (opt_ret, cn, ms, args) ->
          handle_invoke opt_ret [cn] ms args
      | InvokeVirtual (opt_ret, obje, _, ms, args) 
      | InvokeNonVirtual (opt_ret, obje, _ , ms, args) ->
          let cn_lst =
            match JBirPP.static_lookup prog pp with
              | None -> []
              | Some cl -> List.map JProgram.get_name cl
          in
            handle_invoke opt_ret cn_lst ms (obje::args)
      | MayInit cn ->
          if opt.cfa_clinit_as_entry
          then make_csts () (*clinit considered as entry point*)
          else (
            let ms = make_ms "clinit" [] None in
              handle_invoke None [cn] ms []
          )



let compute_csts prog opt node m =
  let open JBirPP in
    match m.cm_implementation with 
      | Native -> []
      | Java _laz -> 
          let iter_on_pp pp csts = 
            let lst_succ = (normal_successors pp)@
                           (exceptional_successors pp) in
              abstract_instruction opt prog pp (get_opcode pp) lst_succ csts
          in
          let cn = JProgram.get_name node in
          let ms = m.cm_signature in
          let first_pp = get_first_pp prog cn ms in
          let reachable_pp = reachable_pp first_pp in

            List.fold_left
              (fun csts pp -> 
                 iter_on_pp pp csts 
              )
              []
              reachable_pp




(*TODO: Do not use list but map/set ???*)
let get_csts program opt entry_points =

  let init_csts =
    List.fold_left 
      (fun lst cms ->
         let (cn, ms) = cms_split cms in
         let pp = JBirPP.get_first_pp program cn ms in
         let pp_var = pp_var_from_PP pp in
           {CFAConstraints.dependencies = [];
            CFAConstraints.target = pp_var ;
            CFAConstraints.transferFun = 
               (fun abst -> 
                                      `PPDomain AbLocals.init )
           }::lst
      )
      []
      entry_points
  in
  let csts = 
    ClassMethodMap.fold
      (fun _cms (node,m) csts ->
         (compute_csts program opt node m)@csts)
      program.JProgram.parsed_methods
      []
  in init_csts@csts


  (*TODO : add native exception *)
let initial_state _program entry_points =
  (* TODO: calculate init size on number of fields or methods of program ? *)
  let state = CFAState.bot (1,1,10000,100000, 1000000)   in
  List.iter
    (function `Method ((),cn,ms) ->
       CFAState.join
         state
         (`Method ((),cn,ms))
         (`MethodDomain (AbMethod.init))
    )
    entry_points;
  state

(*TODO: always fail if we are in unreachable code*)
let cfa_static_lookup state prog classes = 
  let open JProgram in
  fun cn ms pc ->
    let abm = CFAState.get_method state (`Method ((),cn,ms))
    in
      if AbMethod.isBot abm
      then ClassMethodSet.empty
      else
        (
          let caller_c = ClassMap.find cn classes in
          let m = get_method caller_c ms in
            match m with
              | AbstractMethod _ -> 
                  failwith "Can't call static_lookup on Abstract Methods"
              | ConcreteMethod cm ->
                  let pp = JBirPP.get_pp caller_c cm pc in 
                  let get_expr_state e = 
                    (AbVSet.concretize (set_from_expr prog e state pp))
                  in
                  (match cm.cm_implementation with 
                     | Native -> 
                         failwith "Can't call static_lookup on Native methods"
                     | Java bir_code ->
                         (match (JBir.code (Lazy.force bir_code)).(pc) with
                            | InvokeStatic (_ret ,called_cn, called_ms,_args) ->
                                let callee = match ClassMap.find called_cn classes with
                                  | Class c -> c
                                  | Interface _ -> raise IncompatibleClassChangeError
                                in let (_c,cm) =
                                  JControlFlow.invoke_static_lookup callee called_ms
                                in
                                  ClassMethodSet.singleton cm.cm_class_method_signature
                            | InvokeVirtual (_ret, obje, _, called_ms, _args) ->
                                let possible_cn = get_expr_state obje in
                                  ClassSet.fold
                                    (fun cn cmsset -> 
                                       let cms = make_cms cn called_ms in
                                         ClassMethodSet.add cms cmsset
                                    )
                                    possible_cn
                                    ClassMethodSet.empty 
                            | InvokeNonVirtual  (_ret, _e, cn, ms , _args) ->
                                let callee = match ClassMap.find cn classes with
                                  | Class c -> c
                                  | Interface _ -> raise IncompatibleClassChangeError
                                in let (_c,cm) =
                                  JControlFlow.invoke_special_lookup caller_c callee ms
                                in
                                  ClassMethodSet.singleton
                                    cm.cm_class_method_signature
                            | _ -> raise Not_found
                         )
                  )
        )

let upd_reachable_methods program state = 
  ClassMap.fold
    (fun cn nd rmmap -> 
       JProgram.cm_fold
         (fun cm rmmap -> 
            let abm = CFAState.get_method state 
                        (`Method ((),cn,cm.cm_signature)) in
              if AbMethod.isBot abm
              then rmmap
              else 
                (let cms = make_cms cn cm.cm_signature in
                   ClassMethodMap.add cms (nd, cm) rmmap)
         )
         nd
         rmmap
    )
    program.JProgram.classes
    ClassMethodMap.empty


let cfa_program_from_state st prog = 
  let open JProgram in
  {
    prog with
        static_lookup_method =
          cfa_static_lookup
            st
            prog
            prog.classes;
        parsed_methods = upd_reachable_methods prog st
  }

let print_cfa_prog prog state dir = JCFAPrinter.print prog state dir


let get_CFA_program 
      ?(opt=default_opt)
      (program: JBir.t JProgram.program)
      (entry_points:class_method_signature list)
      : JBir.t JProgram.program =
         CFASolver.debug_level := 10;
  let entry_st=
    List.map
      (fun cms -> let cn,ms =cms_split cms in `Method ((),cn,ms))
      entry_points
  in
  let csts = get_csts program opt entry_points
  and state = initial_state program entry_st in

  let state =
    CFASolver.solve_constraints program csts state entry_st
  in
  let prog = 
    cfa_program_from_state state program 
  in
    match opt.cfa_html_dump with
      | None -> prog
      | Some dir -> print_cfa_prog prog state dir; prog



