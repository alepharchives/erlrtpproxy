%%%----------------------------------------------------------------------
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 3 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License
%%% along with this program; if not, write to the Free Software
%%% Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
%%% 02111-1307 USA
%%%
%%%----------------------------------------------------------------------

-module(ser).
-author('lemenkov@gmail.com').

-behaviour(gen_server).
-export([start/1]).
-export([start_link/1]).
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([code_change/3]).
-export([terminate/2]).

-include("common.hrl").

start(Args) ->
	gen_server:start(?MODULE, Args, []).

start_link(Args) ->
	gen_server:start_link(?MODULE, Args, []).

init ({Ip, Port}) ->
	process_flag(trap_exit, true),
	case gen_udp:open(Port, [{ip, Ip}, {active, true}, list]) of
		{ok, Fd} ->
			print("ser[~w] started at [~s:~w]~n", [self(), inet_parse:ntoa(Ip), Port]),
			{ok, Fd};
		{error, Reason} ->
			print("ser not started. Reason [~p]~n", Reason),
			{stop, Reason}
	end.

handle_call(_Other, _From, Fd) ->
	{noreply, Fd}.

handle_cast(_Request, Fd) ->
	{noreply, Fd}.

code_change(_OldVsn, Fd, _Extra) ->
	{ok, Fd}.

terminate(Reason, Fd) ->
	gen_udp:close(Fd),
	gen_server:cast({global, rtpproxy}, {ser_cmd_terminated, self(), Reason}),
	print("::: ser[~w] thread terminated due to reason [~p]~n", [self(), Reason]).

% Fd from which message arrived must be equal to Fd from our state
% Brief introbuction of protocol is here: http://rtpproxy.org/wiki/RTPproxyProtocol
handle_info({udp, Fd, Ip, Port, Msg}, Fd) ->
	% TODO fix issue with missing Cookie
	[Cookie|Rest] = string:tokens(Msg, " ;"),
	Answer = case case Rest of
		% Request basic supported rtpproxy protocol version
		["V"] ->
			#cmd{cookie=Cookie, type=?CMD_V};
		% Request additional rtpproxy protocol extensions
		["VF", Params] ->
			#cmd{cookie=Cookie, type=?CMD_VF, params=Params};
		% update/create session
		% TODO OrigPort must be == 0...65535
		[[$U|Args], CallId, OrigIp, OrigPort, FromTag, MediaId] ->
			{Modifiers, _} = lists:unzip(lists:filter(fun({_, Sym}) -> lists:member(Sym, Args) end, ?MOD_LIST)),
			% TODO check addr
			{ok, GuessIp} = inet_parse:address(OrigIp),
			GuessPort = list_to_integer(OrigPort),
			#cmd{cookie=Cookie, type=?CMD_U, callid=CallId, addr={GuessIp, GuessPort}, from={FromTag, list_to_integer(MediaId)}, params=Modifiers};
		% lookup existing session
		% TODO should both MediaIds be equal?
		% TODO OrigPort must be == 0...65535
		[[$L|Args], CallId, OrigIp, OrigPort, FromTag, FromMediaId, ToTag, ToMediaId] ->
			{Modifiers, _} = lists:unzip(lists:filter(fun({_, Sym}) -> lists:member(Sym, Args) end, ?MOD_LIST)),
			% TODO check addr
			{ok, GuessIp} = inet_parse:address(OrigIp),
			GuessPort = list_to_integer(OrigPort),
			#cmd{cookie=Cookie, type=?CMD_L, callid=CallId, addr={GuessIp, GuessPort}, from={FromTag, list_to_integer(FromMediaId)}, to={ToTag, list_to_integer(ToMediaId)}, params=Modifiers};
		% delete session (no MediaIds)
		["D", CallId, FromTag, ToTag] ->
			#cmd{cookie=Cookie, type=?CMD_D, callid=CallId, from={FromTag, 0}, to={ToTag, 0}};
		% record
		["R", CallId, FromTag, FromMediaId, ToTag, ToMediaId] ->
			#cmd{cookie=Cookie, type=?CMD_R, callid=CallId, from={FromTag, list_to_integer(FromMediaId)}, to={ToTag, list_to_integer(ToMediaId)}};
		% playback pre-recorded audio
		["P", CallId, PlayName, Codecs, FromTag, FromMediaId, ToTag, ToMediaId] ->
			#cmd{cookie=Cookie, type=?CMD_P, callid=CallId, from={FromTag, list_to_integer(FromMediaId)}, to={ToTag, list_to_integer(ToMediaId)}, filename=PlayName, codecs=Codecs};
		% stop playback or record
		["S", CallId, FromTag, FromMediaId, ToTag, ToMediaId] ->
			#cmd{cookie=Cookie, type=?CMD_S, callid=CallId, from={FromTag, list_to_integer(FromMediaId)}, to={ToTag, list_to_integer(ToMediaId)}};
		% copy session (same as record?)
		["C", CallId, RecordName, FromTag, FromMediaId, ToTag, ToMediaId] ->
			#cmd{cookie=Cookie, type=?CMD_C, callid=CallId, from={FromTag, list_to_integer(FromMediaId)}, to={ToTag, list_to_integer(ToMediaId)}, filename=RecordName};
		% query
		["Q", CallId, FromTag, FromMediaId, ToTag, ToMediaId] ->
			#cmd{cookie=Cookie, type=?CMD_Q, callid=CallId, from={FromTag, list_to_integer(FromMediaId)}, to={ToTag, list_to_integer(ToMediaId)}};
		% stop all active sessions
		["X"] ->
			#cmd{cookie=Cookie, type=?CMD_X};
		["I"] ->
			#cmd{cookie=Cookie, type=?CMD_I};
		[_Other] ->
			error_syntax
	end of
		error_syntax ->
			print ("ser[~w]: Other command (bad syntax?) [~s]~n", [self(), Msg]),
			?RTPPROXY_ERR_SYNTAX;
		Cmd ->
			gen_server:call({global, rtpproxy}, {message, Cmd})

	end,
	gen_udp:send(Fd, Ip, Port, Cookie ++ " " ++  Answer ++ "\n"),
	{noreply, Fd};

handle_info(Info, Fd) ->
	print("::: ser[~w] Info [~w]~n", [self(), Info]),
	{noreply, Fd}.

print (Format) ->
	print (Format, []).

print (Format, Params) ->
%	io:format(Format, Params),
	syslog:send(ser, syslog:info(), io_lib:format(Format, Params)).
