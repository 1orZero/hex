//! The clip as Dropline gets it: long pauses shortened and silence at the
//! edges trimmed (Derek Voice's `keptPackets`, decided per 20 ms block), then
//! one 24 kbit/s Ogg Opus stream encoded by macOS's own Opus encoder.

mod opus;

pub(super) use opus::ogg_opus;

/// 16 kHz samples in one 20 ms block, the Opus packet the levels describe.
const BLOCK: usize = 320;
/// A block's level: its RMS in dBFS plus this offset, clamped to 0…100.
const LEVEL_OFFSET_DB: f64 = 100.0;
/// The noise floor is this quantile of the clip's levels.
const FLOOR_QUANTILE: f64 = 0.1;
/// Never speech below this level, however quiet the room.
const MIN_SPEECH_DB: f64 = -55.0;
/// Speech separated by less than this is one stretch.
const JOIN_MS: usize = 200;
/// Shorter loud stretches are clicks, not speech.
const MIN_SPEECH_MS: usize = 100;
/// Kept before the first speech and after the last.
const EDGE_MS: usize = 250;
const BLOCK_MS: usize = 20;
/// Speech is this many dB above the noise floor.
const MARGIN_DB: f64 = 6.0;
/// A pause longer than this is shrunk to `KEPT_PAUSE_MS`.
const LONG_PAUSE_MS: usize = 500;
const KEPT_PAUSE_MS: usize = 250;
/// Speech under this share of the clip means the floor was misjudged: keep
/// everything.
const MIN_SPEECH_SHARE: f64 = 0.1;

/// `samples` without the blocks Dropline doesn't need.
pub(super) fn shorten_pauses(samples: &[f32]) -> Vec<f32> {
    let levels: Vec<u8> = samples.chunks(BLOCK).map(level).collect();
    let keep = kept_blocks(&levels);
    samples
        .chunks(BLOCK)
        .zip(keep)
        .filter(|(_, keep)| *keep)
        .flat_map(|(block, _)| block.iter().copied())
        .collect()
}

fn level(block: &[f32]) -> u8 {
    let power = block
        .iter()
        .map(|s| f64::from(*s) * f64::from(*s))
        .sum::<f64>()
        / block.len() as f64;
    let rms = power.sqrt().max(10f64.powf(-LEVEL_OFFSET_DB / 20.0));
    (20.0 * rms.log10() + LEVEL_OFFSET_DB)
        .round()
        .clamp(0.0, LEVEL_OFFSET_DB) as u8
}

/// Whether each block is sent; with no speech found, or too little, every
/// block is, so a quiet or noisy clip is never emptied.
fn kept_blocks(levels: &[u8]) -> Vec<bool> {
    let blocks = levels.len();
    let all = vec![true; blocks];
    if blocks == 0 {
        return all;
    }
    let mut sorted = levels.to_vec();
    sorted.sort_unstable();
    let floor = f64::from(sorted[(FLOOR_QUANTILE * (blocks - 1) as f64).floor() as usize]);
    let threshold = (floor + MARGIN_DB).max(MIN_SPEECH_DB + LEVEL_OFFSET_DB);

    let mut runs: Vec<(usize, usize)> = Vec::new();
    for (index, level) in levels.iter().enumerate() {
        if f64::from(*level) < threshold {
            continue;
        }
        match runs.last_mut() {
            Some(last) if index - last.1 < JOIN_MS / BLOCK_MS => last.1 = index + 1,
            _ => runs.push((index, index + 1)),
        }
    }
    let speech: Vec<(usize, usize)> = runs
        .into_iter()
        .filter(|(start, end)| end - start >= MIN_SPEECH_MS / BLOCK_MS)
        .collect();
    let spoken: usize = speech.iter().map(|(start, end)| end - start).sum();
    if spoken == 0 || (spoken as f64) < MIN_SPEECH_SHARE * blocks as f64 {
        return all;
    }

    let mut keep = vec![false; blocks];
    let mut mark = |from: isize, to: usize| {
        let to = to.min(blocks);
        let from = (from.max(0) as usize).min(to);
        keep[from..to].fill(true);
    };
    let edge = EDGE_MS.div_ceil(BLOCK_MS);
    let half = (KEPT_PAUSE_MS as f64 / BLOCK_MS as f64 / 2.0).round() as usize;
    mark(speech[0].0 as isize - edge as isize, speech[0].0);
    for (index, (start, end)) in speech.iter().enumerate() {
        mark(*start as isize, *end);
        match speech.get(index + 1) {
            None => mark(*end as isize, end + edge),
            Some((next, _)) if (next - end) * BLOCK_MS > LONG_PAUSE_MS => {
                mark(*end as isize, end + half);
                mark((next - half) as isize, *next);
            }
            Some((next, _)) => mark(*end as isize, *next),
        }
    }
    keep
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tone(blocks: usize, amplitude: f32) -> Vec<f32> {
        (0..blocks * BLOCK)
            .map(|index| amplitude * (index as f32 * 0.3).sin())
            .collect()
    }

    #[test]
    fn levels_follow_derek_voices_scale() {
        assert_eq!(level(&[0.0; BLOCK]), 0);
        assert_eq!(level(&[1.0; BLOCK]), 100);
        assert_eq!(level(&[0.01; BLOCK]), 60);
    }

    #[test]
    fn a_long_pause_shrinks_and_the_edges_are_trimmed() {
        // 1 s silence, 1 s speech, 2 s pause, 1 s speech, 1 s silence.
        let mut levels = vec![10_u8; 50];
        levels.extend([80; 50]);
        levels.extend([10; 100]);
        levels.extend([80; 50]);
        levels.extend([10; 50]);
        let keep = kept_blocks(&levels);
        let kept = keep.iter().filter(|keep| **keep).count();
        // Speech, 260 ms (13 whole blocks) at each edge, and the pause cut to
        // 240 ms: six blocks after the first speech and six before the next.
        assert_eq!(kept, 100 + 13 * 2 + 6 * 2);
        assert!(!keep[36] && keep[37] && keep[50]);
        assert!(keep[105] && !keep[106] && !keep[193] && keep[194]);
        assert!(keep[262] && !keep[263]);
    }

    #[test]
    fn a_short_pause_stays_whole() {
        let mut levels = vec![80_u8; 50];
        levels.extend([10; 20]);
        levels.extend([80; 50]);
        let keep = kept_blocks(&levels);
        assert!(keep[50..70].iter().all(|keep| *keep));
    }

    #[test]
    fn silence_or_too_little_speech_keeps_everything() {
        assert!(kept_blocks(&[5; 100]).iter().all(|keep| *keep));
        let mut levels = vec![10_u8; 200];
        levels[100..110].fill(80);
        assert!(kept_blocks(&levels).iter().all(|keep| *keep));
        assert!(kept_blocks(&[]).is_empty());
    }

    #[test]
    fn shortening_drops_whole_blocks_of_samples() {
        let mut samples = tone(50, 0.0001);
        samples.extend(tone(50, 0.3));
        samples.extend(tone(100, 0.0001));
        samples.extend(tone(50, 0.3));
        let kept = shorten_pauses(&samples);
        assert_eq!(kept.len() % BLOCK, 0);
        assert!(kept.len() < samples.len());
        assert!(kept.len() >= 100 * BLOCK);
    }
}
