//! Generated checks of the product crate, not a translated assembly model.
#[cfg(test)]
mod tests {
    use mosh::{Error, fragment::{Assembly, Fragment, HEADER_LEN, MAX_FRAGMENTS, MAX_INSTRUCTION, split}, state::may_apply};
    use proptest::prelude::*;
    use std::collections::BTreeMap;

    proptest! {
        #![proptest_config(ProptestConfig { cases: 1024, failure_persistence: None, ..ProptestConfig::default() })]

        #[test]
        fn arbitrary_packets_never_panic(packets in prop::collection::vec(prop::collection::vec(any::<u8>(), 0..=256), 0..=64)) {
            let mut assembly = Assembly::default();
            for packet in packets {
                match Fragment::parse(&packet) {
                    Ok(fragment) => {
                        prop_assert!(packet.len() >= HEADER_LEN);
                        prop_assert_eq!(fragment.id, u64::from_be_bytes(packet[..8].try_into().unwrap()));
                        prop_assert_eq!(fragment.index, u16::from_be_bytes([packet[8], packet[9]]) & 0x7fff);
                        prop_assert_eq!(fragment.last, packet[8] & 0x80 != 0);
                        prop_assert_eq!(fragment.contents, &packet[10..]);
                        let _ = assembly.push(fragment);
                    }
                    Err(error) => {
                        prop_assert!(packet.len() < HEADER_LEN);
                        prop_assert!(matches!(error, Error::Fragment));
                    }
                }
            }
        }

        #[test]
        fn structured_packet_sequences_never_panic(
            packets in prop::collection::vec((0..4u64, prop_oneof![0..8u16, any::<u16>()], any::<bool>(), prop::collection::vec(any::<u8>(), 0..=128)), 0..=64)
        ) {
            let mut assembly = Assembly::default();
            for (id, index, last, contents) in packets {
                let mut packet = id.to_be_bytes().to_vec();
                packet.extend_from_slice(&((index & 0x7fff) | if last { 0x8000 } else { 0 }).to_be_bytes());
                packet.extend_from_slice(&contents);
                let _ = assembly.push(Fragment::parse(&packet).unwrap());
            }
        }

        #[test]
        fn bounded_split_never_panics(payload in prop::collection::vec(any::<u8>(), 0..=256), mtu in any::<usize>(), id in any::<u64>()) {
            let result = split(id, &payload, mtu);
            if mtu <= HEADER_LEN { prop_assert!(matches!(result, Err(Error::Mtu))); }
            else { prop_assert!(result.is_ok()); }
        }

        #[test]
        fn reordered_duplicates_preserve_payload(
            id in any::<u64>(), payload in prop::collection::vec(any::<u8>(), 0..=128), chunk in 1..=32usize,
            extras in prop::collection::vec(any::<u16>(), 0..=256), priorities in prop::collection::vec(any::<u64>(), 384)
        ) {
            let fragments = split(id, &payload, HEADER_LEN + chunk).unwrap();
            let mut schedule: Vec<_> = (0..fragments.len()).chain(extras.into_iter().map(|i| usize::from(i) % fragments.len())).enumerate().map(|(i, index)| (priorities[i], index)).collect();
            schedule.sort_by_key(|&(priority, _)| priority);
            let mut assembly = Assembly::default();
            let mut outputs = 0;
            for (_, index) in schedule {
                if let Some(result) = assembly.push(Fragment::parse(&fragments[index]).unwrap()).unwrap() {
                    prop_assert_eq!(&result, &payload, "every completed instruction must preserve every original byte");
                    outputs += 1;
                }
            }
            prop_assert!(outputs >= 1, "all split fragments delivered must complete an instruction");
        }

        #[test]
        fn interleaved_ids_never_mix_payloads(
            id in any::<u64>(), delta in 1..=u64::MAX,
            a in prop::collection::vec(any::<u8>(), 0..=32), b in prop::collection::vec(any::<u8>(), 0..=32),
            chunk_a in 1..=32usize, chunk_b in 1..=32usize,
            extras in prop::collection::vec((any::<bool>(), any::<u16>()), 0..=128), priorities in prop::collection::vec(any::<u64>(), 192)
        ) {
            let a_fragments = split(id, &a, HEADER_LEN + chunk_a).unwrap();
            let b_fragments = split(id ^ delta, &b, HEADER_LEN + chunk_b).unwrap();
            let mut schedule: Vec<_> = (0..a_fragments.len()).map(|i| (true, i))
                .chain((0..b_fragments.len()).map(|i| (false, i)))
                .chain(extras.into_iter().map(|(choose_a, i)| (choose_a, usize::from(i) % if choose_a { a_fragments.len() } else { b_fragments.len() })))
                .enumerate().map(|(i, event)| (priorities[i], event)).collect();
            schedule.sort_by_key(|&(priority, _)| priority);
            let mut assembly = Assembly::default();
            for (_, (choose_a, index)) in schedule {
                let (fragments, expected) = if choose_a { (&a_fragments, &a) } else { (&b_fragments, &b) };
                if let Some(result) = assembly.push(Fragment::parse(&fragments[index]).unwrap()).unwrap() {
                    prop_assert_eq!(&result, expected, "a completed instruction must contain only its own id's bytes");
                }
            }
        }

        #[test]
        fn reyielded_instruction_is_rejected_by_apply_gate(state_pair in (0..u64::MAX).prop_flat_map(|old| (Just(old), old + 1..=u64::MAX))) {
            let (old, new) = state_pair;
            let mut states = BTreeMap::from([(old, ())]);
            let fragments = split(7, b"x", 11).unwrap();
            let mut assembly = Assembly::default();
            prop_assert_eq!(assembly.push(Fragment::parse(&fragments[0]).unwrap()).unwrap(), Some(b"x".to_vec()));
            prop_assert!(may_apply(&states, old, new, old).unwrap());
            states.insert(new, ());
            prop_assert_eq!(assembly.push(Fragment::parse(&fragments[0]).unwrap()).unwrap(), Some(b"x".to_vec()));
            prop_assert!(!may_apply(&states, old, new, old).unwrap());
        }
    }

