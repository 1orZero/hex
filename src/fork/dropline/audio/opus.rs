//! One Ogg Opus file (RFC 7845) from 16 kHz mono samples, through
//! AudioToolbox's Opus encoder: 20 ms packets at 24 kbit/s, as Derek Voice's
//! `OpusOggEncoder` writes them.

use std::ffi::c_void;

const SAMPLE_RATE: f64 = 16_000.0;
const FRAMES_PER_PACKET: u32 = 320;
/// Ogg Opus granules run at 48 kHz: three per 16 kHz sample.
const GRANULES_PER_FRAME: u64 = 3;
const PACKET_GRANULES: u64 = 960;
const BIT_RATE: u32 = 24_000;
const PACKETS_PER_PAGE: usize = 10;

const fn four_cc(code: &[u8; 4]) -> u32 {
    u32::from_be_bytes(*code)
}

const FORMAT_LINEAR_PCM: u32 = four_cc(b"lpcm");
const FORMAT_OPUS: u32 = four_cc(b"opus");
const FLAG_FLOAT_PACKED: u32 = 1 | 8;
const PROPERTY_BIT_RATE: u32 = four_cc(b"brat");
const PROPERTY_PRIME_INFO: u32 = four_cc(b"prim");
const PROPERTY_MAX_PACKET: u32 = four_cc(b"xops");

#[repr(C)]
#[derive(Default)]
struct StreamDescription {
    sample_rate: f64,
    format_id: u32,
    format_flags: u32,
    bytes_per_packet: u32,
    frames_per_packet: u32,
    bytes_per_frame: u32,
    channels_per_frame: u32,
    bits_per_channel: u32,
    reserved: u32,
}

#[repr(C)]
struct Buffer {
    channels: u32,
    byte_size: u32,
    data: *mut c_void,
}

#[repr(C)]
struct BufferList {
    count: u32,
    buffers: [Buffer; 1],
}

#[repr(C)]
#[derive(Default, Clone, Copy)]
struct PacketDescription {
    start_offset: i64,
    variable_frames: u32,
    byte_size: u32,
}

#[repr(C)]
#[derive(Default)]
struct PrimeInfo {
    leading_frames: u32,
    trailing_frames: u32,
}

type Converter = *mut c_void;
type InputProc = unsafe extern "C" fn(
    Converter,
    *mut u32,
    *mut BufferList,
    *mut *mut PacketDescription,
    *mut c_void,
) -> i32;

#[link(name = "AudioToolbox", kind = "framework")]
unsafe extern "C" {
    fn AudioConverterNew(
        source: *const StreamDescription,
        destination: *const StreamDescription,
        converter: *mut Converter,
    ) -> i32;
    fn AudioConverterDispose(converter: Converter) -> i32;
    fn AudioConverterSetProperty(
        converter: Converter,
        id: u32,
        size: u32,
        data: *const c_void,
    ) -> i32;
    fn AudioConverterGetProperty(
        converter: Converter,
        id: u32,
        size: *mut u32,
        data: *mut c_void,
    ) -> i32;
    fn AudioConverterFillComplexBuffer(
        converter: Converter,
        input: InputProc,
        user: *mut c_void,
        packets: *mut u32,
        output: *mut BufferList,
        descriptions: *mut PacketDescription,
    ) -> i32;
}

/// The samples the input callback hands over, in order.
struct Input<'a> {
    samples: &'a [f32],
    next: usize,
}

unsafe extern "C" fn supply(
    _converter: Converter,
    packets: *mut u32,
    data: *mut BufferList,
    _descriptions: *mut *mut PacketDescription,
    user: *mut c_void,
) -> i32 {
    // SAFETY: `user` is the `Input` `encode_packets` passes for this call,
    // alive and unaliased while AudioConverterFillComplexBuffer runs.
    let input = unsafe { &mut *user.cast::<Input>() };
    let left = input.samples.len() - input.next;
    // SAFETY: AudioToolbox passes valid pointers for the requested count
    // and a buffer list with one buffer for mono input.
    unsafe {
        let count = left.min(*packets as usize);
        *packets = count as u32;
        let buffer = &mut (*data).buffers[0];
        buffer.channels = 1;
        buffer.byte_size = (count * 4) as u32;
        // Zero frames with no error is the end of the stream.
        buffer.data = input.samples[input.next..].as_ptr().cast_mut().cast();
        input.next += count;
    }
    0
}

/// `samples` (16 kHz mono) as a complete Ogg Opus file.
pub(in crate::fork::dropline) fn ogg_opus(samples: &[f32]) -> Result<Vec<u8>, String> {
    if samples.is_empty() {
        return Err("沒有錄音".into());
    }
    let (packets, pre_skip) = encode_packets(samples)?;
    let end = samples.len() as u64 * GRANULES_PER_FRAME + u64::from(pre_skip);
    let encoded = packets.len() as u64 * PACKET_GRANULES;
    if encoded < end {
        return Err("編碼器少給了結尾".into());
    }
    Ok(ogg(&packets, pre_skip, end))
}

