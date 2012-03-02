% Bower - a frontend for the Notmuch email system
% Copyright (C) 2011 Peter Wang

:- module string_util.
:- interface.

:- import_module char.

:- func wcwidth(char) = int.

:- func string_wcwidth(string) = int.

:- pred strcase_equal(string::in, string::in) is semidet.

:- pred strcase_str(string::in, string::in) is semidet.

:- pred strrchr(string::in, char::in, int::out) is semidet.

:- pred unsafe_strstr(string::in, string::in, int::in, int::out) is semidet.

:- type pieces
    --->    empty
    ;       literal(string, pieces)
    ;       substring(string, int, int, pieces). % base, start, end

:- pred string_from_rev_pieces(pieces::in, string::out) is det.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- implementation.

:- import_module int.
:- import_module require.
:- import_module string.

%-----------------------------------------------------------------------------%

:- pragma foreign_decl("C", local,
"
    #include <wchar.h>
").

:- pragma foreign_proc("C",
    wcwidth(C::in) = (Width::out),
    [will_not_call_mercury, promise_pure, thread_safe, may_not_duplicate],
"
    Width = (C < 256) ? 1 : wcwidth(C);
").

string_wcwidth(S) = Width :-
    string.foldl(string_wcwidth_2, S, 0, Width).

:- pred string_wcwidth_2(char::in, int::in, int::out) is det.

string_wcwidth_2(C, Width, Width + wcwidth(C)).

%-----------------------------------------------------------------------------%

:- pragma foreign_proc("C",
    strcase_equal(SA::in, SB::in),
    [will_not_call_mercury, promise_pure, thread_safe, may_not_duplicate],
"
    SUCCESS_INDICATOR = (strcasecmp(SA, SB) == 0);
").

:- pragma foreign_proc("C",
    strcase_str(SA::in, SB::in),
    [will_not_call_mercury, promise_pure, thread_safe, may_not_duplicate],
"
    SUCCESS_INDICATOR = (strcasestr(SA, SB) != 0);
").

:- pragma foreign_proc("C",
    strrchr(S::in, C::in, I::out),
    [will_not_call_mercury, promise_pure, thread_safe, may_not_duplicate],
"
    const char *p;

    p = strrchr(S, C);
    if (p != NULL) {
        SUCCESS_INDICATOR = MR_TRUE;
        I = (p - S);
    } else {
        SUCCESS_INDICATOR = MR_FALSE;
        I = -1;
    }
").

:- pragma foreign_proc("C",
    unsafe_strstr(Haystack::in, Needle::in, BeginAt::in, Index::out),
    [will_not_call_mercury, promise_pure, thread_safe, may_not_duplicate],
"
    const char *p;

    p = strstr(Haystack + BeginAt, Needle);
    if (p != NULL) {
        SUCCESS_INDICATOR = MR_TRUE;
        Index = (p - Haystack);
    } else {
        SUCCESS_INDICATOR = MR_FALSE;
        Index = -1;
    }
").

%-----------------------------------------------------------------------------%

string_from_rev_pieces(Pieces, String) :-
    pieces_length(Pieces, 0, Length),
    allocate_string(Length, String0),
    copy_rev_pieces(Pieces, Length, String0, String).

:- pred pieces_length(pieces::in, int::in, int::out) is det.

pieces_length(Pieces, Length0, Length) :-
    (
        Pieces = empty,
        Length = Length0
    ;
        Pieces = literal(Literal, Rest),
        string.length(Literal, PieceLength),
        pieces_length(Rest, Length0 + PieceLength, Length)
    ;
        Pieces = substring(_BaseString, Start, End, Rest),
        % We trust that PieceLength =< length(BaseString).
        PieceLength = End - Start,
        expect(PieceLength >= 0, $module, $pred,
            "substring has negative length"),
        pieces_length(Rest, Length0 + PieceLength, Length)
    ).

:- pred allocate_string(int::in, string::uo) is det.

:- pragma foreign_proc("C",
    allocate_string(Length::in, String::uo),
    [will_not_call_mercury, promise_pure, thread_safe, tabled_for_io],
"
    MR_allocate_aligned_string_msg(String, Length, MR_ALLOC_ID);
    String[Length] = '\\0';
").

:- pred copy_rev_pieces(pieces::in, int::in, string::di, string::uo) is det.

copy_rev_pieces(Pieces, EndPos, !String) :-
    (
        Pieces = empty,
        expect(unify(EndPos, 0), $module, $pred, "EndPos != 0")
    ;
        Pieces = literal(Literal, RestPieces),
        PieceLength = length(Literal),
        StartPos = EndPos - PieceLength,
        expect(StartPos >= 0, $module, $pred, "StartPos < 0"),
        do_copy(Literal, 0, PieceLength, StartPos, !String),
        copy_rev_pieces(RestPieces, StartPos, !String)
    ;
        Pieces = substring(BaseString, BaseStart, BaseEnd, RestPieces),
        PieceLength = BaseEnd - BaseStart,
        StartPos = EndPos - PieceLength,
        expect(StartPos >= 0, $module, $pred, "StartPos < 0"),
        do_copy(BaseString, BaseStart, PieceLength, StartPos, !String),
        copy_rev_pieces(RestPieces, StartPos, !String)
    ).

:- pred do_copy(string::in, int::in, int::in,
    int::in, string::di, string::uo) is det.

:- pragma foreign_proc("C",
    do_copy(Src::in, SrcStart::in, SrcLength::in,
        DestStart::in, Dest0::di, Dest::uo),
    [will_not_call_mercury, promise_pure, thread_safe],
"
    memcpy(Dest0 + DestStart, Src + SrcStart, SrcLength);
    Dest = Dest0;
").

%-----------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sts=4 sw=4 et
