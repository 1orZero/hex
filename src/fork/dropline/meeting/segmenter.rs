//! Cuts one meeting track into Dropline segments at pauses, as Derek
//! Voice's `MeetingSegmenter` does: once a segment passes seven tenths of
//! its limit, it ends in the middle of the first pause of 0.5 s (25 blocks of
//! 20 ms); at the limit it ends anyway. The pause threshold is the 10%
//! quantile of the first seven tenths' levels plus 6 dB, never below 45
//! (-55 dBFS). Segments never overlap. A jump in the track's position (a
//! capture gap, or audio the fork could not take) ends the segment before
//! it, so no segment spans missing audio. A segment with no block above the
//! same kind of threshold, measured over the whole segment, has no speech.

use super::super::audio::{BLOCK, level};

/// Dropline takes 180 s; Derek Voice stops at 178 s.
pub(super) const LIMIT_BLOCKS: usize = 178_000 / 20;
/// A pause this many blocks long ends a segment.
const PAUSE_BLOCKS: usize = 25;
/// The last segment at Stop is sent only from this many blocks (500 ms).
const SHORTEST_BLOCKS: usize = 25;
/// A block below this level is always a pause, however quiet the room.
const MIN_THRESHOLD: u8 = 45;

/// A segment's audio and its half-open place in the track, in 16 kHz
/// samples of the WAV, capture gaps included.
#[derive(Debug)]
pub(super) struct Cut {
    pub start: u64,
    pub end: u64,
    pub samples: Vec<f32>,
    pub speech: bool,
}

pub(super) struct Segmenter {
    limit: usize,
    start: u64,
    samples: Vec<f32>,
    levels: Vec<u8>,
    threshold: Option<u8>,
    scanned: usize,
    quiet: usize,
    next: Option<u64>,
}

impl Segmenter {
    pub(super) fn new(limit_blocks: usize) -> Self {
        Self {
            limit: limit_blocks,
            start: 0,
            samples: Vec::new(),
            levels: Vec::new(),
            threshold: None,
            scanned: 0,
            quiet: 0,
            next: None,
        }
    }

    /// Takes 16 kHz samples that start at `position` in the track and
    /// returns the segments they complete.
    pub(super) fn push(&mut self, position: u64, samples: &[f32]) -> Vec<Cut> {
        let mut cuts = Vec::new();
        if self.next.is_some_and(|next| next != position) {
            cuts.extend(self.finish());
        }
        if self.samples.is_empty() {
            self.start = position;
        }
        self.next = Some(position + samples.len() as u64);
        let measured = self.levels.len() * BLOCK;
        self.samples.extend_from_slice(samples);
        self.levels.extend(
            self.samples[measured..]
                .as_chunks::<BLOCK>()
                .0
                .iter()
                .map(|block| level(block)),
        );
        while let Some(blocks) = self.next_cut() {
            let samples = self.samples.drain(..blocks * BLOCK).collect::<Vec<_>>();
            self.levels.drain(..blocks);
            cuts.push(self.cut(samples));
            self.threshold = None;
            self.scanned = 0;
            self.quiet = 0;
        }
        cuts
    }

    /// The rest of the track, as at Stop or before a gap: a segment when it
    /// lasts 500 ms or more.
    pub(super) fn finish(&mut self) -> Option<Cut> {
        let samples = std::mem::take(&mut self.samples);
        self.levels.clear();
        self.threshold = None;
        self.scanned = 0;
        self.quiet = 0;
        self.next = None;
        (samples.len() >= SHORTEST_BLOCKS * BLOCK).then(|| self.cut(samples))
    }

    fn cut(&mut self, samples: Vec<f32>) -> Cut {
        let start = self.start;
        self.start += samples.len() as u64;
        let levels = samples.chunks(BLOCK).map(level).collect::<Vec<_>>();
        let speech = levels.iter().any(|level| *level >= threshold(&levels));
        Cut {
            start,
            end: self.start,
            samples,
            speech,
        }
    }