/// Every 20 ms Opus packet, and the encoder's delay in 48 kHz granules.
fn encode_packets(samples: &[f32]) -> Result<(Vec<Vec<u8>>, u16), String> {
    let source = StreamDescription {
        sample_rate: SAMPLE_RATE,
        format_id: FORMAT_LINEAR_PCM,
        format_flags: FLAG_FLOAT_PACKED,
        bytes_per_packet: 4,
        frames_per_packet: 1,
        bytes_per_frame: 4,
        channels_per_frame: 1,
        bits_per_channel: 32,
        reserved: 0,
    };
    let destination = StreamDescription {
        sample_rate: SAMPLE_RATE,
        format_id: FORMAT_OPUS,
        frames_per_packet: FRAMES_PER_PACKET,
        channels_per_frame: 1,
        ..StreamDescription::default()
    };
    let mut converter: Converter = std::ptr::null_mut();
    // SAFETY: both descriptions are valid for the call; `converter` receives
    // a new converter that `Owned` disposes of.
    let status = unsafe { AudioConverterNew(&source, &destination, &mut converter) };
    if status != 0 || converter.is_null() {
        return Err(format!("沒有 Opus 編碼器（{status}）"));
    }
    let converter = Owned(converter);
    // SAFETY: the converter is live; each property's size matches its type.
    unsafe {
        let rate = BIT_RATE;
        let status = AudioConverterSetProperty(
            converter.0,
            PROPERTY_BIT_RATE,
            size_of::<u32>() as u32,
            (&raw const rate).cast(),
        );
        if status != 0 {
            return Err(format!("無法設定位元率（{status}）"));
        }
    }
    let mut prime = PrimeInfo::default();
    let mut size = size_of::<PrimeInfo>() as u32;
    // SAFETY: as above; `prime` holds `size` bytes.
    let status = unsafe {
        AudioConverterGetProperty(
            converter.0,
            PROPERTY_PRIME_INFO,
            &mut size,
            (&raw mut prime).cast(),
        )
    };
    let pre_skip = if status == 0 {
        u64::from(prime.leading_frames) * GRANULES_PER_FRAME
    } else {
        0
    };
    let pre_skip = u16::try_from(pre_skip).map_err(|_| "編碼器延遲太長".to_owned())?;
    let mut max_packet: u32 = 0;
    let mut size = size_of::<u32>() as u32;
    // SAFETY: as above.
    let status = unsafe {
        AudioConverterGetProperty(
            converter.0,
            PROPERTY_MAX_PACKET,
            &mut size,
            (&raw mut max_packet).cast(),
        )
    };
    if status != 0 || max_packet == 0 {
        return Err(format!("無法讀取封包大小（{status}）"));
    }

    let mut input = Input { samples, next: 0 };
    let mut output = vec![0_u8; max_packet as usize];
    let mut packets = Vec::with_capacity(samples.len() / FRAMES_PER_PACKET as usize + 4);
    loop {
        let mut list = BufferList {
            count: 1,
            buffers: [Buffer {
                channels: 1,
                byte_size: max_packet,
                data: output.as_mut_ptr().cast(),
            }],
        };
        let mut description = PacketDescription::default();
        let mut count: u32 = 1;
        // SAFETY: the converter is live, `input` outlives the call, and the
        // output buffer and description hold one packet of `max_packet` bytes.
        let status = unsafe {
            AudioConverterFillComplexBuffer(
                converter.0,
                supply,
                (&raw mut input).cast(),
                &mut count,
                &mut list,
                &mut description,
            )
        };
        if status != 0 {
            return Err(format!("編碼失敗（{status}）"));
        }
        if count == 0 {
            break;
        }
        let start =
            usize::try_from(description.start_offset).map_err(|_| "封包位置不對".to_owned())?;
        let end = start + description.byte_size as usize;
        let packet = output.get(start..end).filter(|packet| !packet.is_empty());
        let packet = packet.ok_or_else(|| "封包大小不對".to_owned())?;
        if packet_granules(packet) != PACKET_GRANULES {
            return Err("封包不是 20 ms".into());
        }
        packets.push(packet.to_vec());
    }
    Ok((packets, pre_skip))
}

struct Owned(Converter);

impl Drop for Owned {
    fn drop(&mut self) {
        // SAFETY: the converter came from AudioConverterNew and is disposed once.
        unsafe {
            AudioConverterDispose(self.0);
        }
    }
}

