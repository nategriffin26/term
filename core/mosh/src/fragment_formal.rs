//! Bounded checks of the real fragment implementation; see the project skill.
use super::*;

const PAYLOAD: usize = 2;
const STEPS: usize = 4;

#[kani::proof]
#[kani::unwind(5)]
fn arbitrary_packets_never_panic() {
    let mut assembly = Assembly::default();
    for _ in 0..2 {
        let bytes: [u8; HEADER_LEN + 4] = kani::any();
        let len = usize::from(kani::any::<u8>());
        kani::assume(len <= bytes.len());
        match Fragment::parse(&bytes[..len]) {
            Ok(fragment) => {
                assert!(len >= HEADER_LEN);
                assert_eq!(fragment.index, u16::from_be_bytes([bytes[8], bytes[9]]) & 0x7fff);
                assert_eq!(fragment.last, bytes[8] & 0x80 != 0);
                assert_eq!(fragment.id, u64::from_be_bytes(bytes[..8].try_into().unwrap()));
                assert_eq!(fragment.contents, &bytes[HEADER_LEN..len]);
                let _ = assembly.push(fragment);
            }
            Err(error) => {
                assert!(len < HEADER_LEN);
                assert!(matches!(error, Error::Fragment));
            }
        }
    }
}

#[kani::proof]
#[kani::unwind(5)]
fn bounded_split_never_panics() {
    let bytes: [u8; PAYLOAD] = kani::any();
    let len = usize::from(kani::any::<u8>());
    kani::assume(len <= PAYLOAD);
    let mtu = usize::from(kani::any::<u8>());
    kani::assume(mtu <= HEADER_LEN + PAYLOAD + 1);
    let _ = split(kani::any(), &bytes[..len], mtu);
    let _ = split(kani::any(), &bytes[..len], usize::MAX);
}

#[kani::proof]
#[kani::unwind(5)]
fn reordered_duplicates_preserve_payload() {
    let bytes: [u8; PAYLOAD] = kani::any();
    let len = usize::from(kani::any::<u8>());
    let chunk = usize::from(kani::any::<u8>());
    kani::assume(len <= PAYLOAD);
    kani::assume(chunk >= 1 && chunk <= PAYLOAD);
    let payload = &bytes[..len];
    let fragments = split(kani::any(), payload, HEADER_LEN + chunk).unwrap();
    let mut assembly = Assembly::default();
    let mut delivered = [false; PAYLOAD];
    let mut outputs = 0;
    for _ in 0..STEPS {
        let index = usize::from(kani::any::<u8>());
        kani::assume(index < fragments.len());
        delivered[index] = true;
        if let Some(result) = assembly.push(Fragment::parse(&fragments[index]).unwrap()).unwrap() {
            assert_eq!(result, payload, "completed instruction must preserve every byte");
            outputs += 1;
        }
    }
    for seen in &delivered[..fragments.len()] { kani::assume(*seen); }
    assert!(outputs >= 1, "all fragments delivered must complete an instruction");
}

// This deliberately red witness records the original brief's stronger premise.
#[kani::proof]
#[kani::unwind(4)]
fn finding_completed_instruction_replay() {
    let fragments = split(7, b"x", HEADER_LEN + 1).unwrap();
    let mut assembly = Assembly::default();
    assert_eq!(assembly.push(Fragment::parse(&fragments[0]).unwrap()).unwrap(), Some(b"x".to_vec()));
    assert!(assembly.push(Fragment::parse(&fragments[0]).unwrap()).unwrap().is_none(),
        "completed instruction replay must not emit again");
}

#[kani::proof]
#[kani::unwind(5)]
fn interleaved_ids_never_mix_payloads() {
    let a: [u8; PAYLOAD] = kani::any();
    let b: [u8; PAYLOAD] = kani::any();
    let id_a: u64 = kani::any();
    let id_b: u64 = kani::any();
    kani::assume(id_a != id_b);
    let a_fragments = split(id_a, &a, HEADER_LEN + 1).unwrap();
    let b_fragments = split(id_b, &b, HEADER_LEN + 1).unwrap();
    let mut assembly = Assembly::default();
    for _ in 0..STEPS {
        let choose_a: bool = kani::any();
        let index = usize::from(kani::any::<u8>());
        kani::assume(index < PAYLOAD);
        let (fragments, expected) = if choose_a { (&a_fragments, &a) } else { (&b_fragments, &b) };
        if let Some(result) = assembly.push(Fragment::parse(&fragments[index]).unwrap()).unwrap() {
            assert_eq!(result, expected, "a completed instruction must contain only its own id's bytes");
        }
    }
}

#[kani::proof]
#[kani::unwind(4)]
fn reyielded_instruction_is_rejected_by_apply_gate() {
    let old = 0;
    let new = 1;
    let mut states = BTreeMap::from([(old, ())]);
    let fragments = split(7, b"x", HEADER_LEN + 1).unwrap();
    let mut assembly = Assembly::default();
    assert!(assembly.push(Fragment::parse(&fragments[0]).unwrap()).unwrap().is_some());
    assert!(crate::state::may_apply(&states, old, new, old).unwrap());
    states.insert(new, ());
    assert!(assembly.push(Fragment::parse(&fragments[0]).unwrap()).unwrap().is_some());
    assert!(!crate::state::may_apply(&states, old, new, old).unwrap(),
        "a retained state number must reject the re-yielded instruction");
}
