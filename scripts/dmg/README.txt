FrEQ — system-wide parametric EQ + effects for macOS
=======================================================

INSTALL
-------
1. Double-click  "Install FrEQ.command".
2. If macOS says it "cannot be opened because it is from an unidentified
   developer", right-click (or Control-click) the file, choose Open, then
   click Open in the dialog. This is only needed once, and only because this
   build is not signed with an Apple Developer ID.
3. Enter your Mac password when prompted (needed to install the audio driver
   into /Library and restart the audio system — audio will blink for a
   second).

FrEQ then appears as a slider icon in the menu bar.

FIRST RUN
---------
- Click the menu-bar icon > "Open Controls".
- Turn "Enable" on. Grant microphone access when asked — macOS treats the
  virtual audio device's capture as "microphone" use; FrEQ only reads the
  system-audio loopback and never records a real microphone.
- Import a headphone profile in the Equalizer tab (autoeq.app -> choose
  "EqualizerAPO ParametricEq" -> copy, then Import AutoEq > From clipboard),
  or use the Effects tab (bass, clarity, tube, crossfeed, reverb, and more).

UNINSTALL
---------
Double-click "Uninstall FrEQ.command".

REQUIREMENTS
------------
macOS 13 (Ventura) or later. Universal (Apple Silicon + Intel).

Frequency-response correction only. It cannot change Bluetooth codecs
(macOS is SBC/AAC only) or the headset-mic quality drop — those are macOS
limitations, not EQ.
