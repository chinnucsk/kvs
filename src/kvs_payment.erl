-module(kvs_payment).
-include_lib("kvs/include/membership.hrl").
-include_lib("kvs/include/payments.hrl").
-include_lib("kvs/include/accounts.hrl").
-include_lib("kvs/include/feed_state.hrl").
-compile(export_all).

payments(UserId) -> payments(UserId, undefined).
payments(UserId, PageAmount) ->
    case kvs:get(user_payment, UserId) of
        {ok, O} -> kvs:entries(O, payment, PageAmount);
        {error, _} -> [] end.
payments(UserId, StartFrom, Limit) ->
    case kvs:get(payment, StartFrom) of
        {ok, P} ->  kvs:traversal(payment, P, Limit);
        X -> [] end.

user_paid(UId) ->
    case kvs:get(user_payment, UId) of
        {error,_} -> false;
        {ok,#user_payment{top = undefined}} -> false;
        _ -> true end.

default_if_undefined(Value, Undefined, Default) ->
    case Value of
        Undefined -> Default;
        _ -> Value end.

charge_user_account(_MP) -> ok.
%    OrderId = MP#payment.id,
%    Package = MP#payment.membership,
%    UserId  = MP#payment.user_id,
%
%    Currency = Package#membership.currency,
%    Quota    = Package#membership.quota,
%
%    PaymentTransactionInfo = #tx_payment{id=MP#payment.id},
%
%    try
%        kvs_account:transaction(UserId, currency, Currency, PaymentTransactionInfo),
%        kvs_account:transaction(UserId, quota,    Quota,    PaymentTransactionInfo)
%    catch
%        _:E ->
%            error_logger:info_msg("unable to charge user account. User=~p, OrderId=~p. Error: ~p",
%                   [UserId, OrderId, E])
%    end.

add_payment(#payment{} = MP) -> add_payment(#payment{} = MP, undefined, undefined).
add_payment(#payment{} = MP, State0, Info) ->
    error_logger:info_msg("ADD PAYMENT"),
    Start = now(),
    State = default_if_undefined(State0, undefined, ?MP_STATE_ADDED),
    StateLog = case Info of
        undefined -> [#state_change{time = Start, state = State, info = system_change}];
        _ -> [#state_change{time = Start, state = State, info = Info}] end,

    Id = default_if_undefined(MP#payment.id, undefined, payment_id()),
    kvs:add(MP#payment{id = Id, state = State, start_time = Start, state_log = StateLog, feed_id=MP#payment.user_id}).

set_payment_state(MPId, NewState, Info) ->
    case kvs:get(payment, MPId) of 
      {ok, MP} ->

    Time = now(),
    StateLog = MP#payment.state_log,
    NewStateLog = [#state_change{time = Time, state = NewState, info = Info}|StateLog],
    EndTime = case NewState of
                  ?MP_STATE_DONE -> now();
                  ?MP_STATE_CANCELLED -> now();
                  ?MP_STATE_FAILED -> now();
                  _ -> MP#payment.end_time
              end,
    Purchase = MP#payment{state = NewState, end_time = EndTime, state_log = NewStateLog},

    mqs:notify([kvs_payment,user,Purchase#payment.user_id,notify],Purchase),

    NewMP=MP#payment{state = NewState, end_time = EndTime, state_log = NewStateLog},
    kvs:put(NewMP),

    if
        NewState == ?MP_STATE_DONE -> charge_user_account(MP); % affiliates:purchase_hook(NewMP);
        true -> ok
    end,

    ok;

    Error -> error_logger:info_msg("Can't set purchase state, not yet in db"), Error
    end.

set_payment_info(MPId, Info) ->
    {ok, MP} = kvs:get(payment, MPId),
    kvs:put(MP#payment{info = Info}).

set_payment_external_id(MPId, ExternalId) ->
    {ok, MP} = kvs:get(payment, MPId),
    case MP#payment.external_id of
        ExternalId -> ok;
        _ -> kvs:put(MP#payment{external_id = ExternalId}) end.

list_payments() -> kvs:all(payment).

list_payments(SelectOptions) ->
    Predicate = fun(MP = #payment{}) -> kvs_membership:check_conditions(SelectOptions, MP, true) end,
    kvs_membership:select(payment, Predicate).

payment_id() ->
    NextId = kvs:next_id("payment"),
    lists:concat([timestamp(), "_", NextId]).

handle_notice([kvs_payment, user, Owner, set_state] = Route,
    Message, #state{owner = Owner, type =Type} = State) ->
    error_logger:info_msg("queue_action(~p): set_purchase_state: Owner=~p, Route=~p, Message=~p", [self(), {Type, Owner}, Route, Message]),  
    {MPId, NewState, Info} = Message,
    set_payment_state(MPId, NewState, Info),
    {noreply, State};

handle_notice([kvs_payment, user, Owner, add] = Route,
    Message, #state{owner = Owner, type =Type} = State) ->
    error_logger:info_msg("queue_action(~p): add_purchase: Owner=~p, Route=~p, Message=~p", [self(), {Type, Owner}, Route, Message]),    
    {MP} = Message,
    error_logger:info_msg("Add payment: ~p", [MP]),
    add_payment(MP),
    {noreply, State};

handle_notice(["kvs_payment", "user", _, "set_external_id"] = Route,
    Message, #state{owner = Owner, type =Type} = State) ->
    error_logger:info_msg("queue_action(~p): set_purchase_external_id: Owner=~p, Route=~p, Message=~p", [self(), {Type, Owner}, Route, Message]),
    {PurchaseId, TxnId} = Message,
    set_payment_external_id(PurchaseId, TxnId),
    {noreply, State};

handle_notice(["kvs_payment", "user", _, "set_info"] = Route,
    Message, #state{owner = Owner, type =Type} = State) ->
    error_logger:info_msg("queue_action(~p): set_purchase_info: Owner=~p, Route=~p, Message=~p", [self(), {Type, Owner}, Route, Message]),
    {OrderId, Info} = Message,
    set_payment_info(OrderId, Info),
    {noreply, State};

handle_notice(Route, _, State) -> 
    %error_logger:info_msg("Unknown PAYMENTS notice ~p for: ~p, ~p", [Route, State#state.owner, State#state.type]), 
    {noreply, State}.

timestamp()->
  {Y, Mn, D} = erlang:date(),
  {H, M, S} = erlang:time(),
  lists:flatten(io_lib:format("~b~2..0b~2..0b_~2..0b~2..0b~2..0b", [Y, Mn, D, H, M, S])).
