%%% $Id$

-module(hipe_pack_constants).
-export([pack_constants/1,slim_refs/1]).
-include("hipe_ext_format.hrl").

pack_constants(Data) ->
  pack_constants(Data,0,0,[],[]).

pack_constants([{MFA,_,ConstTab}|Rest],AccSize,ConstNo,Acc,Refs) ->
  Labels = hipe_consttab:labels(ConstTab),
  %% RefToLabels = hipe_consttab:referred_labels(ConstTab),
  {Size, Map, NewConstNo, RefToLabels} = 
    pack_labels(Labels,MFA,ConstTab,AccSize, ConstNo,[], []),
  NewRefs =
    case  RefToLabels of 
      [] -> Refs;
      _ -> [{MFA,RefToLabels}| Refs]
    end,

  pack_constants(Rest, Size, NewConstNo, 
		 Map++Acc, NewRefs);
pack_constants([], Size, _, Acc, Refs) -> {Size, Acc, Refs}.

pack_labels([{_Label,ref}|Labels],MFA,ConstTab,AccSize, ConstNo, Acc, Refs) ->
  pack_labels(Labels,MFA,ConstTab,AccSize, ConstNo, Acc, Refs);
pack_labels([Label|Labels],MFA,ConstTab,AccSize, ConstNo, Acc, Refs) ->
  Const = hipe_consttab:lookup(Label,ConstTab),
  Size = hipe_consttab:const_size(Const),
  Align = hipe_consttab:const_align(Const),
  Start = 
    case AccSize rem Align of
      0 -> AccSize;

      N -> AccSize + (Align -N)
    end,
  Need = Size, %% Do we need to consider alignment?
  %% io:format("Const ~w, Size ~w, Need ~w\n",[Const,Size,Need]),
  RawType = hipe_consttab:const_type(Const),
  Type = ?CONST_TYPE2EXT(RawType),
  RawData = hipe_consttab:const_data(Const),
  {Data, NewRefs} = 
    case RawType of
      term -> {RawData,[]};
      sorted_block -> {RawData, []};
      block -> 
	case RawData of
	  {ElementType, ElementData} ->
	    decompose_block(ElementType, ElementData, Start);
	  {ElementType, ElementData, SortOrder} ->
	    {TblData, TblRefs} = get_sorted_refs(ElementData, SortOrder),
	    {hipe_consttab:decompose({ElementType, TblData}), [{sorted,Start,TblRefs}]}
	end
	    
    end,
		
  pack_labels(Labels,MFA,ConstTab,Start+Need,ConstNo+1,
	      [{MFA,Label,ConstNo,
		Start,Need,
		Type, Data,
		?BOOL2EXT(hipe_consttab:const_exported(Const))}|
	       Acc],
	      NewRefs++Refs);
pack_labels([],_,_,AccSize,ConstNo,Acc,Refs) ->
  {AccSize,Acc, ConstNo, Refs}.

decompose_block(ElementType, Data, Addr) ->
  ElementSize = hipe_consttab:size_of(ElementType),
  {NewData, Refs} = get_refs(Data,Addr,ElementSize),
  {hipe_consttab:decompose({ElementType, NewData}), Refs}.

get_refs([{label,L}|Rest],Pos,4) ->
  {NewData, Refs} = get_refs(Rest, Pos+4, 4),
  {[0|NewData],[{L,Pos}|Refs]};
get_refs([D|Rest],Pos, Size) ->
  {NewData, Refs} = get_refs(Rest, Pos+Size, Size),
  {[D|NewData],Refs};
get_refs([],_,_) ->
  {[],[]}.

get_sorted_refs([{label,L}|Rest], [Ordering|Os]) ->
  {NewData, Refs} = get_sorted_refs(Rest, Os),
  {[0|NewData],[{L,Ordering}|Refs]};
get_sorted_refs([D|Rest], [_Ordering|Os]) ->
  {NewData, Refs} = get_sorted_refs(Rest, Os),
  {[D|NewData],Refs};
get_sorted_refs([],[]) ->
  {[],[]}.



slim_refs([]) -> [];
slim_refs(Refs) ->
  [Ref|Rest] = lists:keysort(1,Refs),
  compact_ref_types(Rest,element(1,Ref),[Ref],[]).

compact_ref_types([Ref|Refs],Type,AccofType,Acc) ->
  case element(1,Ref) of
    Type ->
      compact_ref_types(Refs,Type,[Ref|AccofType], Acc);
    NewType ->
      compact_ref_types(Refs, NewType,[Ref], 
			[{Type,lists:sort(compact_dests(AccofType))}|
			 Acc])
  end;
compact_ref_types([],Type,AccofType,Acc) ->
  [{Type,lists:sort(compact_dests(AccofType))}|Acc].


compact_dests([]) -> [];
compact_dests(Refs) ->
  [Ref|Rest] = lists:keysort(3,Refs),
  compact_dests(Rest,element(3,Ref),[element(2,Ref)],[]).


compact_dests([Ref|Refs],Dest,AccofDest,Acc) ->
  case element(3,Ref) of
    Dest ->
      compact_dests(Refs,Dest,[element(2,Ref)|AccofDest], Acc);
    NewDest ->
      compact_dests(Refs, NewDest,[element(2,Ref)], [{Dest,AccofDest}|Acc])
  end;
compact_dests([],Dest,AccofDest,Acc) ->
  [{Dest,AccofDest}|Acc].