/// The packet's length in 48 kHz granules, from its TOC byte (RFC 6716 §3.1).
fn packet_granules(packet: &[u8]) -> u64 {
    let config = packet[0] >> 3;
    let frame: u64 = if config >= 16 {
        120 << (config & 3)
    } else if config >= 12 {
        480 << (config & 1)
    } else if config & 3 == 3 {
        2880
    } else {
        480 << (config & 3)
    };
    let count = match packet[0] & 3 {
        0 => 1,
        3 => packet.get(1).map_or(0, |byte| u64::from(byte & 63)),
        _ => 2,
    };
    frame * count
}

/// The Ogg pages: OpusHead, OpusTags, then the packets ten to a page, the
/// last page ending the stream at `end`.
fn ogg(packets: &[Vec<u8>], pre_skip: u16, end: u64) -> Vec<u8> {
    let serial = {
        let mut bytes = [0_u8; 4];
        let _ = getrandom::fill(&mut bytes);
        u32::from_le_bytes(bytes)
    };
    let mut writer = Pages {
        serial,
        sequence: 0,
        out: Vec::new(),
    };
    let mut head = b"OpusHead".to_vec();
    head.extend([1, 1]);
    head.extend(pre_skip.to_le_bytes());
    head.extend(16_000_u32.to_le_bytes());
    head.extend(0_u16.to_le_bytes());
    head.push(0);
    writer.page(2, 0, &[head.as_slice()]);
    let vendor = b"Hex";
    let mut tags = b"OpusTags".to_vec();
    tags.extend((vendor.len() as u32).to_le_bytes());
    tags.extend(vendor);
    tags.extend(0_u32.to_le_bytes());
    writer.page(0, 0, &[tags.as_slice()]);
    let pages: Vec<&[Vec<u8>]> = packets.chunks(PACKETS_PER_PAGE).collect();
    let mut granule = 0;
    for (index, page) in pages.iter().enumerate() {
        granule += page.len() as u64 * PACKET_GRANULES;
        let last = index + 1 == pages.len();
        let packets: Vec<&[u8]> = page.iter().map(Vec::as_slice).collect();
        writer.page(
            if last { 4 } else { 0 },
            if last { end } else { granule },
            &packets,
        );
    }
    writer.out
}

struct Pages {
    serial: u32,
    sequence: u32,
    out: Vec<u8>,
}

impl Pages {
    fn page(&mut self, flags: u8, granule: u64, packets: &[&[u8]]) {
        let mut lacing = Vec::new();
        for packet in packets {
            let mut left = packet.len();
            while left >= 255 {
                lacing.push(255);
                left -= 255;
            }
            lacing.push(left as u8);
        }
        let start = self.out.len();
        self.out.extend(b"OggS");
        self.out.extend([0, flags]);
        self.out.extend(granule.to_le_bytes());
        self.out.extend(self.serial.to_le_bytes());
        self.out.extend(self.sequence.to_le_bytes());
        self.out.extend([0; 4]);
        self.out.push(lacing.len() as u8);
        self.out.extend(&lacing);
        for packet in packets {
            self.out.extend(*packet);
        }
        let crc = crc(&self.out[start..]);
        self.out[start + 22..start + 26].copy_from_slice(&crc.to_le_bytes());
        self.sequence += 1;
    }
}

