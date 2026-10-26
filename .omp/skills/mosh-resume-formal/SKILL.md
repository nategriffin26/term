---
name: mosh-resume-formal
description: Use on changes to mosh retained states, ACKs, nonce restart, reconnect/server retirement, suspend/save/free/restore ordering, or checkpoint consumption; rerun and maintain the resume models.
---

# Mosh resume

**Promise:** After a completed suspend/save, killing the suspended app and restoring it on a new UDP address, including a second suspend/save/kill/restore cycle, never permanently loses the references needed to apply the still-running server's diffs or reuses an encryption nonce.

**Harm:** A broken restore freezes the terminal until a fresh SSH bootstrap, and a reused nonce can compromise the session's encryption.

The scope was settled by the lead: unexpected foreground crashes are outside this promise; a fresh bootstrap is the recovery, not reuse of an old checkpoint.

## Run

From the repo root:

```sh
python3 formal/mosh-resume.py
```

Requires Python 3, Java 21, Rust/Cargo, and the workspace's downloaded Cargo dependencies (`--offline`). The command downloads TLC into ignored `local/formal/mosh-resume/`, checks its SHA-256 on every run, executes a probe against the **actual mosh crate**, checks reviewed function fingerprints, and runs both the SSP and reconnect-lifetime models. Exit 0 means both bounded models passed; an invariant violation, source drift, tool failure, or policy mismatch is nonzero. Full output and counterexamples are in `local/formal/mosh-resume/{safe,reconnect}.log`. TLC state databases are removed after each run.

Tool: TLA+ TLC, because the risk is ordering across the two protocol endpoints, asynchronous UDP and persistence, not an isolated arithmetic function. Release URL: `https://github.com/tlaplus/tlaplus/releases/download/v1.8.0/tla2tools.jar`; SHA-256 `d15655eeaff4b3f7b3d65c46b838bc0f35d131b2ef4b1e473689b62c98d4726f`. The downloaded jar identifies itself as `TLC2 Version 2026.10.24.013619 (rev: 2ef2af8)`: the checksum, not the mutable release tag alone, pins it. A changed release asset must not be silently accepted.

## What is checked

`ResumeContinuity` requires a restorable checkpoint, unique sealing nonces, no post-restore empty-receiver panic, and successful application of a fresh server state after a fair retry. `EventuallyApplies` also rules out stuttering forever after recovery begins.

`resume-safe.cfg`: two nonzero distinguished SSP state numbers per direction; two normal instruction sends per endpoint; two restore cycles; two wire messages plus one client send already sealed outside the lock; **one shared loss-or-duplication budget**. Delivery order is arbitrary. Packets to a suspended, dead or superseded socket can be dropped without consuming the fault budget. The recovery suffix adds one fresh client instruction and one fresh server instruction beyond the numbered prefix.

Interior queue culling is an overapproximation: any interior retained sender state can be dropped, while first/last remain. Concrete queues remove the entry 16 positions before the end when the 33rd entry is appended. The small model compresses irrelevant interior states; a culling counterexample must be expanded to that concrete threshold before calling it a bug. It does not claim exhaustive enumeration of 33 literal states.

Time is abstracted to reference selection: normal sends may use any retained reference, including optimistic recent states, expired-to-front fallback, and the prospective-resend optimization. The recovery suffix explicitly expires the assumption and sends from the acknowledged front. ACKs are processed **before** duplicate or missing-reference rejection. Both receiver lists retain the throwaway boundary itself.

## Code correspondence

The continuity invariant checks both directions after restore: the client applies the server's fallback diff (`applied`) and the server applies the client's recovery instruction (`sApplied`).

