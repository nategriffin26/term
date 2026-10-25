---
name: mosh-fragment-formal
description: Use on any change to core/mosh/src/fragment.rs (Fragment::parse, Assembly::push, split, size limits) or state.rs's may_apply gate; rerun and maintain the real-code fragment checks.
---

# Mosh fragment reassembly

Property: Within the stated bounds, arbitrary packet bytes never panic, and delivering every fragment produced by `split` in any order with duplication yields only the byte-exact original instruction and never mixes instruction ids.

Harm: A malformed or reordered packet could crash the terminal or corrupt the screen-state stream.

## Run

From the repository root, with Python 3.12+, Rust through rustup, curl and tar:

```sh
python3 formal/mosh-fragment.py fallback
```

This is **proptest on the real product crate, not an exhaustive formal proof**. The command prints that distinction. Proptest 1.12.0 and dependency checksums are pinned in `formal/fragment-proptest/{Cargo.toml,Cargo.lock}`. Each generated property runs 1024 cases. The runner defaults `PROPTEST_RNG_SEED` to `20261025`; set another decimal seed to explore another reproducible sample. Ordinary product builds and tests do not include these checks.

The original brief requested exactly-once fragment output. Preserve its separately red counterexample:

```sh
python3 formal/mosh-fragment.py fallback-finding
```

It must exit nonzero at `completed instruction replay must not emit again`. The lead corrected the premise: fragment assembly is at-least-once, matching mosh, and SSP's state-number gate drops duplicate instructions. This red configuration documents that distinction, not a product defect. Do not add product duplicate suppression to make it green.

## Kani: available, but the exhaustive safety check did not finish

Kani was chosen to execute the real Rust code rather than a hand-translated model. Installation works on Apple Silicon; the limitation here is solver tractability, **not unsupported hardware or an installation failure**. Kani 0.68.0 / CBMC 6.11.0 successfully falsified the concrete replay expectation. Exhaustive safety did not finish: six arbitrary datagrams timed out at 300 seconds with unwind 18 and again with unwind 8; a combined two-datagram / arbitrary-usize-MTU check timed out at 600 seconds; the isolated two-datagram parser/assembly check timed out at 180 seconds with unwind 5. Both symbolic and concrete SSP gate checks also timed out at 180 seconds. These are not green proofs or product counterexamples.

The requested proptest fallback therefore supplies the rerunnable main check. Kani harnesses remain under `cfg(kani)` in `core/mosh/src/fragment_formal.rs`; the sole product-file change is the conditional module declaration. To retry them:

```sh
python3 formal/mosh-fragment.py setup
python3 formal/mosh-fragment.py check
python3 formal/mosh-fragment.py finding
```

`setup` installs `kani-verifier` 0.68.0 from SHA-256-pinned source, a SHA-256-pinned platform release bundle, and nightly-2026-08-21. `check` gives each Kani harness 180 seconds; failure, timeout or insufficient unwind exits nonzero. `finding` runs the concrete replay witness. `check --harness arbitrary_packets_never_panic` selects one obligation. Never treat an unwinding assertion, unsupported operation or timeout as proof. Release/checksum source: https://github.com/model-checking/kani/releases/tag/kani-0.68.0; setup: https://model-checking.github.io/kani/install-guide.html.

Installer source, Cargo downloads, Kani, rustup downloads and all build output stay under gitignored `local/formal/mosh-fragment/`; the user's Rust default is unchanged. `MOSH_FORMAL_CACHE` can share this cache with an isolated worktree.

## Bounds and assumptions

### Generated checks (`fallback`)

