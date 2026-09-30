#!/usr/bin/env escript
%%! +S 2:2 +SDcpu 2
main([]) -> main(["/app/lib/salix_verified_kernel"]);
main([AppDir]) ->
    true = code:add_patha(filename:join(AppDir, "ebin")),
    false = filelib:is_dir("/opt/elan"),
    [_ | _] = 'Elixir.SalixVerifiedKernel':protocol_atoms(),
    Parent = self(),
    [spawn(fun() ->
        [begin
            Payload = #{worker => Id, count => N, bytes => binary:copy(<<Id>>, 4096)},
            {1, ok, Payload} = invoke({1, codec, 1, roundtrip, Payload})
        end || N <- lists:seq(1, 100)],
        Parent ! done
    end) || Id <- lists:seq(1, 16)],
    [receive done -> ok after 30000 -> error(timeout) end || _ <- lists:seq(1, 16)],
    State = #{'__struct__' => 'Elixir.SalixAgent.InternalSession.State',
        status => active, activity_status => thinking, session_id => <<"s">>,
        async_tool_calls => #{<<"a">> => #{<<"status">> => <<"running">>}},
        last_seq => 0, async_results => [], async_result_refs => #{}},
    Event = #{<<"type">> => <<"async_tool_call_progress">>,
        <<"tool_call_id">> => <<"a">>, <<"progress">> => #{<<"percent">> => 50}},
    {Resident, {1, ok, opened}} = session(nil, open, State),
    true = is_reference(Resident),
    {Pending, {1, ok, {observe, time, Token}}} = session(Resident, step, Event),
    {Updated, {1, ok, {done}}} = session(Pending, resume, {Token, {ok, 123}}),
    {_, {1, ok, Next}} = session(Updated, export, nil),
    #{async_tool_calls := #{<<"a">> := #{<<"updated_at">> := 123,
        <<"progress">> := #{<<"percent">> := 50}}}} = Next,
    Complete = #{<<"type">> => <<"async_tool_call_completed">>, <<"tool_call_id">> => <<"a">>},
    {Completed, {1, ok, {done}}} = session(Updated, step, Complete),
    {_, {1, ok, Settled}} = session(Completed, export, nil),
    #{async_tool_calls := Empty, last_seq := 1, async_result_refs := #{<<"a">> := 1}} = Settled,
    0 = map_size(Empty),
    {Ignored, {1, ok, {done}}} = session(Completed, step, Event),
    {_, {1, ok, Settled}} = session(Ignored, export, nil),
    ifc_smoke(),
    {1, ok, pause} = invoke({1, agent_loop, 1, activation, {true, false, false}}),
    Ref = term_to_binary(make_ref()),
    {1, ok, {{retained, Ref}, accept_result}} =
        invoke({1, agent_loop, 1, dependency_step, {{running, Ref}, {Ref, result}}}),
    {1, ok, ignore} = invoke({1, agent_loop, 1, retry_admission, {invalid, 0}}),
    io:format("Static Lean NIF: 1600 calls, Session, IFC and AgentLoop passed without Lean.~n").

ifc_smoke() ->
    Label = #{'__struct__' => 'Elixir.SalixIFC.Label', atoms => set([public])},
    Request = #{'__struct__' => 'Elixir.SalixIFC.Item', ref => <<"r">>,
        label => Label, integrity => command, principal => system},
    Effect = #{'__struct__' => 'Elixir.SalixIFC.Effect', destination => Label,
        request => <<"r">>, writers => any, sources => context},
    Activation = #{'__struct__' => 'Elixir.SalixIFC.Activation', requester => system,
        source_scope => Label, consumed_refs => set([<<"r">>])},
    Policy = #{'__struct__' => 'Elixir.SalixIFC.Policy', declassification => none,
        external_principals => deny, public_egress => deny, sealed_atoms => set([])},
    Facts = #{'__struct__' => 'Elixir.SalixIFC.Facts', policy => Policy,
        scopes => #{}, membership => #{}, placements => #{}, receipts => set([]), now => 0},
    {1, ok, {ok, {allow, _}}} = invoke({1, ifc, 1, decide, {Effect, Activation, [Request], Facts}}),
    {1, ok, {ok, {deny, #{clause := request_not_command}}}} =
        invoke({1, ifc, 1, decide, {Effect, Activation, [Request#{integrity := data}], Facts}}).

set(Values) -> #{'__struct__' => 'Elixir.MapSet', map => maps:from_list([{V, []} || V <- Values])}.

invoke(Request) ->
    Bytes = 'Elixir.SalixVerifiedKernel.Native':invoke_etf(term_to_binary(Request)),
    binary_to_term(Bytes, [safe]).

session(Resident, Operation, Payload) ->
    {Next, Bytes} = 'Elixir.SalixVerifiedKernel.Native':session(
        Resident, term_to_binary({1, session, 1, Operation, Payload})),
    {Next, binary_to_term(Bytes, [safe])}.