    /// How many blocks the next segment takes, once it is decided.
    fn next_cut(&mut self) -> Option<usize> {
        let shortest = self.limit * 7 / 10;
        if self.levels.len() <= shortest {
            return None;
        }
        let threshold = *self
            .threshold
            .get_or_insert_with(|| threshold(&self.levels[..shortest]));
        let mut index = shortest.max(self.scanned);
        while index < self.levels.len().min(self.limit) {
            self.quiet = if self.levels[index] < threshold {
                self.quiet + 1
            } else {
                0
            };
            if self.quiet == PAUSE_BLOCKS {
                return Some(index - PAUSE_BLOCKS / 2);
            }
            index += 1;
        }
        self.scanned = index;
        (self.levels.len() >= self.limit).then_some(self.limit)
    }
}

/// The 10% quantile of `levels` plus 6 dB, never below the floor.
fn threshold(levels: &[u8]) -> u8 {
    let mut sorted = levels.to_vec();
    sorted.sort_unstable();
    sorted
        .get(sorted.len().saturating_sub(1) / 10)
        .copied()
        .unwrap_or(0)
        .saturating_add(6)
        .max(MIN_THRESHOLD)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `blocks` of 20 ms: speech, loud with two softer blocks in every ten
    /// as between words, or quiet below every threshold.
    fn audio(blocks: usize, loud: bool) -> Vec<f32> {
        (0..blocks * BLOCK)
            .map(|index| {
                let amplitude = match (loud, index / BLOCK % 10) {
                    (false, _) => 0.0001,
                    (true, 4 | 5) => 0.01,
                    (true, _) => 0.3,
                };
                amplitude * (index as f32 * 0.3).sin()
            })
            .collect()
    }

    fn feed(segmenter: &mut Segmenter, position: &mut u64, samples: &[f32]) -> Vec<Cut> {
        let mut cuts = Vec::new();
        for packet in samples.chunks(160) {
            cuts.extend(segmenter.push(*position, packet));
            *position += packet.len() as u64;
        }
        cuts
    }

    fn ranges(cuts: &[Cut]) -> Vec<(u64, u64)> {
        cuts.iter().map(|cut| (cut.start, cut.end)).collect()
    }

    const B: u64 = BLOCK as u64;

    #[test]
    fn a_segment_ends_in_the_middle_of_the_first_pause_after_seven_tenths() {
        // Limit 120 blocks: from block 84 on, a 25-block pause ends it.
        let mut segmenter = Segmenter::new(120);
        let mut position = 0;
        let mut track = audio(60, true);
        track.extend(audio(20, false)); // too early to count
        track.extend(audio(5, true));
        track.extend(audio(30, false)); // blocks 85..115
        track.extend(audio(40, true));
        let cuts = feed(&mut segmenter, &mut position, &track);
        // The pause reaches 25 blocks at block 109; the cut is 12 earlier.
        assert_eq!(ranges(&cuts), [(0, 97 * B)]);
        assert_eq!(cuts[0].samples, track[..97 * BLOCK]);
        let tail = segmenter.finish().unwrap();
        assert_eq!((tail.start, tail.end), (97 * B, 155 * B));
        assert_eq!(tail.samples, track[97 * BLOCK..]);
    }

    #[test]
    fn speech_without_a_pause_is_cut_at_the_limit() {
        let mut segmenter = Segmenter::new(100);
        let mut position = 0;
        let cuts = feed(&mut segmenter, &mut position, &audio(250, true));
        assert_eq!(ranges(&cuts), [(0, 100 * B), (100 * B, 200 * B)]);
        assert_eq!(
            segmenter.finish().map(|cut| (cut.start, cut.end)),
            Some((200 * B, 250 * B))
        );
    }

    #[test]
    fn the_real_limit_is_178_seconds_and_cuts_hold_every_sample_once() {
        let mut segmenter = Segmenter::new(LIMIT_BLOCKS);
        let mut position = 0;
        let track = audio(LIMIT_BLOCKS * 2 + 30, true);
        let mut cuts = feed(&mut segmenter, &mut position, &track);
        cuts.extend(segmenter.finish());
        assert_eq!(cuts[0].end, 178 * 16_000);
        let mut joined = Vec::new();
        let mut at = 0;
        for cut in &cuts {
            assert_eq!(cut.start, at);
            assert_eq!(cut.end - cut.start, cut.samples.len() as u64);
            assert!(cut.samples.len() <= 178 * 16_000);
            at = cut.end;
            joined.extend_from_slice(&cut.samples);
        }
        assert_eq!(cuts.len(), 3);
        assert!(
            joined == track,
            "{} of {} samples",
            joined.len(),
            track.len()
        );
    }

    #[test]
    fn a_tail_shorter_than_500_ms_is_not_sent() {
        let mut segmenter = Segmenter::new(100);
        let mut position = 0;
        feed(&mut segmenter, &mut position, &audio(24, true));
        assert!(segmenter.finish().is_none());
        feed(&mut segmenter, &mut position, &audio(25, true));
        let tail = segmenter.finish().unwrap();
        assert_eq!((tail.start, tail.end), (24 * B, 49 * B));
    }

    #[test]
    fn a_gap_ends_the_segment_before_it_and_keeps_track_positions() {
        let mut segmenter = Segmenter::new(100);
        let mut position = 1_000;
        let mut cuts = feed(&mut segmenter, &mut position, &audio(40, true));
        assert!(cuts.is_empty());
        // Two seconds the writer padded, or packets the fork lost.
        position += 32_000;
        cuts.extend(feed(&mut segmenter, &mut position, &audio(10, true)));
        assert_eq!(ranges(&cuts), [(1_000, 1_000 + 40 * B)]);
        // A short piece before a gap is dropped like a short tail.
        position += 16_000;
        cuts.extend(feed(&mut segmenter, &mut position, &audio(30, true)));
        assert_eq!(cuts.len(), 1);
        let tail = segmenter.finish().unwrap();
        let resumed = 1_000 + 40 * B + 32_000 + 10 * B + 16_000;
        assert_eq!((tail.start, tail.end), (resumed, resumed + 30 * B));
    }

    #[test]
    fn a_segment_without_a_loud_block_has_no_speech() {
        let mut segmenter = Segmenter::new(100);
        let mut position = 0;
        feed(&mut segmenter, &mut position, &audio(40, false));
        assert!(!segmenter.finish().unwrap().speech);
        let mut track = audio(30, false);
        track.extend(audio(10, true));
        feed(&mut segmenter, &mut position, &track);
        assert!(segmenter.finish().unwrap().speech);
        // A steady hum above the floor is not speech either.
        let hum = (0..40 * BLOCK)
            .map(|index| 0.01 * (index as f32 * 0.3).sin())
            .collect::<Vec<f32>>();
        feed(&mut segmenter, &mut position, &hum);
        assert!(!segmenter.finish().unwrap().speech);
    }

    #[test]
    fn a_hum_above_the_floor_still_counts_as_a_pause() {
        // A hum at level ~47, above the floor of 45: the threshold follows
        // the speech's softest blocks (60), so the hum is a pause.
        let floor = |blocks| {
            (0..blocks * BLOCK)
                .map(|index| 0.003 * (index as f32 * 0.3).sin())
                .collect::<Vec<f32>>()
        };
        let mut segmenter = Segmenter::new(100);
        let mut position = 0;
        let mut track = audio(73, true);
        track.extend(floor(30));
        let cuts = feed(&mut segmenter, &mut position, &track);
        // The hum starts at block 73 and is a pause at block 97.
        assert_eq!(
            ranges(&cuts),
            [(0, 85 * B)],
            "levels {:?}",
            segmenter.levels
        );
    }
}