- `arbitrary_packets_never_panic`: 0–64 arbitrary datagrams, each 0–256 arbitrary bytes. Checks header interpretation and feeds successful parses to one real `Assembly::push`.
- `structured_packet_sequences_never_panic`: 0–64 packets, four possible ids, arbitrary final flags, indices biased toward 0–7 but also covering all header indices, and 0–128 bytes of contents. Repeated ids exercise conflicting duplicates and inconsistent final indices instead of almost always clearing the map.
- `bounded_split_never_panics`: 0–256 arbitrary payload bytes, arbitrary u64 id and arbitrary usize MTU. Invalid MTUs must return `Error::Mtu`.
- `reordered_duplicates_preserve_payload`: 0–128 payload bytes, arbitrary u64 id, chunk sizes 1–32 (MTU 11–42), 1–128 real fragments. A random priority orders every original fragment plus 0–256 duplicate deliveries, for at most 384 deliveries. Every output must equal the original bytes; at least one output must occur.
- `interleaved_ids_never_mix_payloads`: two distinct arbitrary u64 ids, independent 0–32-byte payloads and chunk sizes 1–32. Randomly orders every fragment of both instructions plus 0–128 duplicates, at most 192 deliveries. Every output must equal the complete payload of the id that completed it. Both instructions need not finish: changing ids discards incomplete assembly by design.
- `reyielded_instruction_is_rejected_by_apply_gate`: real one-fragment replay with generated `old < new`; the real `state::may_apply` accepts before `new` is retained and rejects afterward.
- `instruction_and_fragment_capacity_boundaries`: concrete cases at MTU 0/1/9/10 and `usize::MAX`; instruction lengths 4 MiB−1, 4 MiB and 4 MiB+1; fragment counts 32768 and 32769; direct invalid u16 index; oversized fragment contents and aggregate assembly bytes. A full 32768-fragment reverse-order assembly must reproduce its payload.

Random priorities can produce any permutation of the bounded deliveries, but 1024 generated cases **sample**, rather than enumerate, these spaces.

### Kani harness bounds (`check`; no full green proof)

Two arbitrary datagrams of 0–14 bytes; separate `split` inputs of 0–2 bytes and MTU 0–13 plus the concrete `usize::MAX` boundary; round-trip inputs of 0–2 bytes, chunk sizes 1–2, four reordered/duplicated deliveries including every fragment; interleaved inputs of two distinct u64 ids, two bytes per instruction, one-byte chunks and four deliveries. Id bits, payload bits and header index bits are symbolic. The replay/gate witnesses use concrete id 7, `b"x"`, MTU 11, and (for the gate) `old = 0`, `new = 1`. Main harnesses use unwind 5; replay and gate witnesses use unwind 4. No stubs replace product or standard-library behavior.

No timers, concurrency or fairness assumptions: one `push` is one synchronous operation. Completion checks explicitly deliver every fragment. The apply-gate witness assumes the replay keeps its `old`/`new`/`throwaway` fields and the completed state remains retained; it does not decode an actual instruction or execute `Client::receive` end to end. Neither tool result proves arbitrary-length streams, every payload size or delivery schedule, out-of-memory behavior, compression, crypto, protobuf, the whole SSP state machine or the iOS application.

## Code correspondence and sync

| Action / state | Real implementation |
| --- | --- |
| Bytes → `id`, `index`, `last`, `contents`, or parse error | `core/mosh/src/fragment.rs`, `Fragment::parse`, `HEADER_LEN` |
| Payload/id/MTU → wire fragments | Same file, `split`, `MAX_FRAGMENTS`, `MAX_INSTRUCTION` |
| One complete delivery | Same file, `Assembly::push` |
| Current id, stored parts, final count, accumulated bytes | Actual `Assembly::{id, fragments, count, bytes}`, not a replica |
| Schedule priorities/indices, seen flags, output count | Harness-only input selection and observation |
| Cross-id payload identity | `Assembly::push`'s new-id clearing branch and ordered concatenation |
| Retained-state membership gate | `core/mosh/src/state.rs`, `may_apply`, on a real BTreeMap |
| Gate/caller correspondence (read, not executed end to end) | `core/mosh/src/lib.rs`, `Client::receive`: parse → push → decode → `may_apply` → terminal changes → insert `instruction.new` |

