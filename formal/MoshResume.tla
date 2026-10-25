--------------------------- MODULE MoshResume ---------------------------
EXTENDS Naturals, FiniteSets, TLC

CONSTANTS MaxState, MaxSends, MaxRestores, FaultBudget,
          AllowStaleKill, ConsumeCheckpoint, KeepBoundary,
          \* TRUE: wall-clock micros on restore exceed every earlier nonce
          \* (resumed_sequence's no-rollback assumption). FALSE: only the saved
          \* next nonce protects restore, which is what the main check proves.
          WallAhead
VARIABLE x
vars == <<x>>
Min(s) == CHOOSE n \in s : \A m \in s : n <= m
Max(s) == CHOOSE n \in s : \A m \in s : n >= m
Ack(sent, ack) == IF ack \in sent THEN {n \in sent : n >= ack} ELSE sent
Retain(states, throwaway, boundary) ==
    {n \in states : IF boundary THEN n >= throwaway ELSE n > throwaway}
Apply(states, p, boundary) ==
    IF p.new \notin states /\ p.old \in states /\ p.new > p.old
    THEN Retain(states, p.throwaway, boundary) \cup {p.new} ELSE states
\* Client::receive calls latest_number after retain_from, before inserting new.
\* A broken retention policy can therefore panic before the diff is applied.
ClientWouldPanic(states, p) ==
    p.new \notin states /\ p.old \in states /\ p.new > p.old
    /\ Retain(states, p.throwaway, KeepBoundary) = {}
ClientApply(states, p) ==
    IF ClientWouldPanic(states, p) THEN {} ELSE Apply(states, p, KeepBoundary)
Packet(dir, old, new, ack, throwaway, seq, addr) ==
    [dir |-> dir, old |-> old, new |-> new, ack |-> ack,
     throwaway |-> throwaway, seq |-> seq, addr |-> addr]
Snapshot == [received |-> x.cRecv, sent |-> x.cSent, next |-> x.nextSeq]

Init == x = [
    cSent |-> {0}, cRecv |-> {0}, sSent |-> {0}, sRecv |-> {0},
    nextSeq |-> 1, expected |-> 1, used |-> {}, nonceSafe |-> TRUE,
    addr |-> 0, peer |-> 0, sealed |-> {}, wire |-> {},
    cSends |-> 0, sSends |-> 0, faults |-> 0,
    mode |-> "live", saved |-> [received |-> {0}, sent |-> {0}, next |-> 1],
    disk |-> FALSE, freshSave |-> FALSE, restores |-> 0,
    blob |-> [received |-> {0}, sent |-> {0}, next |-> 1], captured |-> FALSE,
    phase |-> "normal", probe |-> 0,
    applied |-> FALSE, sApplied |-> FALSE, lostCheckpoint |-> FALSE]

\* Each Seal is Client::next_datagram in State::mosh_plan's lock hold.
\* An arbitrary retained reference includes optimistic, expired-to-front,
\* and prospective-resend selection. Recovery below forces timeout fallback.
ClientSeal ==
    /\ x.phase = "normal" /\ x.mode = "live" /\ x.sealed = {}
    /\ x.cSends < MaxSends
    /\ \E old \in x.cSent, new \in {Max(x.cSent), Max(x.cSent) + 1} :
        /\ old < new /\ new <= MaxState
        /\ LET p == Packet("c", old, new, Max(x.cRecv), Min(x.cSent), x.nextSeq, x.addr)
           IN x' = [x EXCEPT !.cSent = @ \cup {new}, !.sealed = {p},
                      !.nonceSafe = @ /\ x.nextSeq \notin x.used,
                      !.used = @ \cup {x.nextSeq}, !.nextSeq = @ + 1,
                      !.cSends = @ + 1]

\* Socket send awaits outside the lock: it may complete AFTER Suspend/Save.
ClientEmit ==
    /\ x.phase = "normal" /\ x.mode # "dead" /\ x.sealed # {}
    /\ Cardinality(x.wire) < 2
    /\ x' = [x EXCEPT !.wire = @ \cup x.sealed, !.sealed = {}]

ServerSend ==
    /\ x.phase = "normal" /\ x.sSends < MaxSends /\ Cardinality(x.wire) < 2
    /\ \E old \in x.sSent, new \in {Max(x.sSent), Max(x.sSent) + 1} :
        /\ old < new /\ new <= MaxState
        /\ LET p == Packet("s", old, new, Max(x.sRecv), Min(x.sSent), 0, x.peer)
           IN x' = [x EXCEPT !.sSent = @ \cup {new}, !.wire = @ \cup {p}, !.sSends = @ + 1]

