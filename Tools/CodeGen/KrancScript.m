
(*  Copyright 2012 Ian Hinder

    This file is part of Kranc.

    Kranc is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 2 of the License, or
    (at your option) any later version.

    Kranc is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with Kranc; if not, write to the Free Software
    Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
*)

BeginPackage["KrancScript`", {"Errors`", "Helpers`", "Kranc`", "JLink`",
                              "KrancTensor`", "Piraha`", "MapLookup`"}];

CreateThornFromKrancScript;

If[$KrancTensorPackage === "TensorTools", Needs["TensorTools`"]];

Begin["`Private`"];

DefFn[
  CreateThornFromKrancScript[filename_String] :=
  Module[
    {code,stringRules,thorn,processed},

    Print["Creating thorn from ",filename];

    code = ParsePEG["kranc2.peg", "thorn", filename];

    stringRules = XMLElement[s_,{___},c_] :> s@@c;

    thorn = code[[2]] //. stringRules;

    processed = process[thorn]
]];

process[h_[args___]] :=
  Module[
    {},
    Print[args];
    Print["No handler for ", h@@Map[ToString[Head[#]]&,{args}]];
    (* Print["Full expression is: ", HoldForm[h[args]]]; *)
    ThrowError["Failed to parse script"]];

AddTmpCalcs[eqns_] := Module[{tmpeqns={}},
  eqns /. TmpEqn["TmpVar"[var_],"TmpCalc"[calc_],"Result"[res_]] :> AppendTo[tmpeqns,calc];
  Join[eqns,tmpeqns]
];

process[thorn:"thorn"[content___]] :=
  Module[
    {calcs = {}, name, parameters = {}, variables = {}, temporaries = {Global`boundx,Global`boundy,Global`boundz}, tensors, kernels,
     nonScalars, tensorRule, withInds, options = {}, operators = {}, bounds, iter, position, pos},
    
    Do[Switch[el,
              "calculation"[___], AppendTo[calcs,process[el]],
              "uname"[_], name = el[[1]],
              "parameters"["begin parameters end parameters"], Null,
              "variables"["begin variables end variables"], Null,
              "temporaries"["begin temporaries end temporaries"], Null,
              "parameters"[__], parameters = Join[parameters,List@@Map[process,el]],
              "variables"[__], variables = Join[variables,List@@Map[process,el]],
              "temporaries"[__], temporaries = Join[temporaries,List@@Map[process,el]],
              "operators"[__], operators = Join[operators,process[el]],
              "option"[__], options = Join[options, process[el]],
              _, ThrowError["Unrecognised element '"<>Head[el]<>"' in thorn"]],
       {el, {content}}];
    Map[GenOp,operators];

    bounds = {
      Global`boundx->"bound_x",
      Global`boundy->"bound_y",
      Global`boundz->"bound_z"
    };
    position = Map[First,Position[calcs,Where->Boundary]];
    Do[
      pos = position[[iter]];
      calcs[[pos]] = calcs[[pos]] /. (Equations -> eqn_) :> (Equations -> Join[bounds,eqn]);
    ,{iter,1,Length[position]}];

    (* Pull out implicitly defined temporary equations *)
    calcs = calcs /. (Equations->eqn_) :> (Equations->AddTmpCalcs[eqn]);
    (* Pull out implicitly defined temporary variables *)
    calcs = calcs /. TmpEqn["TmpVar"[var_],"TmpCalc"[calc_],"Result"[res_]] :> (
      AppendTo[temporaries,var];
      res);

    tensors = Join[variables,temporaries];
    kernels = Map[If[AtomQ[#],#,First[#]] &, tensors];
    Scan[DefineTensor, kernels];
    nonScalars = Cases[tensors, _tensor];
    tensorRule = tensor[k_,inds__] :> k[inds];

    withInds = nonScalars /. tensorRule; (* This should trigger the tensor character
                                            definitions *)

    SetEnhancedTimes[False];

    (* Need to do something about derives here *)
    derivatives = {};
    options = Join[{RealParameters -> parameters, Calculations -> calcs, Variables -> variables, Shorthands -> temporaries} /. tensorRule,
                   {PartialDerivatives -> derivatives},
                   options];

    (* Print["Creating thorn ", name, " with options:"]; *)
    (* Print[options]; *)
    
    CreateKrancThornTT2[name,Sequence@@options]];

process[calc:"calculation"[content___]] :=
  Module[
    {name,eqs,joinWord,where},
    name = Cases[calc, "uname"[n_]:>n][[1]];
    eqs = Cases[calc, "eqns"[es___]:>{es}][[1]];

    schedule = Cases[calc, "schedule"[___,"uname"[s_],___]:>s][[1]];
    onClause = Cases[calc, "schedule"[___,"uname"[s_],"on_clause"["uname"[f_]]]:>f];

    where = If[Length[onClause] > 0,
      Replace[ToLowerCase[onClause[[1]]],
        {"boundary" :> Boundary,
          _ :> Error["Unrecognised domain for calculation: " <> ToString[onClause[[1]]]]}],
      (* else *)
      Automatic];

    joinWord = If[StringMatchQ[schedule,"initial",IgnoreCase->True] ||
                  StringMatchQ[schedule,"analysis",IgnoreCase->True],
                  "at","in"];

    {Name -> name,
     Equations -> Map[process,eqs],
     Schedule -> {joinWord<>" "<>schedule},
     Where -> where}];

process["eqn"[lhs_,rhs_]] := Module[{name,eqs}, process[lhs] -> process[rhs]];

process["tensor"["name"[k_],"indices"[]]] := ToExpression[If[Names[k] === {}, "Global`"<>k, k]];

process["tensor"["name"[nm_],"indices"[ind___],"bracket"[br1_,br2_,br3_]]] :=
  Module[{n1,n2,n3},
  n1 = process[br1];
  n2 = process[br2];
  n3 = process[br3];
  I3D[process["tensor"["name"[nm],"indices"[ind]]],n1,n2,n3]]

(*
process["tensor"["name"[nm_],"indices"[ind___],"bracket"[br1_]]] :=
  Module[{n1,n2,n3,br},
  n1 = process[br1];
  br = SetIndex[br1]; 
  Print["SetIndex=",IndexWasSet," br=",br];
  I3D[process["tensor"["name"[nm],"indices"[ind]]],n1,n2,n3]]
  *)

builtIns = {"true" -> True,
            "false" -> False,
            "PI" -> Pi};

Do[
  Module[
    {lhs = process["tensor"["name"[b[[1]]],"indices"[]]],
     rhs = b[[2]]},
    Evaluate[lhs] := rhs],
  {b,builtIns}];

process["tensor"["name"[k_],inds_]] :=
   tensor[ToExpression[If[Names[k] === {}, "Global`"<>k, k]],Sequence@@process[inds]];

fprint[x_] := (Print[x//InputForm]; x);

(* Simple operator rules *)
TempNum = 1
Clear[PDiv,MakeTemp,dtens];
MakeTemp[x1_,inds_] := Module[{tmpnm,inds2,tensorAST},
  tmpnm="tmp"<>ToString[TempNum++];
  inds2 = inds /.
    {
      TensorIndex[n1_,"l"] :> "lower_index"["index_symbol"[n1]],
      TensorIndex[n1_,"u"] :> "upper_index"["index_symbol"[n1]]
    } /. List->"indices";
  tensorAST="tensor"["name"[tmpnm],inds2];
  {tmpnm,tensorAST}];
MakeTemp[x1__] := 
  MakeTemp[x1,freesIn[x1]];

process["dtensor"["dname"[dname_],inds_,"tensor"[tensor__]]] := ToExpression[dname][process["tensor"[tensor]],Sequence@@process[inds]];

process["dtensor"["dname"["D"],inds_,"tensor"[tensor__]]] := PD[process["tensor"[tensor]],Sequence@@process[inds]];
process["dtensor"["dname"["D"],inds_,"expr"[tensor__]]] := Module[{summed,tmp,tmpAST,procexpr,result},
  procexpr =process["expr"[tensor]];
  tmparray=MakeTemp[procexpr];
  tmpAST = tmparray[[2]];
  tmp = process[tmpAST];
  tmpnm = tmparray[[1]];
  summed=makeSumOverDummies[PD[tmp,Sequence@@process[inds]]];
  (* Construct the AST for the equation, re-use Kranc machinery *)
  precalc="eqn"[tmpAST,"expr"[tensor]];
  calc=process[precalc];
  result=TmpEqn["TmpVar"[tmp],"TmpCalc"[calc],"Result"[summed]];
  result]

process["dtensor"["dname"["D"], "indices"["lower_index"["index_symbol"["t"]]],"tensor"[tensor__]]] :=
  dot[process["tensor"[tensor]]];

process["indices"[inds___]] := Map[process, {inds}];

process[(pos:("lower_index"|"upper_index"))["index_symbol"[i_]]] :=
  If[StringMatchQ[i,DigitCharacter],
     ToExpression[i],
     TensorIndex[i, If[pos==="lower_index","l","u"]]];

process["func"["name"[name_],exprs__]] :=
  Module[
    {fns},
    fns = {"sin" -> Sin, "cos" -> Cos,
           "tan" -> Tan, "cot" -> Cot,
           "sec" -> Sec, "csc" -> Csc,
           "atan" -> ArcTan, "asin" -> ArcSin, "acos" -> ArcCos,
           "sinh" -> Sinh, "cosh" -> Cosh, "tanh" -> Tanh,
           (* "if" -> IfThen, *) "max" -> Max, "min" -> Min,
           "abs"->Abs,"sqrt" -> Sqrt, "exp" -> Exp};
    If[MemberQ[First/@fns,name], (name/.fns)@@Map[process,{exprs}],
       (* If it's not a function call, it's an explicit multiply *)
       process["mul"["mexpr"["mul"["pow"["value"["tensor"["name"[name],"indices"[]]]]]],"mulop"["*"],"mexpr"[exprs]]]]];

process["mexpr"[mul_]] := process[mul];
process["mexpr"[]] := 0;

(* Addition, subtraction, multiplication and division are all left-associative *)
process["mexpr"[cs___, a_, "addop"["+"], b_]] := process["mexpr"[cs,a]] + process[b];
process["mexpr"[cs___, a_, "addop"["-"], b_]] := process["mexpr"[cs,a]] - process[b];

process["expr"[m:"mexpr"[___]]] := process[m];
process["expr"["neg"[_],m:"mexpr"[___]]] := -process[m];

process["mul"[pow_]] := process[pow];
process["mul"[]] := 1;
process["mul"[cs___, a_, "mulop"["*"], b_]] := process["mul"[cs,a]] * process[b];
process["mul"[cs___, a_, "mulimp"[___], b_]] := process["mul"[cs,a]] * process[b];
process["mul"[cs___, a_, "mulop"["/"], b_]] := process["mul"[cs,a]] / process[b];

process["pow"[a_,b_]] := process[a]^process[b];
process["pow"[a_]] := process[a];

process["value"[a_]] := process[a];

process["number"[a_]] := ToExpression[a];
process["rawmath"["rawtext"[rm_]]] := ToExpression[rm];
process["rawc"["rawtext"[rm_]]] := Global`RawMath[rm];

process["uname"[n_]] := n;

process["option"["inherit"[imps__]]] :=
  {InheritedImplementations -> Map[process, {imps}]};

process["option"["implement"[imp_]]] :=
  {Implementation -> process[imp]};

process["leftenc"[sym_],"number"[num_]] := sym <> num;
process["number"[num_],"rightenc"[sym_]] := num <> sym;
process["infinity"[_]] := "*";

processRange[value_,minOrMax_,paramName_] :=
  If[StringQ[value] && value === "*",value,
    Module[{tmp},
      tmp = N[value];
      If[NumberQ[tmp],1,ThrowError[minOrMax<>" value for parameter "<>paramName<>" is not a number"]];
      Return[tmp]]]

process["parameter"["name"[nm_], "type"[ty_]]] :=
Module[{dtmp,lotmp,hitmp},
  dtmp = 1.0;
  lotmp = "*";
  hitmp = "*";
  {Name -> ToExpression[nm],
   VariableType -> ty,
   Description -> "Parameter " <> nm, (*StringTake[desc,{2,StringLength[desc]-1}],*)
   AllowedValues -> {{Value->ToString[lotmp] <> ":" <> ToString[hitmp]}},
   Default -> dtmp}]

process["parameter"["name"[nm_],"type"[ty_],"expr"[exprd_]]] :=
Module[{dtmp,lotmp,hitmp},
  dtmp = process[exprd];
  lotmp = "*";
  hitmp = "*";
  {Name -> ToExpression[nm],
   VariableType -> ty,
   Description -> "Parameter " <> nm, (*StringTake[desc,{2,StringLength[desc]-1}],*)
   AllowedValues -> {{Value->ToString[lotmp] <> ":" <> ToString[hitmp]}},
   Default -> dtmp}]

process["parameter"["name"[nm_], "type"[ty_], "quote"[desc_], "expr"[exprd_]]] :=
Module[{dtmp,lotmp,hitmp},
  dtmp = process[exprd];
  lotmp = "*";
  hitmp = "*";
  {Name -> ToExpression[nm],
   VariableType -> ty,
   Description -> StringTake[desc,{2,StringLength[desc]-1}],
   AllowedValues -> {{Value->ToString[lotmp] <> ":" <> ToString[hitmp]}},
   Default -> dtmp}]

process["parameter"["name"[nm_],"type"[ty_],"quote"[desc_]]] :=
Module[{dtmp,lotmp,hitmp},
  dtmp = 1.0;
  lotmp = "*";
  hitmp = "*";
  {Name -> ToExpression[nm],
   VariableType -> ty,
   Description -> StringTake[desc,{2,StringLength[desc]-1}],
   AllowedValues -> {{Value->ToString[lotmp] <> ":" <> ToString[hitmp]}},
   Default -> dtmp}]

process["parameter"["name"[nm_],"type"[ty_],"quote"[desc_],"expr"[def_],"parlo"[le__],"parhi"[re__]]] := 
Module[{dtmp,lotmp,hitmp},
  dtmp = N[process[def]];
  lotmp = processRange[process[le],"Minimum",nm];
  hitmp = processRange[process[re],"Maximum",nm];
  If[NumberQ[dtmp],1,ThrowError["Default value for parameter "<>nm<>" is not a number"]];
  {Name -> ToExpression[nm],
   VariableType -> ty,
   Description -> StringTake[desc,{2,StringLength[desc]-1}],
   AllowedValues -> {{Value->ToString[lotmp] <> ":" <> ToString[hitmp]}},
   Default -> dtmp}]

flags = ScriptFlags;

process["option"["use"[features__]]] :=
  Map[(lookup[flags,#] -> True) &,{features}/.(("feature"[n_]):>n)];

process["option"["disable"[features__]]] :=
  Map[(lookup[flags,#] -> False) &,{features}/.(("feature"[n_]):>n)];

(* Operators *)

(* deqn[doper, name[xdiv], expr] *)
process[h:"operators"["deqns"[eqs___]]] :=
  Map[process, {eqs}];

process[d:"deqn"[___]] :=
  Module[{},
    Print["(deqn) No handler for ", d];
    ThrowError["Failed to parse script"]];

replaceInd[indices_,vals_] := Module[{i},
  Table[Rule[indices[[i]],vals[[i]]],{i,1,Length[vals]}]]

indexes[args_String] := Module[{arr,n,perm,i},
  arr=DeleteDuplicates[StringCases[args,RegularExpression["[a-w]"]]];
  n=Length[arr];
  perm=DeleteCases[Permutations[{"x","y","z"},n],_?(Length[#] != n&)];
  Table[StringReplace[args,
    replaceInd[arr,perm[[i]]]]
    ,{i,1,Length[perm]}]
  ];

IsIndex[arg_] := Length[StringCases[arg,RegularExpression["^[a-z]$"]]]===1;

CombineIndex[arg_] := arg
CombineIndex[Null,arg_] := CombineIndex[arg]
CombineIndex[arg_,Null] := CombineIndex[arg]
CombineIndex[Null,Null,arg_] := CombineIndex[arg]
CombineIndex[Null,arg_,Null] := CombineIndex[arg]
CombineIndex[arg_,Null,Null] := CombineIndex[arg]

GetIndex[arg_] := ThrowError["GetIndexError: "<>ToString[arg]];
GetIndex["name"[ind_?IsIndex]] := ind;
GetIndex[_String[_String]] := Null;
GetIndex[vc_[]] := Null;
GetIndex[vc_[arg1_,arg2_]] := CombineIndex[GetIndex[arg1],GetIndex[arg2]];
GetIndex[vc_[arg1_,arg2_,arg3_]] := CombineIndex[GetIndex[arg1],GetIndex[arg2],GetIndex[arg3]];

SetIndex[arg_] := ThrowError["SetIndexError: "<>ToString[arg]];
SetIndex["name"[ind_?IsIndex]] := Module[{},IndexWasSet := ind;"number"["0"]];
SetIndex[vc_[arg_]] := vc[SetIndex[arg]];
SetIndex[vc_] := vc;
SetIndex[vc_[]] := vc[];
SetIndex[vc_[arg1_,arg2_]] := vc[SetIndex[arg1],SetIndex[arg2]];
SetIndex[vc_[arg1_,arg2_,arg3_]] := vc[SetIndex[arg1],SetIndex[arg2],SetIndex[arg3]];

LookupTwo[val_,{},_] := Null;
LookupTwo[val_,_,{}] := Null;
LookupTwo[val_,{h1_,t1___},{h2_,t2___}] := If[val === h1,h2,LookupTwo[val,{t1},{t2}]];

NewBracket[dn_,expr_,arr_,perm_] :=
  Module[{indxLet,indx,br,res,i,expt},
    indxLet={};
    expt = (expr /.
      "name"[ind_?IsIndex] :> (AppendTo[indxLet,ind];"number"["0"]))
        /. "tensor"["number"["0"],"indices"[]] :> "number"["0"];
    indxLet=RemoveDuplicates[indxLet];
    Print["len=",Length[indxLet]];
    If[Length[indxLet]>1,ThrowError["Multiple indexes used together ("<>Riffle[indxLet,","]<>") in definition ("<>dn<>")"]];
    indxLet=indxLet[[1]];
    indx = LookupTwo[indxLet,arr,perm];
    If[indx == Null,ThrowError["Undefined Index ("<>indxLet<>") used in definition ("<>dn<>")"]];
    res=Apply["bracket",Table[
      If[i==indx,expt,"number"["0"]],{i,1,3}]];
    Return[res]
  ];

IndexRules[ar_,pm_] := Module[{i},
  Table[Rule["lower_index"["index_symbol"[ar[[i]]]],"number"[ ToString[pm[[i]]] ]],{i,1,Length[ar]}]]

GenArr["indices"[ind__]] := StringJoin[Map[GenArr,{ind}]];
GenArr["lower_index"[ind_]] := GenArr[ind];
GenArr["upper_index"[ind_]] := GenArr[ind];
GenArr["index_symbol"[letter_]] := letter;
GenArr[ind_] := ThrowError["GenArr "<>ToString[ind]];
GenOp[operator[dn_,ind_,nm_,ex_]] :=
  Module[{arr,perm,permno,str,uniqarr,uniqperm},
    arr=GenArr[ind];
    uniqarr=RemoveDuplicates[StringSplit[arr,""]];
    perm=indexes[arr];
    Print["arr=",arr," perm=",perm," u=",uniqarr];
    For[i=1,i<=Length[perm],i++,
      uniqperm = Map[ToExpression,RemoveDuplicates[StringSplit[StringReplace[perm[[i]],{"x"->"1","y"->"2","z"->"3"}],""]]];
      Print[uniqarr," => ",uniqperm];

      ex2 = ex /. "bracket"[br_] :> NewBracket[dn,br,uniqarr,uniqperm];
      ex2 = ex2 /. IndexRules[uniqarr,uniqperm];
      ex2 = ex2 /.
        "tensor"["name"["del"], "indices"["number"[nu_]]] :>
          "tensor"["name"[{"dx","dy","dz"}[[ToExpression[nu]]]],"indices"[]];

      permno=StringJoin[Riffle[StringCases[StringReplace[perm[[i]],{"x"->"1","y"->"2","z"->"3"}],RegularExpression["[1-3]"]],","]];
      str=dn<>"["<>nm<>"_,"<>permno<>"] = "<>ToString[InputForm[process[ex2]]];
      Print["str=",str];

      ToExpression[str];
    ]];

process["tname"[tens_]] := process[tens]
process["deqn"["doper"["dname"[dn_],ind:"indices"[__]],"barename"[nm_],"expr"[ex_]]] := 
  Module[{},
    operator[dn,ind,nm,ex]]

process["deqn"[("dtensor"["dname"[dname_],
                          "tensor"["name"[tName_],
                                   "indices"[tinds___]]]),
               rhs:"expr"[___]]] :=
  Module[
    {gridInds = {tinds} /. "lower_index"["index_symbol"[i_]] :> Unique[ToExpression@i],
     gridIndSyms,ind,rhsEval},
    gridIndSyms = {tinds} /. "lower_index"["index_symbol"[i_]] :> i;

    If[Length[gridIndSyms] > 1,
       ThrowError["Kranc does not yet support explicit specification of finite difference operators of dimension higher than 1.  1D operators will be automatically generalised to act on grid functions of all dimensions."]];

    rhsEval = (process[rhs] /. {tensor[ToExpression[tName],__] :> 1,
                                "int"[n_]:>ToExpression[n],
                                Global`h :> spacing[1],
                                Global`h1 :> spacing[1],
                                Global`h2 :> spacing[2],
                                Global`h3 :> spacing[3],
                                dimof[i_] :> Position[gridIndSyms,i][[1,1]]});

    ind = Unique[i];

    ToExpression[dname][Pattern[Evaluate[ind],_]] -> (rhsEval/.{spacing[1]->spacing[ind],shift[1]->shift[ind]})];

(* Differencing operators *)

process["tensor"["name"[k_],
                 "indices"[a___,
                           pos_["index_expr"[sym:"index_symbol"[i_],
                                             "index_op"[op_], int_]],
                           b___]]] :=
  (shift[dimof[i]]^If[op==="+", int, -int] *
   process["tensor"["name"[k],
                    "indices"[a,pos[sym],b]]]);

(* TODO: support multi-dimensional grid function accesses, i.e. v_(i+1,j) *)

process["tensor"["name"[k_],
                 "indices"[a___,
                           pos_["index_expr"[sym:"index_symbol"[___]]],
                           b___]]] :=
   process["tensor"["name"[k],
                           "indices"[a,pos[sym],b]]];



End[];

EndPackage[];
