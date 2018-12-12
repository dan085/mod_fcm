%% Google Cloud Messaging for Ejabberd
%% Created: 02/08/2018 by Dverdugo
%% License: MIT/X11

-module(mod_fcm).


-include("ejabberd.hrl").
-include("logger.hrl").
-include("jlib.hrl").

-behaviour(gen_mod).

-record(fcm_users, {user, fcm_key, last_seen}).


-define(NS_FCM, "https://fcm.googleapis.com/fcm"). %% I hope Google doesn't mind.
-define(FCM_URL, ?NS_FCM ++ "/send").
-define(CONTENT_TYPE, "application/x-www-form-urlencoded;charset=UTF-8").


-export([start/2, stop/1, message/3, iq/3, mod_opt_type/1, depends/2]).

%% http://stackoverflow.com/questions/114196/url-encode-in-erlang
-spec(url_encode(string()) -> string()).

escape_uri(S) when is_list(S) ->
    escape_uri(unicode:characters_to_binary(S));
escape_uri(<<C:8, Cs/binary>>) when C >= $a, C =< $z ->
    [C] ++ escape_uri(Cs);
escape_uri(<<C:8, Cs/binary>>) when C >= $A, C =< $Z ->
    [C] ++ escape_uri(Cs);
escape_uri(<<C:8, Cs/binary>>) when C >= $0, C =< $9 ->
    [C] ++ escape_uri(Cs);
escape_uri(<<C:8, Cs/binary>>) when C == $. ->
    [C] ++ escape_uri(Cs);
escape_uri(<<C:8, Cs/binary>>) when C == $- ->
    [C] ++ escape_uri(Cs);
escape_uri(<<C:8, Cs/binary>>) when C == $_ ->
    [C] ++ escape_uri(Cs);
escape_uri(<<C:8, Cs/binary>>) ->
    escape_byte(C) ++ escape_uri(Cs);
escape_uri(<<>>) ->
    "".

escape_byte(C) ->
    "%" ++ hex_octet(C).

hex_octet(N) when N =< 9 ->
    [$0 + N];
hex_octet(N) when N > 15 ->
    hex_octet(N bsr 4) ++ hex_octet(N band 15);
hex_octet(N) ->
    [N - 10 + $a].


url_encode(Data) ->
    url_encode(Data,"").

url_encode([],Acc) ->
    Acc;
url_encode([{Key,Value}|R],"") ->
    url_encode(R, escape_uri(Key) ++ "=" ++ escape_uri(Value));
url_encode([{Key,Value}|R],Acc) ->
    url_encode(R, Acc ++ "&" ++ escape_uri(Key) ++ "=" ++ escape_uri(Value)).


%% Send an HTTP request to Google APIs and handle the response
send([{Key, Value}|R], API_KEY) ->
	Header = [{"Authorization", url_encode([{"key", API_KEY}])}],
	Body = url_encode([{Key, Value}|R]),
	{ok, RawResponse} = httpc:request(post, {?FCM_URL, Header, ?CONTENT_TYPE, Body}, [], []),
	%% {{"HTTP/1.1",200,"OK"} ..}
	{{_, SCode, Status}, ResponseBody} = {element(1, RawResponse), element(3, RawResponse)},
	%% TODO: Errors 5xx
	case SCode of
		200 -> ?DEBUG("mod_fcm: t(he message was sent", []);
		401 -> ?ERROR_MSG("mod_fcm: error! Code ~B (~s)", [SCode, Status]);
		_ -> ?ERROR_MSG("mod_fcm: error! Code ~B (~s), response: \"~s\"", [SCode, Status, ResponseBody])
	end.


