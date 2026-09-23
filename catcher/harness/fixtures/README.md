`known-60s.ref.txt` is the P1 word-error-rate target. The wav speaks the passage three times, and the ref is three copies of that passage, in order, for WER.

`known-60s.wav` is a 16 kHz mono PCM16 file (59.99 s) that speaks the passage three times. It replaced the quiet tone loop, git blob `62faa201cfec9ccde054d907eccb34ea9615fc18`. Periods were added between the reference lines so the synthesizer could pause; they are not extra words. One clear pass is about 18.6 s, so three readings fill the minute with no silent gap over two seconds.

Generated with Piper 1.8.0, voice `en_US-lessac-medium`:

```
piper -m en_US-lessac-medium.onnx -c en_US-lessac-medium.onnx.json \
  -i passage.txt -f once.wav \
  --length-scale 1.0 --sentence-silence 0.6 \
  --noise-scale 0.333 --noise-w-scale 0.4 --volume 0.7
ffmpeg -i once.wav -ac 1 -ar 16000 -c:a pcm_s16le once-16k.wav
# once-16k.wav concatenated with itself three times, then:
ffmpeg -i triple.wav -af atempo=0.9288 -ac 1 -ar 16000 -c:a pcm_s16le known-60s.wav
```
