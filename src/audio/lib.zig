pub const pcm = @import("pcm.zig");
pub const capture = @import("capture.zig");
pub const encoder = @import("encoder.zig");
pub const pipeline = @import("pipeline.zig");

pub const AudioRingBuffer = pcm.AudioRingBuffer;
pub const AudioTrackBuffer = pcm.AudioTrackBuffer;
pub const SourceCursor = pcm.SourceCursor;
pub const StreamAlignment = pcm.StreamAlignment;

pub const EventFd = capture.EventFd;
pub const EventSignal = capture.EventSignal;
pub const AudioCapture = capture.AudioCapture;
pub const AudioCaptureError = capture.AudioCaptureError;
pub const AudioProbeReport = capture.AudioProbeReport;
pub const probePulseAudio = capture.probePulseAudio;

pub const AudioEncoder = encoder.AudioEncoder;
pub const EncodedAudioPacket = encoder.EncodedAudioPacket;
pub const AudioEncoderError = encoder.AudioEncoderError;
pub const default_bitrate_bps = encoder.default_bitrate_bps;

pub const AudioSessionMixer = pipeline.AudioSessionMixer;
pub const AudioPipeline = pipeline.AudioPipeline;
pub const AudioPipelineError = pipeline.AudioPipelineError;
pub const AudioStats = pipeline.AudioStats;

test {
    @import("std").testing.refAllDecls(@This());
}
