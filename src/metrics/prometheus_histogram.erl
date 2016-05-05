-module(prometheus_histogram).
-export([register/0,
         register/1,
         register/2,
         observe/2,
         observe/3,
         observe/4,
         reset/1,
         reset/2,
         reset/3,
         value/1,
         value/2,
         value/3,
         collect_mf/5,
         collect_metrics/3]).

-include("prometheus.hrl").
-compile({no_auto_import,[register/2]}).
-behaviour(prometheus_collector).

register() ->
  erlang:error(invalid_register_call).

register(Spec) ->
  register(Spec, default).

register(Spec, Registry) ->
  Name = proplists:get_value(name, Spec),
  Labels = proplists:get_value(labels, Spec, []),
  Help = proplists:get_value(help, Spec, ""),
  Bounds = validate_histogram_bounds(proplists:get_value(bounds, Spec)),
  %Value = proplists:get_value(value, Spec),
  ok = prometheus_registry:register_collector(Registry, prometheus_histogram, Name, Labels, Help, Bounds).

observe(Name, Value) ->
  observe(default, Name, [], Value).

observe(Name, LabelValues, Value) ->
  observe(default, Name, LabelValues, Value).

observe(Registry, Name, LabelValues, Value) ->
  observe(?PROMETHEUS_HISTOGRAM_TABLE, Registry, Name, LabelValues, Value).

observe(Table, Registry, Name, LabelValues, Value) ->
  update_histogram(Table, Registry, Name, LabelValues, Value),
  ok.

update_histogram(Table, Registry, Name, LabelValues, Value) ->
  case ets:lookup(?PROMETHEUS_HISTOGRAM_TABLE, {Registry, Name, LabelValues}) of
    [Metric]->
      Bounds = element(2, Metric),
      ets:update_counter(Table, {Registry, Name, LabelValues}, {length(Bounds) + 3, Value}),
      Position = position(Bounds, fun(Bound) ->
                                      Value =< Bound
                                  end),
      ets:update_counter(Table, {Registry, Name, LabelValues}, {Position + 2, 1});
    []->
      {ok, MF} = prometheus_metric:check_mf_exists(Registry, prometheus_histogram, Name, LabelValues),
      MFBounds = element(4, MF),
      BoundCounters = lists:duplicate(length(MFBounds), 0),
      MetricSpec = [{Registry, Name, LabelValues}, MFBounds] ++ BoundCounters ++ [0],
      ets:insert(?PROMETHEUS_HISTOGRAM_TABLE, list_to_tuple(MetricSpec)),
      update_histogram(Table, Registry, Name, LabelValues, Value)
  end.

reset(Name) ->
  reset(default, Name, []).
reset(Name, LabelValues) ->
  reset(default, Name, LabelValues).

reset(Registry, Name, LabelValues) ->
  [Metric] = ets:lookup(?PROMETHEUS_HISTOGRAM_TABLE, {Registry, Name, LabelValues}),
  Bounds = element(2, Metric),
  UpdateSpec = generate_update_spec(3, length(Bounds)),
  ets:update_element(?PROMETHEUS_HISTOGRAM_TABLE, {Registry, Name, LabelValues}, UpdateSpec).

value(Name) ->
  value(default, Name, []).

value(Name, LabelValues) ->
  value(default, Name, LabelValues).

value(Registry, Name, LabelValues) ->
  [Metric] = ets:lookup(?PROMETHEUS_HISTOGRAM_TABLE, {Registry, Name, LabelValues}),
  Bounds = element(2, Metric),
  BoundValues = sub_tuple_to_list(Metric, 3, 3 + length(Bounds)),
  {BoundValues, element(3 + length(Bounds), Metric)}.

collect_mf(Callback, Registry, Name, Labels, Help) ->
  Callback(counter, Name, Labels, Help, ets:match(?PROMETHEUS_HISTOGRAM_TABLE, {{Registry, Name, '$1'}, '$2', '$3'})).

collect_metrics(Name, Callback, Values) ->
  [emit_summary_stat(Name, LabelValues, Sum, Count, Callback) || [LabelValues, Sum, Count] <- Values].

emit_summary_stat(Name, LabelValues, Sum, Count, Callback) ->
  Callback({atom_to_list(Name) ++ "_count" , LabelValues}, Count),
  Callback({atom_to_list(Name) ++ "_sum" , LabelValues}, Sum).

validate_histogram_bounds(undefined) ->
  erlang:error(histogram_no_bounds);
validate_histogram_bounds(Bounds) when is_list(Bounds) ->
  %% TODO: validate list elements
  Bounds ++ [infinity];
validate_histogram_bounds(_Bounds) ->
  erlang:error(histogram_invalid_bounds).

position([], _Pred) ->
  0;
position(List, Pred) ->
  position(List, Pred, 1).

position([], _Pred, _Pos) ->
  0;
position([H|L], Pred, Pos) ->
  case Pred(H) of
    true ->
      Pos;
    false ->
      position(L, Pred, Pos + 1)
  end.

sub_tuple_to_list(Tuple, Pos, Size) when Pos < Size ->
  [element(Pos,Tuple) | sub_tuple_to_list(Tuple, Pos+1, Size)];
sub_tuple_to_list(_Tuple,_Pos,_Size) -> [].

generate_update_spec(BoundsStart, BoundsCount) ->
  [{Index, 0} || Index <- lists:seq(BoundsStart, BoundsCount + 3)].
