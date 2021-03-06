%%%----------------------------------------------------------------------
%%% File    : mod_log_rest.erl
%%% Author  : Brendon Crawford <brendon@last.vc>
%%% Purpose : Log 2 ways chat messages to a REST service
%%%----------------------------------------------------------------------

-module(mod_log_rest).
-author('brendon@last.vc').

-behaviour(gen_mod).

-export([start/2,
         init/1,
         stop/1,
         log_packet_send/3,
         log_packet_receive/4,
         async_response/0,
         timestamp/0
]).

%-define(ejabberd_debug, true).

-include("ejabberd.hrl").
-include("jlib.hrl").

-define(PROCNAME, ?MODULE).
-define(DEFAULT_URL, "http://localhost:9091/messages/add").

-record(config, {url=?DEFAULT_URL}).

%%
%% Start
%%
start(Host, Opts) ->
    ?DEBUG(" ~p  ~p~n", [Host, Opts]),
    % Start ibrowse
    ibrowse:start(),
    case gen_mod:get_opt(host_config, Opts, []) of
        [] ->
            start_vh(Host, Opts);
        HostConfig ->
            start_vhs(Host, HostConfig)
    end.

%%
%% Start VHosts
%%
start_vhs(_, []) ->
    ok;
start_vhs(Host, [{Host, Opts}| Tail]) ->
    ?DEBUG("start_vhs ~p  ~p~n", [Host, [{Host, Opts}| Tail]]),
    start_vh(Host, Opts),
    start_vhs(Host, Tail);
start_vhs(Host, [{_VHost, _Opts}| Tail]) ->
    ?DEBUG("start_vhs ~p  ~p~n", [Host, [{_VHost, _Opts}| Tail]]),
    start_vhs(Host, Tail).

%%
%% Start VHost
%%
start_vh(Host, Opts) ->
    Url = gen_mod:get_opt(url, Opts, ?DEFAULT_URL),
    ejabberd_hooks:add(user_send_packet, Host, ?MODULE, log_packet_send, 55),
    ejabberd_hooks:add(user_receive_packet, Host, ?MODULE,
                       log_packet_receive, 55),
    register(gen_mod:get_module_proc(Host, ?PROCNAME),
    spawn(?MODULE, init, [#config{url=Url}])).

%%
%% Init
%%
init(Config)->
    ?DEBUG("Starting ~p with config ~p~n", [?MODULE, Config]),
    loop(Config).

%%
%% Loop
%%
loop(Config) ->
    receive
        {call, Caller, get_config} ->
            Caller ! {config, Config},
            loop(Config);
        stop ->
            exit(normal)
    end.

%%
%% Stop
%%
stop(Host) ->
    % Stop ibrowse
    ibrowse:stop(),
    ejabberd_hooks:delete(user_send_packet, Host,
                          ?MODULE, log_packet_send, 55),
    ejabberd_hooks:delete(user_receive_packet, Host,
                          ?MODULE, log_packet_receive, 55),
    gen_mod:get_module_proc(Host, ?PROCNAME) ! stop,
    ok.

%%
%% Log Packet Send
%%
log_packet_send(From, To, Packet) ->
    log_packet(From, To, Packet, From#jid.lserver).

%%
%% Log Packet Receive
%%
log_packet_receive(_JID, From, To, _Packet)
        when From#jid.lserver == To#jid.lserver->
    ok; % only log at send time if the message is local to the server
log_packet_receive(_JID, From, To, Packet) ->
    log_packet(From, To, Packet, To#jid.lserver).

%%
%% Log Packet
%%
log_packet(From, To, Packet = {xmlelement, "message", Attrs, _Els}, Host) ->
    case xml:get_attr_s("type", Attrs) of
        "groupchat" -> %% mod_muc_log already does it
            ?DEBUG("dropping groupchat: ~s", [xml:element_to_string(Packet)]),
            ok;
        "error" -> %% we don't log errors
            ?DEBUG("dropping error: ~s", [xml:element_to_string(Packet)]),
            ok;
        _ ->
            write_packet(From, To, Packet, Host)
    end;
log_packet(_From, _To, _Packet, _Host) ->
    ok.

%%
%% Write Packet
%%
write_packet(From, To, Packet, Host) ->
    gen_mod:get_module_proc(Host, ?PROCNAME) ! {call, self(), get_config},
    Config =
        receive
            {config, Result} ->
                Result
        end,
    {Subject, Body} = {
        case xml:get_path_s(Packet, [{elem, "subject"}, cdata]) of
            false ->
                "";
            Text ->
                Text
        end,
        xml:get_path_s(Packet, [{elem, "body"}, cdata])
    },
    case Subject ++ Body of
        "" -> %% don't log empty messages
            ?DEBUG("not logging empty message from ~s",
                   [jlib:jid_to_string(From)]),
            ok;
        _ ->
            Timestamp = timestamp(),
            Url = Config#config.url,
            FromJid = From#jid.luser++"@"++From#jid.lserver,
            ToJid = To#jid.luser++"@"++To#jid.lserver,
            send_to_rest(Url, Timestamp, FromJid, ToJid, Subject, Body)
    end.

%%
%% Async response
%%
%% Handles all async responses from iBrowse
%%
async_response() ->
    receive
        {ibrowse_async_headers, ReqId, _, _} ->
            ibrowse:stream_next(ReqId),
            ok;
        {ibrowse_async_response, ReqId, _} ->
            ibrowse:stream_next(ReqId),
            ok;
        {ibrowse_async_response_end, ReqId} ->
            ibrowse:stream_close(ReqId),
            ok;
        _ ->
            ok
    end.

%%
%% Send to rest
%%
send_to_rest(Url, Timestamp, FromJid, ToJid, Subject, Body) ->
    Res = spawn(?MODULE, async_response, []),
    Params = mochiweb_util:urlencode([{body, Body},
                                      {from_jid, FromJid},
                                      {to_jid, ToJid},
                                      {subject, Subject},
                                      {timestamp, Timestamp}]),
    ?DEBUG("Args ~p~n", [Params]),
    ibrowse:send_req(Url,
                     [{"Content-Type","application/x-www-form-urlencoded"}],
                     post, 
                     Params,
                     [{stream_to, Res}]),
    ok.

%%
%% Get a timestamp
%%
timestamp() ->
    Fmt = "~4.10.0B-~2.10.0B-~2.10.0BT~2.10.0B:~2.10.0B:~2.10.0BZ",
    {{Year, Month, Day}, {Hour, Min, Sec}} = calendar:universal_time(),
    Date = iolist_to_binary(io_lib:format(Fmt,
                                          [Year, Month, Day, Hour, Min, Sec])),
    Date.


