open Global

let num_pos_tests = ref 1
let num_neg_tests = ref 1
let test_script = ref "sh test.sh"
let test_command = ref ""

let _ = 
  options := !options @ 
    [ 
      "--testscript", Arg.Set_string test_script, "X test script." ;
      "--testcomm", Arg.Set_string test_command, "X test command."; 
      "--pos-tests", Arg.Set_int num_pos_tests, "X number of positive tests.";
      "--neg-tests", Arg.Set_int num_neg_tests, "X number of negative tests."
    ]
type test = 
  | Positive of int 
  | Negative of int 

let test_name t = match t with
  | Positive x -> Printf.sprintf "p%d" x
  | Negative x -> Printf.sprintf "n%d" x

let internal_test_case exe_name source_name test =
  let cmd = 
    let base_command = 
      match !test_command with 
      | "" -> 
        "__TEST_SCRIPT__ __TEST_NAME__  __EXE_NAME__"^
          "__SOURCE_NAME__ 2>/dev/null >/dev/null"
    |  x -> x
      in
      let cmd = Global.replace_in_string base_command 
        [ 
          "__TEST_SCRIPT__", !test_script ;
          "__EXE_NAME__", exe_name ;
          "__TEST_NAME__", (test_name test) ;
          "__SOURCE_NAME__", (source_name) ;
        ] 
      in 
        cmd
  in
    (* Run our single test. *) 
    let status = Stats2.time "test" Unix.system cmd in
      match status with 
      | Unix.WEXITED(0) -> true 
      | _ -> false

let run_tests coverage_outname coverage_exename coverage_sourcename = 
  let internal_run_tests  test_maker max_test expected = 
    lfoldl
      (fun (covering,unexpecteds) test ->
        let _ = 
          try Unix.unlink coverage_outname with _ -> ()
        in
        let cmd = Printf.sprintf "touch %s\n" coverage_outname in
        let _ = ignore(Unix.system cmd) in
        let actual_test = test_maker test in 
	      debug "\t%s\n" (test_name actual_test);
        let res = 
          internal_test_case coverage_exename coverage_sourcename actual_test
        in 
        let covering = 
          let lines = get_lines coverage_outname in 
            if (llen lines) > 0 then 
              actual_test :: covering
            else covering
        in
        let unexpecteds = 
          if res <> expected then actual_test :: unexpecteds
          else unexpecteds
        in
          covering,unexpecteds
          ) ([],[]) (1 -- max_test) 
  in
  let neg_touch,neg_unexpected = debug "coverage negative:\n"; 
      internal_run_tests (fun t -> Negative t) !num_neg_tests false 
  in
  let pos_touch,pos_unexpected = debug "coverage positive:\n"; 
        internal_run_tests (fun t -> Positive t) !num_pos_tests true in
    neg_touch @ pos_touch, neg_unexpected @ pos_unexpected