Last confirmed product revision: `114c04d35d41cdb71ac4a24a46429a9c6951b664`. This was the only fragment implementation commit at creation; its message and code were read. No remote issue tracker was configured. Verification changes do not alter these product functions.

## Finding: completed instruction replay

1. `split(7, b"x", 11)` emits index 0 with `last = true`.
2. Parse and push it: `count = Some(1)`, then output `Some(b"x")`.
3. Completion clears `fragments`, `count` and `bytes`, but retains `id`.
4. Push the same parsed fragment again: no stored duplicate remains, so it emits `Some(b"x")` again.
5. If state `new` was retained after first application, `state::may_apply` returns false before any second terminal update.

The fragment expectation was wrong; pre-completion duplicate idempotence does not imply post-completion suppression. Keep the separately red witness as evidence. Do not weaken it or modify product behavior in this pass.

## Maintaining and attacking the check

Read changes to the covered functions/state/limits from the sync revision. Update harnesses from the actual code and intended contract, never to obtain a pass. A reachable failed assertion is a finding; an input/step the real code cannot take is a harness error. For generated failures, use the printed minimal input and seed to replay the real calls. A new finding gets its own failing configuration so remaining checks stay green.

Commit verification files, then create an isolated worktree:

```sh
git worktree add --detach local/formal/mosh-fragment-attack HEAD
```

Only there, change `if fragment.last { self.count = Some(index + 1); }` to `Some(index + 2)` in `core/mosh/src/fragment.rs`. From that worktree run:

```sh
python3 formal/mosh-fragment.py fallback --harness reordered_duplicates_preserve_payload
```

It must fail: all fragments have arrived, but the final count is off by one. `MOSH_FORMAL_CACHE` may share the original checkout's cache; otherwise downloads/build output remain under the worktree's own ignored `local/`. Restore that one scratch line with an edit, remove the clean owned worktree, then run `fallback` and `fallback-finding` on real code. The former must be green; the latter must fail only on the original stronger premise. Never mutate the live product checkout for this attack. Move the sync revision forward only after confirming correspondence at the new revision.

## Recorded attack evidence

At verification revision `25b0f7b`, the skill's isolated-worktree attack was followed against the real `fragment.rs`. Each mutation was restored before the next; the clean worktree was then removed.

| Scratch break | Check observed failing | Evidence | Check / command time |
| --- | --- | --- | --- |
| Final count `index + 1` → `index + 2` | `reordered_duplicates_preserve_payload` | Shrunk payload `[]`, chunk 1: every fragment arrived, no output completed | 0.12 s / 4.59 s |
| Omit `fragments.clear()` on a new id | `interleaved_ids_never_mix_payloads` | A valid interleaved delivery returned `Error::Fragment` | 0.01 s / 11.79 s |
| Header guard `< HEADER_LEN` → `< HEADER_LEN - 1` | `arbitrary_packets_never_panic` | A 9-byte packet reached `[8..10]` and panicked | 0.01 s / 3.68 s |

The separately red native replay witness failed at its intended assertion in 0.19 s command time. The Kani replay witness failed at the same semantic assertion in 15.39 s verification / 23.42 s command time. Initial fallback run: 7 passed, 1 intentionally ignored; 1.46 s tests / 24.62 s command including cold compilation. These attacks cover the length guard, final-count completion and new-id clearing; they do not mutation-test every limit, splitter line or SSP path.

The final concrete Kani gate retry exercised the runner's native timeout: CBMC reported `CBMC timed out`, `VERIFICATION:- FAILED`, zero successful harnesses, and exit status 1 (188.05 s command time). The generated gate check is green; the whole receive/apply pipeline remains unproved. Normal Rust compilation currently reports `unexpected_cfgs` for `cfg(kani)`; no product lint settings were changed under this assignment's module-only permission.

After restoring all mutations and removing the clean worktree, the real-code fallback was rerun: **7 passed, 0 failed, 1 intentional finding ignored**, with 6144 generated cases plus concrete boundary checks; 0.82 s tests / 2.17 s command time. No product fixes were made.
