# Bundled sound origin

Every `.wav` file in this directory was generated from scratch by this project using simple
waveform synthesis: sine and square oscillators combined with amplitude envelopes (exponential
decay, linear fade-in, or a frequency sweep for `scifi.wav`), written out as raw 16-bit PCM with
a hand-constructed RIFF/WAVE header. No third-party audio samples, recordings, sound libraries,
or copyrighted material of any kind were used in producing any of these files.

We are not making a stronger legal claim than that — e.g. we are not asserting a specific license
(such as CC0) or warranting originality/non-infringement in a formal sense. The factual claim is
limited to how the files were produced: procedurally generated math, not sampled or copied audio.

## Files

| File | Synthesis |
|---|---|
| `classic.wav` | Sine, 880Hz -> 1318Hz two-tone, exponential decay |
| `chime.wav` | Sine at 1046.5Hz + quiet 2093Hz overtone, slow decay, soft fade-in |
| `soft.wav` | Single sine at 523.25Hz, low amplitude, slow decay, gentle fade-in |
| `alert.wav` | Two sharp 1500Hz sine pulses with a short gap |
| `retro.wav` | Square wave, stepped frequency (440Hz -> 587.33Hz) |
| `magic.wav` | Ascending 4-note sine arpeggio (C6, E6, G6, C7) |
| `digital.wav` | Two very short high-frequency sine blips (2000Hz, 2500Hz) |
| `double.wav` | Two identical 900Hz sine beeps separated by silence |
| `scifi.wav` | Continuous sine frequency sweep, 400Hz -> 1800Hz |
| `success.wav` | Ascending 3-note major arpeggio (C6, E6, G6), warm decay |

Generated at 44100Hz, 16-bit, mono PCM.