%% TODO: Define some kind of a shaper to prevent floods and the FCM API to burn out :/
%% Or this could be the limits, like 10 messages/user, 10 messages/hour, etc
message(From, To, Packet) ->
	Type = fxml:get_tag_attr_s(<<"type">>, Packet),
	?DEBUG("mod_fcm: got offline message", []),
	case catch Type of 
		"normal" -> ok;
		_ ->
			%% Strings
			JFrom = jlib:jid_to_string(From#jid{user = From#jid.user, server = From#jid.server, resource = <<"">>}),
			JTo = jlib:jid_to_string(To#jid{user = To#jid.user, server = To#jid.server, resource = <<"">>}),
			ToUser = To#jid.user,
			ToServer = To#jid.server,
			ServerKey = gen_mod:get_module_opt(ToServer, ?MODULE, fcm_api_key, fun(V) -> V end, undefined),
			Body = fxml:get_path_s(Packet, [{elem, <<"body">>}, cdata]),
			
			case Body of
						<<>> -> ok; %% There is no body
						_ ->
							IQ = {iq,"",get,"vcard-temp","",
							{xmlelement,"vCard",[{"xmlns","vcard-temp"}],[]}},
							IQ_Vcard = mod_vcard:process_sm_iq(To, From, IQ),
							case IQ_Vcard#iq.sub_el of
								[] -> "";
								[Vcard] -> 
									case fxml:get_path_s(Vcard, [{elem, <<"NICKNAME">>}, cdata]) of
									<<"">> -> 
										Nickname = fxml:get_path_s(Vcard, [{elem, <<"NICKNAME">>}, cdata]),
										Subject = fxml:get_path_s(Packet, [{elem, <<"subject">>}, cdata]),
										case Subject of
											<<"0">> -> 
												Body_ = fxml:get_path_s(Packet, [{elem, <<"body">>}, cdata]), %% There is no body
												Body_subj = fxml:get_path_s(Packet, [{elem, <<"subject">>}, cdata]),
												Result = mnesia:dirty_read(fcm_users, {ToUser, ToServer}),
												case Result of 
													[] -> ?DEBUG("mod_fcm: No such record found for ~s", [JTo]);
													[#fcm_users{fcm_key = API_KEY}] ->
														?DEBUG("mod_fcm: sending the message to FCM for user ~s", [JTo]),
														Args = [{"registration_id", API_KEY}, {"priority", "high"}, {"data.message", Body_}, {"data.source", JFrom}, {"data.destination", JFrom}, {"data.subject", Body_subj}],
											 			if ServerKey /=
															undefined -> send(Args, ServerKey);
															true ->
																?ERROR_MSG("mod_fcm: fcm_api_key is undefined!", []),
																ok
														end
												end;	  	  	  	  	  	  	  
											_ ->
												Body_sub = fxml:get_path_s(Packet, [{elem, <<"subject">>}, cdata]),
												Result = mnesia:dirty_read(fcm_users, {ToUser, ToServer}),
												case Result of 
													[] -> ?DEBUG("mod_fcm: No such record found for ~s", [JTo]);
													[#fcm_users{fcm_key = API_KEY}] ->
														?DEBUG("mod_fcm: sending the message to FCM for user ~s", [JTo]),
														Args = [{"registration_id", API_KEY}, {"priority", "high"}, {"data.message", Body_sub}, {"data.source", JFrom}, {"data.destination", JFrom}, {"data.subject", Body_sub}],
														if ServerKey /=
															undefined -> send(Args, ServerKey);
															true ->
																?ERROR_MSG("mod_fcm: fcm_api_key is undefined!", []),
																ok
														end
												end
										end;
									_ -> 
										Nickname = fxml:get_path_s(Vcard, [{elem, <<"NICKNAME">>}, cdata]),
										Subject = fxml:get_path_s(Packet, [{elem, <<"subject">>}, cdata]),
										case Subject of
											<<"0">> ->
												Body_sub_ = fxml:get_path_s(Packet, [{elem, <<"subject">>}, cdata]), 
												Body_ = fxml:get_path_s(Packet, [{elem, <<"body">>}, cdata]), %% There is no body
												Result = mnesia:dirty_read(fcm_users, {ToUser, ToServer}),
												case Result of 
													[] -> ?DEBUG("mod_fcm: No such record found for ~s", [JTo]);
													[#fcm_users{fcm_key = API_KEY}] ->
														?DEBUG("mod_fcm: sending the message to FCM for user ~s", [JTo]),
														Args = [{"registration_id", API_KEY}, {"priority", "high"}, {"data.message", Body_}, {"data.source", JFrom}, {"data.destination", Nickname}, {"data.subject", Body_sub_}],
														if ServerKey /=
															undefined -> send(Args, ServerKey);
															true ->
																?ERROR_MSG("mod_fcm: fcm_api_key is undefined!", []),
																ok
														end
												end;	  	  	  	  	  	  	  
											_ ->
												Body_sub = fxml:get_path_s(Packet, [{elem, <<"subject">>}, cdata]),
												Result = mnesia:dirty_read(fcm_users, {ToUser, ToServer}),
												case Result of 
													[] -> ?DEBUG("mod_fcm: No such record found for ~s", [JTo]);
													[#fcm_users{fcm_key = API_KEY}] ->
														?DEBUG("mod_fcm: sending the message to FCM for user ~s", [JTo]),
														Args = [{"registration_id", API_KEY}, {"priority", "high"}, {"data.message", Body_sub}, {"data.source", JFrom}, {"data.destination", Nickname}, {"data.subject", Body_sub}],
														if ServerKey /=
															undefined -> send(Args, ServerKey);
															true ->
																?ERROR_MSG("mod_fcm: fcm_api_key is undefined!", []),
																ok
														end
												end
										end
									end
							end				
						end			
	end.


iq(#jid{user = User, server = Server}, _To, #iq{sub_el = SubEl} = IQ) ->
	LUser = jlib:nodeprep(User),
	LServer = jlib:nameprep(Server),

	{MegaSecs, Secs, _MicroSecs} = now(),
	TimeStamp = MegaSecs * 1000000 + Secs,

	API_KEY = fxml:get_tag_cdata(fxml:get_subtag(SubEl, <<"key">>)),

	F = fun() -> mnesia:write(#fcm_users{user={LUser, LServer}, fcm_key=API_KEY, last_seen=TimeStamp}) end,

	case mnesia:dirty_read(fcm_users, {LUser, LServer}) of
		[] ->
			mnesia:transaction(F),
			?DEBUG("mod_fcm: new user registered ~s@~s", [LUser, LServer]);

		%% Record exists, the key is equal to the one we know
		[#fcm_users{user={LUser, LServer}, fcm_key=API_KEY}] ->
			mnesia:transaction(F),
			?DEBUG("mod_fcm: updating last_seen for user ~s@~s", [LUser, LServer]);

		%% Record for this key was found, but for another key
		[#fcm_users{user={LUser, LServer}, fcm_key=_KEY}] ->
			mnesia:transaction(F),
			?DEBUG("mod_fcm: updating fcm_key for user ~s@~s", [LUser, LServer])
		end,
	
	IQ#iq{type=result, sub_el=[]}. %% We don't need the result, but the handler have to send something.


start(Host, _Opts) -> 
	ssl:start(),
	application:start(inets),
	mnesia:create_table(fcm_users, [{disc_copies, [node()]}, {attributes, record_info(fields, fcm_users)}]),
	gen_iq_handler:add_iq_handler(ejabberd_local, Host, <<?NS_FCM>>, ?MODULE, iq, no_queue),
	ejabberd_hooks:add(offline_message_hook, Host, ?MODULE, message, 49),
	?INFO_MSG("mod_fcm has started successfully!", []),
	ok.


stop(_Host) -> ok.


depends(_Host, _Opts) ->
    [].


mod_opt_type(fcm_api_key) -> fun iolist_to_binary/1. %binary_to_list?