\* Culling interiors overapproximates the 32-entry queues: the end points
\* are kept; invisible intermediate states can fill the concrete queue.
CullClient ==
    /\ x.phase = "normal" /\ x.mode = "live"
    /\ \E n \in x.cSent \ {Min(x.cSent), Max(x.cSent)} :
        x' = [x EXCEPT !.cSent = @ \ {n}]
CullServer ==
    /\ x.phase = "normal"
    /\ \E n \in x.sSent \ {Min(x.sSent), Max(x.sSent)} :
        x' = [x EXCEPT !.sSent = @ \ {n}]

\* ACK processing precedes duplicate/missing-reference rejection on BOTH ends.
Deliver(p, duplicate) ==
    /\ x.phase = "normal" /\ p \in x.wire
    /\ (~duplicate \/ x.faults < FaultBudget)
    /\ IF p.dir = "c"
       THEN x' = [x EXCEPT !.sSent = Ack(@, p.ack), !.sRecv = Apply(@, p, TRUE),
                    !.expected = IF p.seq >= @ THEN p.seq + 1 ELSE @,
                    !.peer = IF p.seq >= x.expected THEN p.addr ELSE @,
                    !.wire = IF duplicate THEN @ ELSE @ \ {p},
                    !.faults = @ + IF duplicate THEN 1 ELSE 0]
       ELSE /\ x.mode = "live" /\ p.addr = x.addr
            /\ x' = [x EXCEPT !.cSent = Ack(@, p.ack), !.cRecv = ClientApply(@, p),
                       !.phase = IF ClientWouldPanic(x.cRecv, p) THEN "panicked" ELSE @,
                       !.wire = IF duplicate THEN @ ELSE @ \ {p},
                       !.faults = @ + IF duplicate THEN 1 ELSE 0]
Lose(p) ==
    /\ x.phase = "normal" /\ p \in x.wire
    /\ x.faults < FaultBudget \/ (p.dir = "s" /\ (x.mode # "live" \/ p.addr # x.addr))
    /\ x' = [x EXCEPT !.wire = @ \ {p},
               !.faults = @ + IF p.dir = "s" /\ (x.mode # "live" \/ p.addr # x.addr) THEN 0 ELSE 1]

Suspend ==
    /\ x.phase = "normal" /\ x.mode = "live" /\ x.restores < MaxRestores
    /\ x' = [x EXCEPT !.mode = "suspended"]
Save ==
    /\ x.phase = "normal" /\ x.mode = "suspended" /\ ~x.captured
    /\ x' = [x EXCEPT !.blob = Snapshot, !.captured = TRUE]
Persist ==
    /\ x.phase = "normal" /\ x.mode = "suspended" /\ x.captured /\ ~x.freshSave
    /\ x' = [x EXCEPT !.saved = x.blob, !.disk = TRUE, !.freshSave = TRUE]
KillOrFree ==
    /\ x.phase = "normal" /\ x.mode # "dead" /\ x.restores < MaxRestores
    /\ ((x.mode = "suspended" /\ x.freshSave) \/ (AllowStaleKill /\ x.restores > 0))
    /\ x' = [x EXCEPT !.mode = "dead", !.sealed = {}]
ReadSaved ==
    /\ x.phase = "normal" /\ x.mode = "dead" /\ x.disk
    /\ x' = [x EXCEPT !.mode = "loaded"]
ClearSaved ==
    /\ x.phase = "normal" /\ x.mode = "loaded"
    /\ x' = [x EXCEPT !.disk = IF ConsumeCheckpoint THEN FALSE ELSE @, !.mode = "ready"]
Restore ==
    /\ x.phase = "normal" /\ x.mode = "ready"
    /\ x' = [x EXCEPT !.cRecv = x.saved.received, !.cSent = x.saved.sent,
               !.nextSeq = IF WallAhead THEN Max({x.saved.next, Max(x.used \cup {0}) + 1})
                           ELSE x.saved.next,
               !.addr = @ + 1, !.restores = @ + 1, !.mode = "live",
               !.freshSave = FALSE, !.captured = FALSE]
RestoreMissing ==
    /\ x.phase = "normal" /\ x.mode = "dead" /\ ~x.disk
    /\ x' = [x EXCEPT !.lostCheckpoint = TRUE, !.phase = "done"]

\* After any explored history, settle the network. This is a fair retry
\* suffix, NOT an assumption that the receiver possesses the needed state.
\* Client first sends its highest ACK and a fresh nonce from its new socket.
BeginRecovery ==
    /\ x.phase = "normal" /\ x.mode = "live" /\ x.restores > 0
    /\ x.wire = {} /\ x.sealed = {}
    /\ x' = [x EXCEPT !.phase = "rehome"]
RecoveryClientSeal ==
    /\ x.phase = "rehome"
    /\ x' = [x EXCEPT !.sealed = {Packet("c", Min(x.cSent), MaxState + 1,
                  Max(x.cRecv), Min(x.cSent), x.nextSeq, x.addr)},
               !.cSent = @ \cup {MaxState + 1},
               !.nonceSafe = @ /\ x.nextSeq \notin x.used,
               !.used = @ \cup {x.nextSeq}, !.nextSeq = @ + 1, !.phase = "emit"]