/// Ogg's CRC-32 (polynomial 0x04c11db7, no reflection, zero start).
fn crc(bytes: &[u8]) -> u32 {
    bytes.iter().fold(0_u32, |crc, byte| {
        let mut value = (crc >> 24 ^ u32::from(*byte)) << 24;
        for _ in 0..8 {
            value = if value & 0x8000_0000 == 0 {
                value << 1
            } else {
                (value << 1) ^ 0x04c1_1db7
            };
        }
        (crc << 8) ^ value
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The Ogg pages of `file`: (flags, granule, sequence, payload).
    fn pages(file: &[u8]) -> Vec<(u8, u64, u32, Vec<u8>)> {
        let mut pages = Vec::new();
        let mut at = 0;
        while at < file.len() {
            assert_eq!(&file[at..at + 4], b"OggS");
            let flags = file[at + 5];
            let granule = u64::from_le_bytes(file[at + 6..at + 14].try_into().unwrap());
            let sequence = u32::from_le_bytes(file[at + 18..at + 22].try_into().unwrap());
            let stored = u32::from_le_bytes(file[at + 22..at + 26].try_into().unwrap());
            let segments = file[at + 26] as usize;
            let length: usize = file[at + 27..at + 27 + segments]
                .iter()
                .map(|l| *l as usize)
                .sum();
            let end = at + 27 + segments + length;
            let mut page = file[at..end].to_vec();
            page[22..26].fill(0);
            assert_eq!(crc(&page), stored, "page {sequence}'s CRC");
            pages.push((
                flags,
                granule,
                sequence,
                file[at + 27 + segments..end].to_vec(),
            ));
            at = end;
        }
        pages
    }

    #[test]
    fn the_crc_matches_oggs_reference() {
        assert_eq!(crc(b"123456789"), 0x89a1_897f);
        assert_eq!(crc(&[]), 0);
    }

    #[test]
    fn toc_bytes_give_twenty_ms_only_for_twenty_ms_packets() {
        // SILK wideband 20 ms (config 9), CELT wideband 20 ms (config 23),
        // and a 10 ms CELT packet (config 22).
        assert_eq!(packet_granules(&[9 << 3]), 960);
        assert_eq!(packet_granules(&[23 << 3]), 960);
        assert_eq!(packet_granules(&[22 << 3]), 480);
        assert_eq!(packet_granules(&[(22 << 3) | 1]), 960);
    }

    #[test]
    fn a_clip_encodes_as_a_complete_ogg_opus_file() {
        let samples: Vec<f32> = (0..16_000 * 3 + 123)
            .map(|index| 0.2 * (index as f32 * 0.05).sin())
            .collect();
        let file = ogg_opus(&samples).unwrap();
        let pages = pages(&file);
        assert!(pages.len() >= 3);
        assert_eq!(pages[0].0, 2);
        assert!(pages[0].3.starts_with(b"OpusHead"));
        assert_eq!(
            u32::from_le_bytes(pages[0].3[12..16].try_into().unwrap()),
            16_000
        );
        assert!(pages[1].3.starts_with(b"OpusTags"));
        let last = pages.last().unwrap();
        assert_eq!(last.0, 4);
        let pre_skip = u64::from(u16::from_le_bytes(pages[0].3[10..12].try_into().unwrap()));
        assert_eq!(last.1, samples.len() as u64 * 3 + pre_skip);
        assert!(pages.windows(2).all(|pair| pair[1].2 == pair[0].2 + 1));
        assert!(
            pages[2..pages.len() - 1]
                .iter()
                .all(|page| page.1 % PACKET_GRANULES == 0)
        );
        // 24 kbit/s: three seconds is a few kilobytes, not raw PCM's 96.
        assert!(file.len() < 16_000, "{} bytes", file.len());
    }

    unsafe extern "C" {
        fn hex_meeting_import_decode(
            input: *const std::ffi::c_char,
            output: *const std::ffi::c_char,
            cancelled: extern "C" fn() -> std::ffi::c_int,
            error: *mut *mut std::ffi::c_char,
        ) -> i32;
    }

    extern "C" fn never_cancelled() -> std::ffi::c_int {
        0
    }

    /// Core Audio reads Ogg Opus; meeting import's decoder turns the file
    /// into the 16 kHz mono WAV it was encoded from.
    #[test]
    fn core_audio_decodes_the_file_back() {
        let samples: Vec<f32> = (0..16_000 * 2)
            .map(|index| 0.3 * (index as f32 * 2.0 * std::f32::consts::PI * 440.0 / 16_000.0).sin())
            .collect();
        let file = ogg_opus(&samples).unwrap();
        let folder = std::env::temp_dir().join(format!("qa-hex-dropline-{}", std::process::id()));
        std::fs::create_dir_all(&folder).unwrap();
        let ogg = folder.join("qa-recording.ogg");
        let wav = folder.join("qa-recording.wav");
        std::fs::write(&ogg, &file).unwrap();
        let path = |path: &std::path::Path| std::ffi::CString::new(path.to_str().unwrap()).unwrap();
        let mut error = std::ptr::null_mut();
        let status = unsafe {
            hex_meeting_import_decode(
                path(&ogg).as_ptr(),
                path(&wav).as_ptr(),
                never_cancelled,
                &mut error,
            )
        };
        assert_eq!(status, 0, "Core Audio could not decode the file");
        let decoded: Vec<f32> = hound::WavReader::open(&wav)
            .unwrap()
            .samples::<f32>()
            .map(Result::unwrap)
            .collect();
        std::fs::remove_dir_all(&folder).unwrap();
        let difference = decoded.len().abs_diff(samples.len());
        assert!(
            difference < 320,
            "{} decoded, {} encoded",
            decoded.len(),
            samples.len()
        );
        let energy =
            |samples: &[f32]| samples.iter().map(|s| s * s).sum::<f32>() / samples.len() as f32;
        let ratio = energy(&decoded) / energy(&samples);
        assert!((0.7..1.3).contains(&ratio), "energy ratio {ratio}");
    }

    #[test]
    fn no_samples_is_an_error() {
        assert!(ogg_opus(&[]).is_err());
    }
}
