//! Executed by mosh-resume.py against the actual mosh crate, not a reimplementation.
use std::collections::BTreeMap;
use mosh::state::{may_apply, retain_from};

fn main() {
    let mut zero = BTreeMap::from([(0, ())]);
    retain_from(&mut zero, 0);
    let keep_boundary = zero.contains_key(&0);
    // A single boolean represents the two supported retention policies. Reject
    // every other observed policy rather than silently translating it to TLA+.
    for threshold in 0..=8 {
        let mut states: BTreeMap<_, _> = (0..=8).map(|n| (n, ())).collect();
        retain_from(&mut states, threshold);
        for number in 0..=8 {
            assert_eq!(states.contains_key(&number),
                if keep_boundary { number >= threshold } else { number > threshold },
                "retention changed shape: update the model before claiming a pass");
        }
    }
    for mask in 1u32..32 {
        let states: BTreeMap<_, _> = (0..5).filter(|n| mask & (1 << n) != 0).map(|n| (n, ())).collect();
        for old in 0..5 {
            for new in 0..5 {
                for throwaway in 0..5 {
                    let got = may_apply(&states, old, new, throwaway);
                    if states.contains_key(&new) {
                        assert_eq!(got.unwrap(), false);
                    } else if new <= old || throwaway > old {
                        assert!(matches!(got, Err(mosh::Error::StateOrder)));
                    } else {
                        assert_eq!(got.unwrap(), states.contains_key(&old));
                    }
                }
            }
        }
    }
    for wall in 0..=8 {
        for saved in 0..=8 {
            let got = mosh::resumed_sequence(wall, saved).unwrap();
            assert!(got >= wall && got >= saved && (got == wall || got == saved));
        }
    }
    assert!(matches!(mosh::resumed_sequence(mosh::crypto::SEQUENCE_MAX, 0), Err(mosh::Error::SequenceExhausted)));
    println!("KeepBoundary = {}", if keep_boundary { "TRUE" } else { "FALSE" });
}