RecoveryClientEmit ==
    /\ x.phase = "emit"
    /\ x' = [x EXCEPT !.wire = x.sealed, !.sealed = {}, !.phase = "rehome_receive"]
RecoveryServerReceive ==
    /\ x.phase = "rehome_receive"
    /\ LET p == CHOOSE p \in x.wire : TRUE
       IN x' = [x EXCEPT !.sSent = Ack(@, p.ack), !.sRecv = Apply(@, p, TRUE),
                  !.sApplied = p.old \in x.sRecv,
                  !.expected = IF p.seq >= @ THEN p.seq + 1 ELSE @,
                  !.peer = IF p.seq >= x.expected THEN p.addr ELSE @,
                  !.wire = {}, !.phase = "timeout"]
ServerTimeout ==
    /\ x.phase = "timeout"
    /\ x' = [x EXCEPT !.probe = Min(x.sSent), !.phase = "retry"]
RecoveryServerSend ==
    /\ x.phase = "retry"
    /\ x' = [x EXCEPT !.wire = {Packet("s", x.probe, MaxState + 1,
                   Max(x.sRecv), Min(x.sSent), 0, x.peer)},
               !.sSent = @ \cup {MaxState + 1}, !.phase = "retry_receive"]
RecoveryClientReceive ==
    /\ x.phase = "retry_receive"
    /\ LET p == CHOOSE p \in x.wire : TRUE
       IN x' = [x EXCEPT !.applied = p.old \in x.cRecv /\ p.addr = x.addr /\ ~ClientWouldPanic(x.cRecv, p),
                  !.cRecv = IF p.addr = x.addr THEN ClientApply(@, p) ELSE @,
                  !.cSent = IF p.addr = x.addr THEN Ack(@, p.ack) ELSE @,
                  !.wire = {}, !.phase = IF p.addr = x.addr /\ ClientWouldPanic(x.cRecv, p) THEN "panicked" ELSE "done"]

Next == ClientSeal \/ ClientEmit \/ ServerSend \/ CullClient \/ CullServer
        \/ (\E p \in x.wire : Deliver(p, FALSE) \/ Deliver(p, TRUE) \/ Lose(p))
        \/ Suspend \/ Save \/ Persist \/ KillOrFree \/ ReadSaved \/ Restore \/ RestoreMissing \/ ClearSaved
        \/ BeginRecovery \/ RecoveryClientSeal \/ RecoveryClientEmit \/ RecoveryServerReceive
        \/ ServerTimeout \/ RecoveryServerSend \/ RecoveryClientReceive
Spec == Init /\ [][Next]_vars
        /\ WF_vars(RecoveryClientSeal) /\ WF_vars(RecoveryClientEmit)
        /\ WF_vars(RecoveryServerReceive) /\ WF_vars(ServerTimeout)
        /\ WF_vars(RecoveryServerSend) /\ WF_vars(RecoveryClientReceive)

\* One promise, including availability of the checkpoint and nonce-safe roaming.
ResumeContinuity == ~x.lostCheckpoint /\ x.nonceSafe
                    /\ (x.restores > 0 => x.phase # "panicked")
                    /\ (x.phase = "done" => x.applied /\ x.sApplied)
EventuallyApplies == (x.phase = "rehome") ~> x.applied
=============================================================================