Last reviewed revisions: mosh, termcore/SSH lifecycle, and app checkpoint/reconnect callers **`04b81cd`**. Review covered `aecc24a`, `d4b78ae` (test cleanup only), `4cad2bc`, app `1163bf4`/`4c44da9`, the resulting `3720db8` repair, `7a171dd` (old server retired over the bootstrap connection instead of the shared cache, and never when its pid equals the new server's; `RetireOld` unchanged), `644a388` (SSH-transport branch of `replace_remote` passes the startup command; no mosh change), and `04b81cd` (app `Tab.wireAutoReconnect`: the probe of a tab in Term's own tmux attach asks `tmux has-session` and frees the tab when the session is gone, before any reconnect starts; a reconnect runs `tmux attach -t =NAME`; core ordering unchanged, the free is the model's `KillOrFree`). Hashes before `5a5c069` refer to the pre-public history. The SSP functions are unchanged since `114c04d`; their model and bounds remain unchanged. Exact covered function bodies, including new reconnect writers, are pinned in `formal/mosh-resume-code.json`. The upstream endpoint is mosh-server **1.4.0**, read from `local/mosh-src/src/` (gitignored; fetch with `mkdir -p local && git clone -q --depth 1 --branch mosh-1.4.0 https://github.com/mobile-shell/mosh.git local/mosh-src`); these upstream files are not product files in this repo.

| Model action/operator | Code to read |
| --- | --- |
| `Init`, `Snapshot` | `core/mosh/src/lib.rs`: `Client::new`, `Persistent`, `Client::save` |
| `ClientSeal`, `RecoveryClientSeal` | `core/mosh/src/lib.rs`: `Client::next_datagram`, `next_send`, `next_wake`; `core/termcore/src/remote.rs`: `State::mosh_plan` |
| `ClientEmit`, `RecoveryClientEmit` | `core/termcore/src/remote.rs`: `mosh_loop`, its `sock.send(d).await` after releasing the session mutex |
| `ServerSend`, `RecoveryServerSend` | `local/mosh-src/src/network/transportsender-impl.h`: `tick`, `send_empty_ack`, `send_to_receiver`, `send_in_fragments` |
| `CullClient`, `CullServer` | `core/mosh/src/state.rs`: `add_sent`; upstream `transportsender-impl.h`: `add_sent_state` |
| `Deliver` client-to-server, `RecoveryServerReceive` | upstream `network.cc`: `Connection::recv_one` (`seq >= expected_receiver_seq` changes address; old packets still return payload); `networktransport-impl.h`: `Transport::recv` |
| `Deliver` server-to-client, `RecoveryClientReceive` | `core/termcore/src/remote.rs`: `State::mosh_receive` (drops while suspended); `core/mosh/src/lib.rs`: `Client::receive` |
| `Ack` | `core/mosh/src/state.rs`: `acknowledge`, `UserStream::discard_before`; upstream `transportsender-impl.h`: `process_acknowledgment_through` |
| `Apply`, `Retain` | `core/mosh/src/state.rs`: `may_apply`, `retain_from`; upstream `networktransport-impl.h`: `recv`, `process_throwaway_until`, `get_remote_diff` |
| `ClientWouldPanic`, `ClientApply`, phase `panicked` | `Client::receive`: after `retain_from`, `latest_number` unwraps the last retained state **before** inserting the new state; the measured broken policy can empty that map |
| `ServerTimeout` | upstream `transportsender-impl.h`: `update_assumed_receiver_state`, `calculate_timers`; client counterpart `core/mosh/src/state.rs`: `assumed` |
| `Suspend` | `SessionRegistry.suspendAll` -> `term_session_suspend` -> `Mosh::suspend`; `State::mosh_plan` parks and `mosh_receive` drops packets |
| `Save` | `core/termcore/src/lib.rs`: `term_session_save` -> `Mosh::save` -> `Client::save`, under the session lock |
| `Persist` | `app/Sources/Shell/SessionRegistry.swift`: `suspendAll`, successful atomic blob/index writes |
| `KillOrFree` | OS process termination, or `term_session_free` -> `State::stop` while suspended; discards sealed-but-unsent packets, never sends shutdown |
| `ReadSaved`, `ClearSaved` | `SessionRegistry.restoreSaved`: read blobs, then `clearSaved`, **before** constructing any restored session; `resumeAll` also deletes before enabling network |
| `Restore` | `term_session_restore` -> remote `restore` -> `Client::restore`, `resumed_sequence`; `mosh_loop` binds a fresh socket and `socket_rebound` -> `Client::resume` forces send |
| `RestoreMissing` | `SessionRegistry.restoreSaved`: missing index/blob cannot restore a session |
| `Lose`, duplicate `Deliver` | UDP/environment faults; suspended receive guard and discarded sockets are explicit code paths |
| `BeginRecovery` | Observer switches from bounded adversarial history to a fair, quiescent retry suffix; not a product operation |

Every normal client protocol operation is one mutex hold; the network emission is a **different** action. Thus an ACK sealed before suspend can reach the server **after save**. Its nonce and acknowledged reference were already included in the saved client. Serialization and durable publication are separate actions. `Persist` combines the blob/index writes only under the stated assumption that both finish successfully before the kill; it is not a filesystem crash-atomicity proof. Read, deletion, and restore are separate steps.

### Reconnect and server lifetime

The SSP promise still concerns a **still-running server**, not a server that expired its idle timeout or was deliberately retired. `MOSH_SERVER_NETWORK_TMOUT` changes how long that premise holds, not the SSP retention or nonce rules. `core/ssh/src/mosh.rs:mosh_bootstrap` sets it on every launch candidate. Neither model promises that a server survives its configured timeout.

Reconnect needs a separate lifetime check: a coherent snapshot can still name a dead server. `MoshReconnect.tla` uses two server/key generations, one reconnect and one completed suspend/save/kill/restore. It checks `PairCoherent` and `RestoredServerAlive`; no packet/state-number product is needed because `MoshResume.tla` independently checks SSP within each generation. This is a safety check without fairness. It assumes the original server is alive initially, fresh bootstrap keys, successful checkpoint publication/consumption, and no server death except the modeled retirement/cleanup.

`Session::update` (`core/termcore/src/session.rs:345-349`) holds the same mutex as `term_session_save` (`core/termcore/src/lib.rs:74-83`). `replace_remote` installs the client and PID together; `Client::save` stores key, address, next nonce and retained states together (`core/mosh/src/lib.rs:453-459`). There is no mixed old/new pair. Epoch guards in `mosh_plan` and `mosh_receive` prevent an old task from mutating the replacement. A previously sealed old packet still belongs to the old key/server; it cannot advance the replacement's nonce stream.

| Lifecycle action | Code correspondence |
| --- | --- |
| `BeginReconnect` | `Tab.reconnect` -> `term_session_reconnect` -> remote `reconnect`; the Rust task can outlive `AutoReconnect.suspended` |
| `StartNew`, `RetireOld` | remote `replace_remote`; SSH `mosh_bootstrap`, `end_server_command`; remote launch/termination is not a session-lock action |
| `Install`, `RejectSuspended`, `CleanupNew` | `replace_remote`'s locked installation decision, then cleanup of an uninstalled server |
| `Suspend`, `Save`, `Persist` | `Tab.suspend`, `Session.save`, `SessionRegistry.suspendAll`; serialization and durable publication are separate actions |
| `Kill`, `ReadSaved`, `ClearSaved`, `Restore` | OS kill and `SessionRegistry.restoreSaved`; the saved generation is restored, not the generation last installed in memory |

`resume-reconnect-before.cfg` preserves the `aecc24a` bug. At that revision, bootstrap prepends old-server termination (`core/ssh/src/mosh.rs:38-45`) before the installation lock. Suspension only freezes the old protocol loop: `replace_remote` could still swap while suspended. A completed checkpoint can therefore contain old key/address/PID while reconnect has retired that server. A post-swap save is coherent for the new server; a pre-swap save is not rewritten by a later swap. The shortest counterexample needs no successful replacement: begin reconnect, retire old, suspend/save/persist, kill, read/delete/restore the old checkpoint. No abstract culling is involved.

The repair in `3720db8` launches without retiring the old server (`remote.rs:669-670`), rejects installation while stopped/suspended under the session lock (`672-677`), cleans up an uninstalled new server (`695-696`), and retires the old server only after successful installation (`697-702`, over the bootstrap connection since `7a171dd`). Suspending first preserves the old pair/server; installing first makes both of Swift's save-size/copy calls see the new pair. A kill while bootstrap is in flight cannot retire the saved server. Freeing a suspended session similarly sets `stopped`, preventing installation. Bootstrap failure leaves the old server intact. Not modeled: an app Resume action; `RestoredServerAlive` relies on `SessionRegistry.resumeAll` deleting checkpoints before resuming (a scratch model with Resume that skips the delete goes red), which the SSP model's checkpoint-consumption check covers.

The runner derives `FreezeSuspended` from that exact source guard, after checking the rest of the function's fingerprint. This is reviewed control-flow correspondence, **not an executable termcore probe**. The only accepted alternate source is deletion of that three-line guard; every other edit requires review. The model separates the app's background state from the protocol's `suspended` flag: with the guard deleted, the replacement is live even though the app remains backgrounded.

### Variables

All fields live in model record `x`:

- `cSent`, `cRecv`: `Client.sent`/`received`; `sSent`, `sRecv`: upstream `sent_states`/`received_states`. Set membership and ordering matter; terminal bytes and user-stream positions are not modeled.
- `nextSeq`: `Client.next_sequence`; `expected`: upstream `Connection.expected_receiver_seq`; `used`, `nonceSafe`: ghost observations of the nonces passed to `Crypto::seal`.
- `addr`, `peer`: successive client UDP sockets and the server's `remote_addr`; integer labels stand for distinct source addresses.
- `sealed`: `State::mosh_plan`'s `datagrams` held by `mosh_loop`; `wire`: UDP instructions in flight. Complete authenticated instructions abstract fragment assembly.
- `mode`: `Mosh.suspended`, process existence and the app's checkpoint-loading steps. `saved`, `disk`: saved client and durable checkpoint existence; `blob`, `captured`: serialized bytes before durable publication; `freshSave`: completed checkpoint in this lifecycle.
- `cSends`, `sSends`, `restores`, `faults`: observer counters implementing the bounds, not product fields.
- `phase`, `probe`, `applied`, `lostCheckpoint`: observer state for the fair-retry suffix, the server's timed-out reference, successful new-state application, and failed checkpoint lookup.

## Fairness and exclusions

Safety needs no fairness. The conditional eventual-application check assumes weak fairness for the six recovery actions: client timer/seal, UDP send, server receive, timeout expiry, server send, client receive. The process and server stay alive during that suffix, bind succeeds, and both directions eventually deliver a complete instruction; no unending new output prevents the timeout fallback. `BeginRecovery` itself is **not** assumed fair: permanent network partition, permanent suspension, and endless process kills do not promise progress. The suffix tests that, once connectivity returns, protocol state has not made recovery impossible.

One client owns the key. On the main path (`resume-safe.cfg`, `WallAhead = FALSE`) restore takes only the saved next nonce, so the check proves `Client::save` stores a nonce past every pre-suspend sealed packet (a save that forgets it turns `nonceSafe` red). For the stale and foreground counterexamples only (`WallAhead = TRUE`), wall time on restore is assumed greater than every earlier sealed nonce, matching the documented non-rolling-back clock/packet-rate assumption of `resumed_sequence`. Clock rollback, counter exhaustion, encrypted-block limits, concurrent restores, compromised peers, invalid/corrupt snapshots, disk write/delete failures, fragmented-message resource limits, >1024 receiver quenching, terminal/parser correctness, and user-input/state-content identity are not proven here. No live phone, wall-clock scheduling or general unbounded protocol proof is claimed.

The successful-checkpoint assumption matters: `clearSaved` uses best-effort deletion, and blob/index publication spans multiple filesystem operations. A disk failure or a kill during publication/consumption is not covered. An unexpected foreground kill after consuming a checkpoint has no saved state; the app must reconnect/bootstrap instead.

## Counterexamples kept separate

```sh
python3 formal/mosh-resume.py --scenario stale
python3 formal/mosh-resume.py --scenario foreground
python3 formal/mosh-resume.py --scenario reconnect-before
```

These are deliberately red, not part of the green gate:

- `stale`: retains a checkpoint while allowing another unsaved process kill. This represents the **old** checkpoint reuse risk, not the current delete-before-network ordering. Restore the checkpoint, receive a newer state, send its ACK, let the server discard older states, die without saving, then restore the old checkpoint. Even the server's timeout fallback now names a reference the client lacks. More retries cannot reconstruct it.
- `foreground`: uses current checkpoint consumption but allows the out-of-scope foreground kill. After restore consumes the checkpoint, another kill has nothing to restore. This documents the lead's explicit non-goal rather than weakening the main property.
- `reconnect-before`: the historical retire-before-install ordering can restore a coherent checkpoint whose server reconnect has killed. `PairCoherent` stays true; `RestoredServerAlive` fails. The default command checks the repaired ordering with `resume-reconnect.cfg`.

## Maintain and prove it can fail

1. Read every covered changed function and its callers since the sync revisions. A fingerprint mismatch is **model drift requiring review**, not evidence of a product bug. It cannot be waived just to obtain green.
2. Replay every TLC counterexample against those functions, in the printed order. An impossible code step means the model is wrong. Expand abstract sender culling to 33 concrete states. A valid code trace is a finding: report it without changing product code or weakening the property.
3. Update the model for intentional code changes. After review, run `python3 formal/mosh-resume.py --record-reviewed-code` to refresh the correspondence fingerprints. This is not a test and does not advance the sync revision by itself.
4. Run the main check (SSP and reconnect lifetime) and the three separate counterexample scenarios. Main must be green; counterexamples must fail for their named reason, not a parser/tool error. Replay each trace against its current or explicitly historical code.
5. In a disposable git worktree containing this verification commit, change **real** `core/mosh/src/state.rs:retain_from` from `*num < throwaway` to `*num <= throwaway`. Run the same main command there. The Rust probe measures the changed policy and sets `KeepBoundary = FALSE`; TLC must report `ResumeContinuity` violated. Restore that line, then delete only the three-line `if matches!(&st.remote, Remote::Mosh(old) if old.suspended)` guard in `replace_remote`. Run the same main command: SSP stays green, the source-derived `FreezeSuspended = FALSE` must make `RestoredServerAlive` red. These are the only two normalized fingerprint mutations. Do not edit models/configs to manufacture either result.
6. Delete only that scratch worktree, rerun the unchanged real checkout green, and advance sync revisions after confirming correspondence. Commit verification separately from product fixes.

There are no existing protocol-transition logging hooks in the covered Rust client/termcore, so this is not TLC replay of recorded product executions. The real-code probe checks the complete small retention/may-apply/sequence truth tables; the distributed ordering model remains a reviewed abstraction. A successful source fingerprint check detects known-body drift, not newly added call sites: search for every new writer when maintaining it.

## Creation evidence

After removing the corrected mutation worktree, the unchanged product checkout passed: **234,069 distinct states / 833,283 generated**, depth 34, invariant and temporal property both green (TLC 10 seconds; command **12.30 seconds**). The full logs remain in ignored `local/formal/mosh-resume/`.

The first scratch mutation exposed a modeling omission: the initial abstraction inserted the new state immediately after retention, but `Client::receive` first calls `latest_number`. Deleting the sole retained reference panics there, before insertion. The model was corrected to represent that exact failure boundary; the mutation was not changed to suit the model.

The corrected mutation run used a detached worktree at `10acb0b`, changing only real `core/mosh/src/state.rs:retain_from` from `<` to `<=`. The unchanged runner measured `KeepBoundary = FALSE`; TLC returned exit 12, `ResumeContinuity` violated, at **13 states** (11,347 distinct states explored; TLC 1 second, whole command 4.58 seconds). Its concrete sequence is: suspend/save/kill; load/delete/restore on a new socket; send an authenticated packet so the server re-homes; receive its `0 -> 1, throwaway = 0` reply; mutated retention removes state 0; `latest_number` unwraps the now-empty map before inserting state 1. No server culling approximation is needed for this counterexample. The mutation worktree was removed, and `mutation.log` preserves the trace.

The historical stale-checkpoint config failed as expected after 27 states (TLC 24 seconds; command 25.54 seconds): saved receiver `{0}`, live receiver `{0,1}`, ACK 1 culls server state 0, second restore returns to `{0}`, server fallback requires 1. The foreground-boundary config failed after 10 states (TLC 1 second; command 3.99 seconds): successful restore consumes the checkpoint, another kill leaves no blob. Neither result is presented as a failure of the current completed-checkpoint path.

## Reconnect maintenance evidence

Verification commit `344a7d2` was tested in a disposable detached worktree. Both real-code mutations below reached TLC, not merely the drift gate. The worktree was removed before rerunning the unchanged product checkout green. A final run after tightening mutation normalization passed both models in **22.20 seconds** including the real mosh probe. All deliberate TLC failures returned exit **12**.

| Check | Result | Distinct / generated states | TLC time | Trace depth |
| --- | --- | --- | --- | --- |
| Main SSP, final rerun | Green | 234,069 / 833,283 | 20 s | 34 |
| Main reconnect, final rerun | Green | 54 / 76 | <1 s | 12 |
| Stale checkpoint | `ResumeContinuity` red | 374,046 / 1,534,270 | 21 s | 27 |
| Foreground kill | `ResumeContinuity` red | 12,004 / 30,740 | 1 s | 10 |
| Historical reconnect | `RestoredServerAlive` red | 41 / 56 | <1 s | 10 |
| Real `retain_from` mutation | `ResumeContinuity` red | 11,347 / 33,563 | 1 s | 13 |
| Real suspension-guard deletion | `RestoredServerAlive` red | 64 / 91 | <1 s | 12 |

Runner times: stale **22.93 s**, foreground **2.14 s**, historical reconnect **1.03 s**, retention mutation **2.80 s**, guard mutation **38.72 s** (includes the unchanged SSP passing first). Main also passed initially in **33.37 s** and immediately after worktree removal in **21.01 s**. These runs plus the final gate totaled **144.20 s**, excluding worktree setup/removal.

The fingerprint-normalizer attack exposed an overly broad first implementation: removing the guard wherever it appeared also accepted moving it. Anchoring normalization to its original location fixed that. Assertions were seen red on the unanchored implementation and green after the change: exact deletion accepted; relocation and an unrelated `stopped`-guard change rejected; reviewed fingerprints unchanged.

Trace replay:
- Stale: save `{0}`; restore without consuming the historical checkpoint; receive state 1, ACK it and let the server discard 0; kill unsaved and restore `{0}` again. Fresh nonce 3 re-homes the server, but the client's recovery references 0 and the server's fallback references 1: each receiver lacks its reference. ACK processing is before reference rejection (`Client::receive:278-286`; upstream `networktransport-impl.h:80-108`, `transportsender-impl.h:349-370`). There is no interior-culling action to expand.
- Foreground: suspend/save/persist, kill, read/delete/restore, kill without saving, then missing checkpoint. This is exactly the stated excluded foreground-kill boundary, not a failure of completed checkpoints.
- Retention mutation: restore `{0}`, send/re-home, receive `0 -> 1` with throwaway 0; mutated `retain_from` removes the sole state before `Client::receive:304` calls `latest_number`. The model ends in `panicked`, with nonce safety still true.
- Guard mutation: begin reconnect, start new server, suspend, capture old blob, install a live new client, retire old, persist captured old blob, kill, read/delete/restore old. `remote.rs:671-699` permits precisely that ordering when only the guard is removed; the new server remains alive but cannot authenticate the old saved key. No mixed-pair or nonce reuse claim is needed.

Full logs: `local/formal/mosh-resume/{safe,reconnect,stale,foreground,reconnect-before,mutation,reconnect-mutation}.log`. No phone run or unbounded proof is claimed. The lifecycle mutation uses source-derived correspondence; only the SSP policy probe executes compiled product code.
