-------------------------- MODULE MoshReconnect --------------------------
EXTENDS Naturals, TLC

\* Two server/key generations, one reconnect, one completed checkpoint.
\* Protocol references/nonces within either generation are checked by MoshResume.
CONSTANTS RetireAfterInstall, FreezeSuspended
VARIABLE x
vars == <<x>>
Client(epoch) == [key |-> epoch, server |-> epoch, pid |-> epoch]
Coherent(c) == c.key = c.server /\ c.server = c.pid

Init == x = [mode |-> "live", suspended |-> FALSE,
             client |-> Client(0), alive |-> {0},
             reconnect |-> "none", blob |-> Client(0), captured |-> FALSE,
             saved |-> Client(0), disk |-> FALSE, persisted |-> FALSE]

\* remote::reconnect captures the old PID under the session lock. The app
\* starts this in the foreground; its Rust task can outlive app suspension.
BeginReconnect ==
    /\ x.mode = "live" /\ x.reconnect = "none"
    /\ x' = [x EXCEPT !.reconnect = "requested"]

\* ssh::mosh_bootstrap's old implementation retires before launching.
\* The repaired ordering retires only the old generation after installation.
RetireOld ==
    /\ x.reconnect = IF RetireAfterInstall THEN "installed" ELSE "requested"
    /\ x' = [x EXCEPT !.alive = @ \ {0},
               !.reconnect = IF RetireAfterInstall THEN "done" ELSE "retired"]
StartNew ==
    /\ x.reconnect = IF RetireAfterInstall THEN "requested" ELSE "retired"
    /\ x' = [x EXCEPT !.alive = @ \cup {1}, !.reconnect = "bootstrapped"]
\* Session::update is one mutex hold: all identity fields change together.
\* mode tracks the app lifecycle; suspended is the protocol flag. Deleting
\* the new guard installs a live client even though the app is backgrounded.
Install ==
    /\ x.reconnect = "bootstrapped" /\ x.mode \in {"live", "suspended"}
    /\ ~FreezeSuspended \/ ~x.suspended
    /\ x' = [x EXCEPT !.client = Client(1), !.reconnect = "installed",
               !.suspended = IF RetireAfterInstall THEN FALSE ELSE @]
RejectSuspended ==
    /\ FreezeSuspended /\ x.suspended /\ x.mode = "suspended" /\ x.reconnect = "bootstrapped"
    /\ x' = [x EXCEPT !.reconnect = "rejected"]
CleanupNew ==
    /\ x.reconnect = "rejected"
    /\ x' = [x EXCEPT !.alive = @ \ {1}, !.reconnect = "done"]

Suspend ==
    /\ x.mode = "live"
    /\ x' = [x EXCEPT !.mode = "suspended", !.suspended = TRUE]
Save ==
    /\ x.mode = "suspended" /\ ~x.captured
    /\ x' = [x EXCEPT !.blob = x.client, !.captured = TRUE]
Persist ==
    /\ x.mode = "suspended" /\ x.captured /\ ~x.persisted
    /\ x' = [x EXCEPT !.saved = x.blob, !.disk = TRUE, !.persisted = TRUE]
Kill ==
    /\ x.mode = "suspended" /\ x.persisted
    /\ x' = [x EXCEPT !.mode = "dead"]
ReadSaved ==
    /\ x.mode = "dead" /\ x.disk
    /\ x' = [x EXCEPT !.mode = "loaded"]
ClearSaved ==
    /\ x.mode = "loaded"
    /\ x' = [x EXCEPT !.mode = "ready", !.disk = FALSE]
Restore ==
    /\ x.mode = "ready"
    /\ x' = [x EXCEPT !.client = x.saved, !.mode = "restored", !.suspended = FALSE]

Next == BeginReconnect \/ RetireOld \/ StartNew \/ Install \/ RejectSuspended
        \/ CleanupNew \/ Suspend \/ Save \/ Persist \/ Kill \/ ReadSaved
        \/ ClearSaved \/ Restore
Spec == Init /\ [][Next]_vars

\* Coherence alone does not establish that a checkpoint can still connect.
PairCoherent == Coherent(x.client) /\ Coherent(x.blob) /\ Coherent(x.saved)
RestoredServerAlive == x.mode = "restored" => x.client.server \in x.alive
=============================================================================