    #[test]
    fn instruction_and_fragment_capacity_boundaries() {
        for mtu in [0, 1, HEADER_LEN - 1, HEADER_LEN] {
            assert!(matches!(split(0, b"x", mtu), Err(Error::Mtu)));
        }
        assert!(matches!(split(0, &vec![0; MAX_INSTRUCTION + 1], usize::MAX), Err(Error::Oversized)));
        assert!(matches!(split(0, &vec![0; MAX_FRAGMENTS + 1], HEADER_LEN + 1), Err(Error::Oversized)));
        for size in [MAX_INSTRUCTION - 1, MAX_INSTRUCTION] {
            let payload = vec![0x5a; size];
            let fragments = split(9, &payload, usize::MAX).unwrap();
            assert_eq!(fragments.len(), 1);
            assert_eq!(Assembly::default().push(Fragment::parse(&fragments[0]).unwrap()).unwrap(), Some(payload));
        }
        let payload = vec![0x71; MAX_FRAGMENTS];
        let fragments = split(10, &payload, HEADER_LEN + 1).unwrap();
        assert_eq!(fragments.len(), MAX_FRAGMENTS);
        let mut assembly = Assembly::default();
        let mut outputs = Vec::new();
        for fragment in fragments.iter().rev() {
            if let Some(output) = assembly.push(Fragment::parse(fragment).unwrap()).unwrap() { outputs.push(output); }
        }
        assert_eq!(outputs, vec![payload]);
        let mut assembly = Assembly::default();
        assert!(matches!(assembly.push(Fragment { id: 0, index: u16::MAX, last: true, contents: b"" }), Err(Error::Fragment)));
        assert!(matches!(assembly.push(Fragment { id: 0, index: 0, last: true, contents: &vec![0; MAX_INSTRUCTION + 1] }), Err(Error::Oversized)));
        assembly.push(Fragment { id: 0, index: 0, last: false, contents: &vec![0; MAX_INSTRUCTION] }).unwrap();
        assert!(matches!(assembly.push(Fragment { id: 0, index: 1, last: true, contents: b"x" }), Err(Error::Oversized)));
    }

    #[test]
    #[ignore = "original brief premise: fragment assembly deliberately re-yields completed instructions"]
    fn finding_completed_instruction_replay() {
        let fragments = split(7, b"x", 11).unwrap();
        let mut assembly = Assembly::default();
        assert_eq!(assembly.push(Fragment::parse(&fragments[0]).unwrap()).unwrap(), Some(b"x".to_vec()));
        assert!(assembly.push(Fragment::parse(&fragments[0]).unwrap()).unwrap().is_none(), "completed instruction replay must not emit again");
    }
}
