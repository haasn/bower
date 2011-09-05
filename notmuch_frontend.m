%-----------------------------------------------------------------------------%

:- module notmuch_frontend.
:- interface.

:- import_module io.

:- pred main(io::di, io::uo) is det.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- implementation.

:- import_module char.
:- import_module int.
:- import_module list.
:- import_module maybe.
:- import_module string.
:- import_module time.

:- import_module callout.
:- import_module compose.
:- import_module curs.
:- import_module curs.panel.
:- import_module data.
:- import_module index_view.
:- import_module pager.
:- import_module recall.
:- import_module screen.
:- import_module text_entry.
:- import_module thread_pager.

%-----------------------------------------------------------------------------%

:- pragma foreign_decl("C", local,
"
    #include <locale.h>
").

%-----------------------------------------------------------------------------%

main(!IO) :-
    setlocale(!IO),
    io.command_line_arguments(Args, !IO),
    Terms = Args,
    curs.start(!IO),
    create_screen(Screen, !IO),
    (
        Terms = [],
        open_index(Screen, [], !IO)
    ;
        Terms = [_ | _],
        search_and_open_index(Screen, Terms, !IO)
    ),
    curs.stop(!IO).

:- pred setlocale(io::di, io::uo) is det.

:- pragma foreign_proc("C",
    setlocale(IO0::di, IO::uo),
    [will_not_call_mercury, promise_pure, thread_safe, tabled_for_io,
        may_not_duplicate],
"
    setlocale(LC_ALL, """");
    IO = IO0;
").

%-----------------------------------------------------------------------------%

:- pred search_and_open_index(screen::in, list(string)::in, io::di, io::uo)
    is det.

search_and_open_index(Screen, Terms, !IO) :-
    update_message(Screen, set_info("Searching..."), !IO),
    panel.update_panels(!IO),
    run_notmuch(["search", "--format=json" | Terms], parse_threads_list,
        Threads, !IO),
    string.format("Found %d threads.", [i(length(Threads))], Message),
    update_message(Screen, set_info(Message), !IO),
    open_index(Screen, Threads, !IO).

:- pred open_index(screen::in, list(thread)::in, io::di, io::uo) is det.

open_index(Screen, Threads, !IO) :-
    setup_index_view(Threads, IndexInfo, !IO),
    index_loop(Screen, IndexInfo, !IO).

:- pred index_loop(screen::in, index_info::in, io::di, io::uo) is det.

index_loop(Screen, !.IndexInfo, !IO) :-
    draw_index_view(Screen, !.IndexInfo, !IO),
    draw_bar(Screen, !IO),
    panel.update_panels(!IO),
    get_char(Char, !IO),
    index_view_input(Screen, Char, MessageUpdate, Action, !IndexInfo),
    update_message(Screen, MessageUpdate, !IO),
    (
        Action = continue,
        index_loop(Screen, !.IndexInfo, !IO)
    ;
        Action = open_pager(ThreadId),
        open_thread_pager(Screen, ThreadId, !IO),
        index_loop(Screen, !.IndexInfo, !IO)
    ;
        Action = enter_limit,
        text_entry(Screen, "Limit to messages matching: ", Return, !IO),
        (
            Return = yes(String),
            search_and_open_index(Screen, [String], !IO)
        ;
            Return = no,
            update_message(Screen, clear_message, !IO),
            index_loop(Screen, !.IndexInfo, !IO)
        )
    ;
        Action = start_compose,
        start_compose(Screen, !IO),
        index_loop(Screen, !.IndexInfo, !IO)
    ;
        Action = start_recall,
        select_recall(Screen, MaybeFileName, !IO),
        (
            MaybeFileName = yes(FileName),
            continue_postponed(Screen, FileName, !IO)
        ;
            MaybeFileName = no
        ),
        index_loop(Screen, !.IndexInfo, !IO)
    ;
        Action = quit
    ).

%-----------------------------------------------------------------------------%

:- pred open_thread_pager(screen::in, thread_id::in, io::di, io::uo) is det.

open_thread_pager(Screen, ThreadId, !IO) :-
    run_notmuch(["show", "--format=json", thread_id_to_search_term(ThreadId)],
        parse_messages_list, Messages : list(message), !IO),
    time(Time, !IO),
    Nowish = localtime(Time),
    Rows = Screen ^ rows,
    Cols = Screen ^ cols,
    setup_thread_pager(Nowish, Rows - 2, Cols, Messages, ThreadPagerInfo, Count),
    string.format("Showing message 1 of %d.", [i(Count)], Msg),
    update_message(Screen, set_info(Msg), !IO),
    thread_pager_loop(Screen, ThreadPagerInfo, !IO).

:- pred thread_pager_loop(screen::in, thread_pager_info::in, io::di, io::uo)
    is det.

thread_pager_loop(Screen, !.Info, !IO) :-
    draw_thread_pager(Screen, !.Info, !IO),
    draw_bar(Screen, !IO),
    panel.update_panels(!IO),
    get_char(Char, !IO),
    thread_pager_input(Char, Action, MessageUpdate, !Info),
    update_message(Screen, MessageUpdate, !IO),
    (
        Action = continue,
        thread_pager_loop(Screen, !.Info, !IO)
    ;
        Action = start_reply(Message, ReplyKind),
        start_reply(Screen, Message, ReplyKind, !IO),
        thread_pager_loop(Screen, !.Info, !IO)
    ;
        Action = leave(ReadMessages, UnreadMessages),
        tag_as_read_unread(Screen, ReadMessages, UnreadMessages, !IO)
    ).

:- pred tag_as_read_unread(screen::in,
    list(message_id)::in, list(message_id)::in, io::di, io::uo) is det.

tag_as_read_unread(Screen, ReadMessages, UnreadMessages, !IO) :-
    tag_messages("-unread", ReadMessages, ResA, !IO),
    tag_messages("+unread", UnreadMessages, ResB, !IO),
    ( ResA = error(Error) ->
        Msg = io.error_message(Error),
        update_message(Screen, set_warning(Msg), !IO)
    ; ResB = error(Error) ->
        Msg = io.error_message(Error),
        update_message(Screen, set_warning(Msg), !IO)
    ;
        update_message(Screen, clear_message, !IO)
    ).

:- pred tag_messages(string::in, list(message_id)::in, io.res::out,
    io::di, io::uo) is det.

tag_messages(TagUpdate, MessageIds, Res, !IO) :-
    (
        MessageIds = [],
        Res = ok
    ;
        MessageIds = [_ | _],
        IdStrings = list.map(message_id_to_search_term, MessageIds),
        Args = ["notmuch", "tag", TagUpdate, "--" | IdStrings],
        args_to_quoted_command(Args, Command),
        io.call_system(Command, CallRes, !IO),
        (
            CallRes = ok(ExitStatus),
            ( ExitStatus = 0 ->
                Res = ok
            ;
                string.format("notmuch tag returned exit status %d",
                    [i(ExitStatus)], Msg),
                Res = error(io.make_io_error(Msg))
            )
        ;
            CallRes = error(Error),
            Res = error(Error)
        )
    ).

:- import_module quote_arg.

%-----------------------------------------------------------------------------%

:- pred open_pager(screen::in, thread_id::in, io::di, io::uo) is det.

open_pager(Screen, ThreadId, !IO) :-
    run_notmuch(["show", "--format=json", thread_id_to_search_term(ThreadId)],
        parse_messages_list, Messages : list(message), !IO),
    Cols = Screen ^ cols,
    setup_pager(Cols, Messages, PagerInfo),
    pager_loop(Screen, PagerInfo, !IO).

:- pred pager_loop(screen::in, pager_info::in, io::di, io::uo)
    is det.

pager_loop(Screen, !.PagerInfo, !IO) :-
    draw_pager(Screen, !.PagerInfo, !IO),
    draw_bar(Screen, !IO),
    panel.update_panels(!IO),
    get_char(Char, !IO),
    pager_input(Screen, Char, Action, MessageUpdate, !PagerInfo),
    update_message(Screen, MessageUpdate, !IO),
    (
        Action = continue,
        pager_loop(Screen, !.PagerInfo, !IO)
    ;
        Action = leave_pager
    ).

%-----------------------------------------------------------------------------%

:- pred draw_bar(screen::in, io::di, io::uo) is det.

draw_bar(Screen, !IO) :-
    Cols = Screen ^ cols,
    Panel = Screen ^ bar_panel,
    panel.erase(Panel, !IO),
    panel.attr_set(Panel, fg_bg(white, blue), !IO),
    hline(Panel, char.to_int('-'), Cols, !IO).

%-----------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sts=4 sw=4 et
