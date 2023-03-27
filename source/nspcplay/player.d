module nspcplay.player;

import nspcplay.common;
import nspcplay.song;
import nspcplay.sequence;
import nspcplay.samples;

import std.algorithm.comparison;
import std.exception;
import std.experimental.logger;
import std.format;
import std.typecons;

enum uint nativeSamplingRate = 32000;

private enum left = 0;
private enum right = 1;
private struct SongState {
	byte masterVolumeLeft = 112;
	byte masterVolumeRight = 112;
	ChannelState[] channels;
	byte transpose;
	Slider volume = Slider(0xC000);
	Slider tempo;
	int nextTimerTick;
	int cycleTimer = 255;
	ubyte percussionBase; // set with FA
	ubyte repeatCount;
	int phraseCounter = -1;

	bool echoEnabled;
	Slider echoVolumeLeft;
	Slider echoVolumeRight;
	ushort echoBufferSize = 1;
	byte echoFeedbackVolume;
	ushort echoBufferIndex;
	ubyte firBufferIndex;
	short[2][7680] echoBuffer;
	const(byte)[] firCoefficients;
	short[2][8] firHistory;
	bool enchantedReadahead = true; //this is a bug that existed in the prototype, and optionally by addmusick
	//amk state
	bool amkFixSampleLoadTuning;
	bool useAltRTable;
}

private struct Slider {
	ushort current;
	ushort delta;
	ubyte cycles;
	ubyte target;

	private void slide() nothrow @safe pure {
		if (cycles) {
			if (--cycles == 0) {
				current = target << 8;
			} else {
				current += delta;
			}
		}
	}
}

enum ADSRPhase {
	attack,
	decay,
	sustain,
	gain,
	release
}

private struct ChannelState {
	bool enabled = true;
	int next; // time left in note

	Slider note;
	ubyte currentPortStartCounter;
	ubyte noteLength;
	ubyte noteStyle;

	ubyte noteRelease; // time to release note, in cycles

	Parser parser;

	ubyte instrument; // instrument
	ADSRGain instrumentADSRGain;
	ubyte finetune;
	byte transpose;
	Slider panning = Slider(0x0A00);
	ubyte panFlags;
	Slider volume = Slider(0xFF00);
	ubyte totalVolume;
	byte leftVolume;
	byte rightVolume;

	ubyte portType;
	ubyte portStart;
	ubyte portLength;
	ubyte portRange;
	ubyte vibratoStart;
	ubyte vibratoSpeed;
	ubyte vibratoMaxRange;
	ubyte vibratoFadeIn;
	ubyte tremoloStart;
	ubyte tremoloSpeed;
	ubyte tremoloRange;

	ubyte vibratoPhase;
	ubyte vibratoStartCounter;
	ubyte currentVibratoRange;
	ubyte vibratoFadeInCounter;
	ubyte vibratoRangeDelta;
	ubyte tremoloPhase;
	ubyte tremoloStartCounter;

	ubyte sampleID;
	int samplePosition = -1;
	int noteFrequency;

	short gain;
	ADSRPhase adsrPhase;
	ushort adsrCounter;
	ubyte adsrRate;

	short[8] interpolationBuffer;
	short[2] echoSamples;

	bool echoEnabled;

	// Konami-specific state
	ushort loopStart;
	ushort loopCount;
	ubyte noteDelta; //TODO: implement this. what unit does this use?
	ubyte volumeDelta; //ditto
	// AMK specific state
	Nullable!ushort tuningOverride;
	ushort semitoneTune;
	ubyte volumeBoost;
	ushort[ubyte] remotes;
	// Pseudo VCMD state
	Nullable!ubyte releaseOverride;
	void setADSRPhase(ADSRPhase phase) @safe pure nothrow {
		adsrCounter = 0;
		adsrPhase = phase;
		final switch (phase) {
			case ADSRPhase.attack:
				adsrRate = cast(ubyte)(instrumentADSRGain.attackRate * 2 + 1);
				break;
			case ADSRPhase.decay:
				adsrRate = cast(ubyte)(instrumentADSRGain.decayRate * 2 + 16);
				break;
			case ADSRPhase.sustain:
				adsrRate = instrumentADSRGain.sustainRate;
				break;
			case ADSRPhase.gain:
				if (instrumentADSRGain.mode == ADSRGainMode.customGain) {
					adsrRate = instrumentADSRGain.gainRate;
				}
				assert(instrumentADSRGain.mode != ADSRGainMode.adsr);
				break;
			case ADSRPhase.release:
				adsrRate = 31;
				break;
		}
	}
}

private struct Parser {
	const(Command)[] sequenceData;
	/// the sequence data that will be restored upon return from subroutine
	const(Command)[] subroutineReturnData;
	/// Starting address of the subroutine
	ushort subroutineStartAddress;
	/// Number of times to repeat the subroutine
	ubyte subroutineCount;
	/// Sequence data at  the start of a loop
	const(Command)[] loopStart;
	/// Number of times to loop
	ubyte loopCount = 0xFF;
	bool empty() const @safe pure nothrow {
		return sequenceData.length == 0;
	}
	Command popCommand(const Song song) nothrow @safe pure {
		bool _;
		return popCommand(song, _);
	}
	Command popCommand(const Song song, out bool done, bool followSubroutines = true) nothrow @safe pure {
		const command = sequenceData[0];
		if (command.type == VCMDClass.terminator) {
			done = subroutineCount == 0;
			if (!done) {
				sequenceData = --subroutineCount ? song.tracks[subroutineStartAddress] : subroutineReturnData;
			}
		} else if ((command.type == VCMDClass.special) && (command.special == VCMD.konamiLoopStart)) {
			sequenceData = sequenceData[1 .. $];
			loopStart = sequenceData[];
		} else if ((command.type == VCMDClass.special) && (command.special == VCMD.amkSubloop)) {
			if (command.parameters[0] == 0) {
				sequenceData = sequenceData[1 .. $];
				loopStart = sequenceData[];
			} else {
				if (loopCount == 0xFF) {
					loopCount = cast(ubyte)(command.parameters[0]);
				}
				if (loopCount > 0) {
					sequenceData = loopStart;
					loopCount--;
				} else {
					loopCount = 0xFF;
					sequenceData = sequenceData[1 .. $];
				}
			}
		} else if ((command.type == VCMDClass.special) && (command.special == VCMD.konamiLoopEnd)) {
			if (loopCount == 0xFF) {
				loopCount = cast(ubyte)(command.parameters[0] - 1);
			}
			if (loopCount > 0) {
				sequenceData = loopStart;
				loopCount--;
			} else {
				loopCount = 0xFF;
				sequenceData = sequenceData[1 .. $];
			}
		} else if (followSubroutines && (command.type == VCMDClass.special) && (command.special == VCMD.subRoutine)) {
			subroutineReturnData = sequenceData[1 .. $];
			subroutineStartAddress = read!ushort(command.parameters);
			subroutineCount = command.parameters[2];
			sequenceData = song.tracks[subroutineStartAddress];
		} else {
			sequenceData = sequenceData[1 .. $];
		}
		return command;
	}
}

// Rates (in samples) until next step is applied
private immutable adsrGainRates = [ 0, 2048, 1536, 1280, 1024, 768, 640, 512, 384, 320, 256, 192, 160, 128, 96, 80, 64, 48, 40, 32, 24, 20, 16, 12, 10, 8, 6, 5, 4, 3, 2, 1 ];

void doADSR(ref ChannelState channel) nothrow @safe pure {
	ushort level() {
		return cast(ushort)(((channel.gain - 1) >> 8) + 1);
	}
	final switch (channel.adsrPhase) {
		case ADSRPhase.attack:
			channel.gain += (channel.adsrRate == 31) ? 1024 : 32;
			if (channel.gain > 0x7E0) {
				channel.setADSRPhase(ADSRPhase.decay);
			}
			break;
		case ADSRPhase.decay:
			channel.gain -= level;
			if (channel.gain < channel.instrumentADSRGain.sustainLevel) {
				channel.setADSRPhase(ADSRPhase.sustain);
			}
			break;
		case ADSRPhase.sustain:
			channel.gain -= level;
			break;
		case ADSRPhase.gain:
			final switch(channel.instrumentADSRGain.gainMode) {
				case GainMode.linearDecreaseGain:
					channel.gain -= 32;
					break;
				case GainMode.expDecreaseGain:
					channel.gain -= level;
					break;
				case GainMode.linearIncreaseGain:
					channel.gain += 32;
					break;
				case GainMode.bentIncreaseGain:
					channel.gain +=  (channel.gain < 0x600) ? 32 : 8;
					break;
			}
			break;
		case ADSRPhase.release:
			channel.gain -= 8;
			if (channel.gain < 0) {
				channel.samplePosition = -1;
			}
			break;
	}
	channel.gain = clamp(channel.gain, cast(short)0, cast(short)0x7FF);
}

short[2] mixEcho(ref SongState state) nothrow pure @trusted {
	import std.range : cycle, popFrontN, take;
	short[2] result;
	int[2] previous;
	state.firHistory[state.firBufferIndex] = [state.echoBuffer[state.echoBufferIndex][0] >> 1, state.echoBuffer[state.echoBufferIndex][1] >> 1];
	auto firHistory = cycle(state.firHistory);
	firHistory.popFrontN(state.firBufferIndex + 1);
	foreach (idx; 0 .. state.firCoefficients.length) {
		previous[left] += (firHistory[idx][left] * state.firCoefficients[idx]) >> 6;
		previous[right] += (firHistory[idx][right] * state.firCoefficients[idx]) >> 6;
	}
	if (++state.firBufferIndex >= state.firHistory.length) {
		state.firBufferIndex = 0;
	}
	previous[left] = clamp(previous[left], short.min, short.max);
	previous[right] = clamp(previous[right], short.min, short.max);

	previous[left] &= ~1;
	previous[right] &= ~1;

	int[2] newSample;
	foreach (channel; state.channels) {
		if (channel.echoEnabled) {
			newSample[left] += channel.echoSamples[left];
			newSample[right] += channel.echoSamples[right];
		}
	}

	result[left] = cast(short)clamp(newSample[left] + cast(short)(previous[left] * state.echoFeedbackVolume >> 7), short.min, short.max);
	result[right] = cast(short)clamp(newSample[right] + cast(short)(previous[right] * state.echoFeedbackVolume >> 7), short.min, short.max);

	result[left] &= ~1;
	result[right] &= ~1;

	if (state.echoEnabled) {
		state.echoBuffer[state.echoBufferIndex][left] = result[left];
		state.echoBuffer[state.echoBufferIndex][right] = result[right];
	}

	if (++state.echoBufferIndex >= state.echoBufferSize) {
		state.echoBufferIndex = 0;
	}
	return result;
}

@safe pure unittest {
	SongState state;
	state.firCoefficients = [127, 0, 0, 0, 0, 0, 0, 0];
	state.echoFeedbackVolume = 60;
	state.channels.length = 8;
	state.echoBufferSize = 2560;
	state.echoBufferIndex = 0;
	state.echoBuffer[] = [-1, -1];
	short[2] mix(short[2] chan2, short[2] chan3, short[2] chan4) {
		state.echoEnabled = true;
		state.channels[0].echoEnabled = false;
		state.channels[0].echoSamples = [0, 0];
		state.channels[1].echoEnabled = false;
		state.channels[1].echoSamples = [0, 0];
		state.channels[2].echoEnabled = true;
		state.channels[2].echoSamples = chan2;
		state.channels[3].echoEnabled = true;
		state.channels[3].echoSamples = chan3;
		state.channels[4].echoEnabled = true;
		state.channels[4].echoSamples = chan4;
		state.channels[5].echoEnabled = false;
		state.channels[5].echoSamples = [0, 0];
		state.channels[6].echoEnabled = false;
		state.channels[6].echoSamples = [0, 0];
		state.channels[7].echoEnabled = false;
		state.channels[7].echoSamples = [0, 0];
		return mixEcho(state);
	}

	import nspcplay.echotestdata;
	foreach (id, tcase; testcases) {
		import std.format;
		const result = mix(tcase.data.tupleof);
		assert(result == tcase.result, format!"Failed: %s - mix(%s) - %s != %s"(id, tcase.data, result, tcase.result));
	}
}

///
struct NSPCPlayer {
	enum defaultSpeed = 500;

	package const(Song)* currentSong;
	private SongState state;
	private SongState backupState;
	private int mixrate = nativeSamplingRate;
	private int timerSpeed = defaultSpeed;
	private bool songPlaying;

	private bool loopEnabled = true;

	Interpolation interpolation = Interpolation.gaussian;

	size_t onTimerTicksLeft;
	void function(scope NSPCPlayer*) @safe pure nothrow onTimerTick;
	void function(scope NSPCPlayer*) @safe pure nothrow onPhraseChange;
	///
	short[2][] fillBuffer(short[2][] buffer) nothrow pure @safe {
		if (!songPlaying) {
			buffer[] = [0, 0];
			return buffer;
		}
		size_t length;
		foreach (ref sample; buffer) {
			sample[] = 0;
			if ((state.nextTimerTick -= timerSpeed) < 0) {
				state.nextTimerTick += mixrate;
				if (!doTimer()) {
					break;
				}
			}
			length++;
			int[2] tempSample;
			foreach (i, ref channel; state.channels) {
				const loadedSample = currentSong.samples[channel.sampleID & 0x7F];
				if (!channel.enabled) {
					continue;
				}

				if (channel.samplePosition < 0) {
					continue;
				}

				int ipos = channel.samplePosition >> 15;

				foreach (idx, ref interpolationSample; channel.interpolationBuffer) {
					size_t offset = ipos + idx;
					while (loadedSample.loopLength && (offset >= loadedSample.data.length)) {
						offset -= loadedSample.loopLength;
					}
					if (offset < loadedSample.data.length) {
						interpolationSample = loadedSample.data[offset];
					} else if (loadedSample.data && (idx > 0)) {
						interpolationSample = channel.interpolationBuffer[idx - 1];
					} else { //no sample data?
					}
				}
				int s1 = interpolate(interpolation, channel.interpolationBuffer[], channel.samplePosition >> 3);

				if (channel.adsrRate && (++channel.adsrCounter >= cast(int)(adsrGainRates[channel.adsrRate] * (mixrate / cast(double)nativeSamplingRate)))) {
					doADSR(channel);
					channel.adsrCounter = 0;
				}
				if (channel.gain == 0) {
					continue;
				}
				s1 = (s1 * channel.gain) >> 11;

				const leftSample = cast(short)(s1 * channel.leftVolume / 128.0);
				const rightSample = cast(short)(s1 * channel.rightVolume / 128.0);
				tempSample[left] += leftSample;
				tempSample[right] += rightSample;
				if (channel.echoEnabled) {
					channel.echoSamples[0] = leftSample;
					channel.echoSamples[1] = rightSample;
				}

				channel.samplePosition += channel.noteFrequency;
				if ((channel.samplePosition >> 15) >= loadedSample.data.length) {
					if (loadedSample.loopLength) {
						channel.samplePosition -= loadedSample.loopLength << 15;
					} else {
						channel.samplePosition = -1;
						channel.adsrPhase = ADSRPhase.release;
					}
				}
			}
			const echo = mixEcho(state);
			sample[left] = cast(short)clamp(cast(int)((tempSample[left] * state.masterVolumeLeft + echo[left] * cast(byte)state.echoVolumeLeft.current) / 128.0), short.min, short.max);
			sample[right] = cast(short)clamp(cast(int)((tempSample[right] * state.masterVolumeRight + echo[right] * cast(byte)state.echoVolumeRight.current) / 128.0), short.min, short.max);
		}
		return buffer[0 .. length];
	}

	private void calcTotalVolume(const SongState st, ref ChannelState c, byte tremoloPhase) nothrow @safe pure {
		ubyte v = (tremoloPhase << 1 ^ tremoloPhase >> 7) & 0xFF;
		v = ~(v * c.tremoloRange >> 8) & 0xFF;

		v = v * (st.volume.current >> 8) >> 8;
		v = v * currentSong.volumeTable[c.noteStyle & 15] >> 8;
		v = v * (c.volume.current >> 8) >> 8;
		c.totalVolume = v * v >> 8;
	}

	private int calcVolume3(const ChannelState c, int pan, int flag) nothrow pure @safe {
		static immutable ubyte[] panTable = [0x00, 0x01, 0x03, 0x07, 0x0D, 0x15, 0x1E, 0x29, 0x34, 0x42, 0x51, 0x5E, 0x67, 0x6E, 0x73, 0x77, 0x7A, 0x7C, 0x7D, 0x7E, 0x7F, 0x7F];
		const ubyte[] ph = panTable[pan >> 8 .. (pan >> 8) + 2];
		int v = ph[0] + ((ph[1] - ph[0]) * (pan & 255) >> 8);
		v = v * c.totalVolume >> 8;
		v += v * c.volumeBoost >> 8;
		if (c.panFlags & flag) {
			v = -v;
		}
		return v;
	}

	private void calcVolume2(ref ChannelState c, int pan) nothrow pure @safe {
		c.leftVolume = cast(byte) calcVolume3(c, pan, 0x80);
		c.rightVolume = cast(byte) calcVolume3(c, 0x1400 - pan, 0x40);
	}

	private void makeSlider(ref Slider s, int cycles, int target) nothrow pure @safe {
		if (cycles) {
			s.delta = cast(ushort)(((target << 8) - (s.current & 0xFF00)) / cycles);
			s.cycles = cast(ubyte) cycles;
			s.target = cast(ubyte) target;
		}
	}

	private void setInstrument(ref SongState st, ref ChannelState c, size_t instrument) nothrow pure @safe {
		const idata = currentSong.instruments[instrument];
		c.instrument = cast(ubyte) instrument;
		c.sampleID = currentSong.instruments[instrument].sampleID;
		setADSRGain(c, idata.adsrGain);
		c.tuningOverride.nullify();
	}
	private void setADSRGain(ref ChannelState c, const ADSRGain adsrGain) nothrow pure @safe {
		c.instrumentADSRGain = adsrGain;
		if (adsrGain.mode == ADSRGainMode.directGain) {
			c.gain = adsrGain.fixedVolume;
		}
	}

	// calculate how far to advance the sample pointer on each output sample
	private void setFrequency(ref ChannelState c, int note16) const nothrow pure @safe {
		static immutable ushort[13] noteFrequencyTable = [0x085F, 0x08DE, 0x0965, 0x09F4, 0x0A8C, 0x0B2C, 0x0BD6, 0x0C8B, 0x0D4A, 0x0E14, 0x0EEA, 0x0FCD, 0x10BE];

		// What is this for???
		if (note16 >= 0x3400) {
			note16 += (note16 >> 8) - 0x34;
		} else if (note16 < 0x1300) {
			note16 += ((note16 >> 8) - 0x13) << 1;
		}

		if (cast(ushort) note16 >= 0x5400) {
			c.noteFrequency = 0;
			return;
		}

		int octave = (note16 >> 8) / 12;
		int tone = (note16 >> 8) % 12;
		int freq = noteFrequencyTable[tone];
		freq += (noteFrequencyTable[tone + 1] - freq) * (note16 & 0xFF) >> 8;
		freq <<= 1;
		freq >>= 6 - octave;


		freq *= c.tuningOverride.get(currentSong.instruments[c.instrument].tuning);
		freq >>= 8;
		freq &= 0x3fff;

		c.noteFrequency = (freq * (nativeSamplingRate << (15 - 12))) / mixrate;
	}

	private int calcVibratoDisp(ref ChannelState c, int phase) nothrow pure @safe {
		int range = c.currentVibratoRange;
		if (range > 0xF0) {
			range = (range - 0xF0) * 256;
		}

		int disp = (phase << 2) & 255; /* //// */
		if (phase & 0x40) {
			disp ^= 0xFF; /* /\/\ */
		}
		disp = (disp * range) >> 8;

		if (phase & 0x80) {
			disp = -disp; /* /\   */
		}
		return disp; /*   \/ */
	}
	// do a Ex/Fx code
	private void doCommand(ref SongState st, ref ChannelState c, const Command command) nothrow pure @safe {
		final switch (command.special) {
			case VCMD.instrument:
				setInstrument(st, c, currentSong.absoluteInstrumentID(command.parameters[0], st.percussionBase, false));
				break;
			case VCMD.panning:
			case VCMD.konamiPanning: // ???
				c.panFlags = command.parameters[0];
				c.panning.current = (command.parameters[0] & 0x1F) << 8;
				break;
			case VCMD.panningFade:
			case VCMD.konamiPanningFade: // ???
				makeSlider(c.panning, command.parameters[0], command.parameters[1]);
				break;
			case VCMD.vibratoOn:
				c.vibratoStart = command.parameters[0];
				c.vibratoSpeed = command.parameters[1];
				c.currentVibratoRange = c.vibratoMaxRange = command.parameters[2];
				c.vibratoFadeIn = 0;
				break;
			case VCMD.vibratoOff:
				c.currentVibratoRange = c.vibratoMaxRange = 0;
				c.vibratoFadeIn = 0;
				break;
			case VCMD.songVolume:
				st.volume.current = command.parameters[0] << 8;
				break;
			case VCMD.songVolumeFade:
				makeSlider(st.volume, command.parameters[0], command.parameters[1]);
				break;
			case VCMD.tempo:
				st.tempo.current = command.parameters[0] << 8;
				break;
			case VCMD.tempoFade:
				makeSlider(st.tempo, command.parameters[0], command.parameters[1]);
				break;
			case VCMD.globalAbsoluteTransposition:
				st.transpose = command.parameters[0];
				break;
			case VCMD.channelAbsoluteTransposition:
				c.transpose = command.parameters[0];
				break;
			case VCMD.tremoloOn:
				c.tremoloStart = command.parameters[0];
				c.tremoloSpeed = command.parameters[1];
				c.tremoloRange = command.parameters[2];
				break;
			case VCMD.tremoloOff:
				c.tremoloRange = 0;
				break;
			case VCMD.volume:
				c.volume.current = command.parameters[0] << 8;
				break;
			case VCMD.volumeFade:
				makeSlider(c.volume, command.parameters[0], command.parameters[1]);
				break;
			case VCMD.subRoutine:
				/// This is handled by the parser
				break;
			case VCMD.vibratoFadeIn:
				c.vibratoFadeIn = command.parameters[0];
				c.vibratoRangeDelta = c.currentVibratoRange / command.parameters[0];
				break;
			case VCMD.notePitchEnvelopeTo:
			case VCMD.notePitchEnvelopeFrom:
				c.portType = (command.special == VCMD.notePitchEnvelopeTo);
				c.portStart = command.parameters[0];
				c.portLength = command.parameters[1];
				c.portRange = command.parameters[2];
				break;
			case VCMD.notePitchEnvelopeOff:
				c.portLength = 0;
				break;
			case VCMD.fineTune:
				c.finetune = command.parameters[0];
				break;
			case VCMD.echoEnableBitsAndVolume:
				foreach (idx, ref channel; st.channels) {
					channel.echoEnabled = !!(command.parameters[0] & (1 << idx));
				}
				st.echoVolumeLeft.current = command.parameters[1];
				st.echoVolumeRight.current = command.parameters[2];
				st.echoEnabled = true;
				break;
			case VCMD.echoOff:
				st.echoVolumeLeft.current = 0;
				st.echoVolumeRight.current = 0;
				st.echoEnabled = false;
				break;
			case VCMD.echoParameterSetup:
				st.echoBufferIndex = 0;
				st.firBufferIndex = 0;
				st.echoBuffer[] = [0,0];
				st.firHistory[] = [0,0];
				st.echoBufferSize = (command.parameters[0] & 0xF) * 512;
				st.echoFeedbackVolume = command.parameters[1];
				st.firCoefficients = currentSong.firCoefficients[command.parameters[2]];
				debug tracef("Echo params: %s, %s, %s", st.echoBufferSize, st.echoFeedbackVolume, st.firCoefficients);
				break;
			case VCMD.echoVolumeFade:
				makeSlider(st.echoVolumeLeft, command.parameters[0], command.parameters[1]);
				makeSlider(st.echoVolumeRight, command.parameters[0], command.parameters[2]);
				break;
			case VCMD.noop0: //do nothing
			case VCMD.noop1: //do nothing
			case VCMD.noop2: //do nothing
				break;
			case VCMD.konamiLoopStart: // handled by parser
			case VCMD.konamiLoopEnd:
			case VCMD.amkSubloop:
				break;
			case VCMD.pitchSlideToNote:
				c.currentPortStartCounter = command.parameters[0];
				int target = command.parameters[2] + st.transpose;
				if (target >= 0x100) {
					target -= 0xFF;
				}
				target += c.transpose;
				makeSlider(c.note, command.parameters[1], target & 0x7F);
				break;
			case VCMD.percussionBaseInstrumentRedefine:
				st.percussionBase = command.parameters[0];
				break;
			case VCMD.konamiADSRGain:
				setADSRGain(c, konamiADSRGain(command.parameters));
				break;
			case VCMD.amkSetADSRGain:
				setADSRGain(c, amkADSRGain(command.parameters));
				break;
			case VCMD.amkSetFIR:
				st.firCoefficients = cast(const(byte)[])command.parameters;
				break;
			case VCMD.amkSampleLoad:
				c.sampleID = command.parameters[0];
				ubyte finetune = st.amkFixSampleLoadTuning ? 0 : cast(ubyte)currentSong.instruments[c.instrument].tuning;
				c.tuningOverride = (cast(ushort)command.parameters[1] << 8) | finetune;
				break;
			case VCMD.amkF4:
				if (command.parameters[0] == 3) {
					c.echoEnabled = !c.echoEnabled;
					break;
				}
				if (command.parameters[0] == 9) {
					setInstrument(st, c, c.instrument);
					break;
				}
				debug(nspclogging) warningf("Unhandled command: %x", command);
				break;
			case VCMD.amkFA:
				if (command.parameters[0] == 1) {
					auto newGain = c.instrumentADSRGain;
					newGain.gain = command.parameters[1];
					newGain.adsr &= ~0x80;
					setADSRGain(c, newGain);
					break;
				}
				if (command.parameters[0] == 2) {
					c.semitoneTune = command.parameters[1];
					break;
				}
				if (command.parameters[0] == 3) {
					c.volumeBoost = command.parameters[1];
					break;
				}
				if (command.parameters[0] == 4) {
					// reserves echo buffer, which we don't need to do
					break;
				}
				if (command.parameters[0] == 6) {
					st.useAltRTable = !!command.parameters[1];
					break;
				}
				debug(nspclogging) warningf("Unhandled command: %x", command);
				break;
			case VCMD.amkRemoteCommand:
				if (command.parameters[2] == 0) {
					c.remotes = null;
				} else {
					c.remotes[command.parameters[2]] = read!ushort(command.parameters[]);
				}
				break;
			case VCMD.setRelease:
				c.releaseOverride = command.parameters[0];
				break;
			case VCMD.deleteTrack:
				c.parser.sequenceData = [];
				break;
			case VCMD.konamiE4: // ???
			case VCMD.konamiE7: // ???
			case VCMD.konamiF5: // ???
			case VCMD.channelMute:
			case VCMD.fastForwardOn:
			case VCMD.fastForwardOff:
			case VCMD.amkWriteDSP:
			case VCMD.amkEnableNoise:
			case VCMD.amkSendData:
			case VCMD.amkFB:
				debug(nspclogging) warningf("Unhandled command: %x", command);
				break;
			case VCMD.invalid: //do nothing
				assert(0, "Invalid command");
		}
	}

	// $0654 + $08D4-$8EF
	private void doNote(ref SongState st, ref ChannelState c, const Command command) nothrow pure @safe {
		ubyte note = command.note;
		executeRemote(255, c, st);
		// using >=CA as a note switches to that instrument and plays a predefined note
		if (command.type == VCMDClass.percussion) {
			setInstrument(st, c, currentSong.absoluteInstrumentID(note, st.percussionBase, true));
			note = cast(ubyte)(currentSong.percussionNotes[note]);
		}
		if (command.type.among(VCMDClass.percussion, VCMDClass.note)) {
			c.vibratoPhase = c.vibratoFadeIn & 1 ? 0x80 : 0;
			c.vibratoStartCounter = 0;
			c.vibratoFadeInCounter = 0;
			c.tremoloPhase = 0;
			c.tremoloStartCounter = 0;

			c.samplePosition = 0;
			//c.sampleID = currentSong.instruments[c.instrument].sampleID;
			c.gain = 0;
			c.setADSRPhase((currentSong.instruments[c.instrument].adsrGain.mode == ADSRGainMode.adsr) ? ADSRPhase.attack : ADSRPhase.gain);

			note += st.transpose + c.transpose + c.semitoneTune;
			c.note.current = cast(ushort)(note << 8 | c.finetune);

			c.note.cycles = c.portLength;
			if (c.note.cycles) {
				int target = note;
				c.currentPortStartCounter = c.portStart;
				if (c.portType == 0) {
					c.note.current -= c.portRange << 8;
				} else {
					target += c.portRange;
				}
				makeSlider(c.note, c.portLength, target & 0x7F);
			}

			setFrequency(c, c.note.current);
		}

		// Search forward for the next note (to see if it's C8). This is annoying
		// but necessary - C8 can continue the last note of a subroutine as well
		// as a normal note.
		VCMDClass nextNote;
		{
			auto p = c.parser;
			bool done;
			while (!done && !p.empty) {
				const tmpCommand = p.popCommand(*currentSong, done, st.enchantedReadahead);
				if (tmpCommand.type.among(VCMDClass.note, VCMDClass.tie, VCMDClass.rest, VCMDClass.percussion)) {
					nextNote = tmpCommand.type;
					break;
				}
			}
		}

		int rel;
		if (nextNote == VCMDClass.tie) {
			// if the note will be continued, don't release yet
			rel = c.noteLength;
		} else {
			const releaseTable = st.useAltRTable ? currentSong.altReleaseTable : currentSong.releaseTable;
			rel = (c.noteLength * c.releaseOverride.get(releaseTable[c.noteStyle >> 4])) >> 8;
			if (rel > c.noteLength - 2) {
				rel = c.noteLength - 2;
			}
			if (rel < 1) {
				rel = 1;
			}
		}
		c.noteRelease = cast(ubyte) rel;
	}

	private void loadPattern() nothrow pure @safe {
		state.phraseCounter++;
		const nextPhrase = currentSong.order[state.phraseCounter];
		debug(nspclogging) tracef("Next phrase: %s", nextPhrase);
		final switch (nextPhrase.type) {
			case PhraseType.end:
				state.phraseCounter--;
				songPlaying = false;
				return;
			case PhraseType.jumpLimited:
				if (--state.repeatCount >= 0x80) {
					state.repeatCount = cast(ubyte)nextPhrase.jumpTimes;
				}
				if (state.repeatCount > 0) {
					state.phraseCounter = nextPhrase.id - 1;
				}
				debug(nspclogging) tracef("%s more repeats", state.repeatCount);
				loadPattern();
				break;
			case PhraseType.jump:
				if (loopEnabled) {
					state.phraseCounter = nextPhrase.id - 1;
					loadPattern();
				} else {
					state.phraseCounter--;
					songPlaying = false;
				}
				break;
			case PhraseType.fastForwardOn:
				assert(0, "Not yet implemented");
			case PhraseType.fastForwardOff:
				assert(0, "Not yet implemented");
			case PhraseType.pattern:
				const trackList = currentSong.trackLists[nextPhrase.id];
				state.channels.length = max(state.channels.length, trackList.length);
				backupState.channels.length = state.channels.length;
				foreach (idx, channel; state.channels) {
					setChannel(idx, assumeWontThrow(currentSong.tracks.get(trackList[idx], [])));
				}
				break;
		}
		if (onPhraseChange !is null) {
			onPhraseChange(&this);
		}
	}
	public void setChannel(size_t index, const(Command)[] commands) nothrow pure @safe {
		state.channels[index].enabled = false;
		state.channels[index].parser.sequenceData = commands;
		state.channels[index].parser.subroutineCount = 0;
		state.channels[index].volume.cycles = 0;
		state.channels[index].panning.cycles = 0;
		state.channels[index].next = 0;
		state.channels[index].enabled = true;
	}

	private void doKeySweepVibratoChecks(ref ChannelState c) nothrow pure @safe {
		// key off
		if (c.noteRelease) {
			c.noteRelease--;
		}
		if (!c.noteRelease) {
			c.setADSRPhase(ADSRPhase.release);
			executeRemote(3, c, state);
		}

		// sweep
		if (c.note.cycles) {
			if (c.currentPortStartCounter == 0) {
				c.note.slide();
				setFrequency(c, c.note.current);
			} else {
				c.currentPortStartCounter--;
			}
		}

		// vibrato
		if (c.currentVibratoRange) {
			if (c.vibratoStartCounter == c.vibratoStart) {
				int range;
				if (c.vibratoFadeInCounter == c.vibratoFadeIn) {
					range = c.vibratoMaxRange;
				} else {
					range = c.currentVibratoRange;
					if (c.vibratoFadeInCounter == 0) {
						range = 0;
					}
					range += c.vibratoRangeDelta;
					c.vibratoFadeInCounter++;
				} // DA0
				c.currentVibratoRange = cast(ubyte) range;
				c.vibratoPhase += c.vibratoSpeed;
				setFrequency(c, c.note.current + calcVibratoDisp(c, c.vibratoPhase));
			} else {
				c.vibratoStartCounter++;
			}
		}
	}
	bool inRemote = false;
	private void executeRemote(ubyte event, ref ChannelState channel, ref SongState song) nothrow pure @safe {
		assert(!inRemote);
		if (auto seq = event in channel.remotes) {
			inRemote = true;
			Parser parser;
			parser.sequenceData = currentSong.tracks[*seq];
			parser.subroutineCount = 0;
			execute(parser, channel, song);
			inRemote = false;
		}
	}
	/// Executes vcmds until either a terminator or a note is reached
	private bool execute(ref Parser parser, ref ChannelState channel, ref SongState song) nothrow pure @safe {
		while (!parser.empty) {
			bool done;
			const command = parser.popCommand(*currentSong, done);
			if (executeCommand(channel, song, command, done)) {
				return done;
			}
		}
		return true;
	}
	private bool executeCommand(ref ChannelState channel, ref SongState song, const Command command, ref bool done) nothrow pure @safe {
		final switch (command.type) {
			case VCMDClass.terminator:
				if (done) {
					done = false;
					return true;
				}
				break;
			case VCMDClass.noteDuration:
				channel.noteLength = command.noteDuration;
				if (command.parameters.length > 0) {
					channel.noteStyle = command.parameters[0];
				}
				break;
			case VCMDClass.note:
			case VCMDClass.tie:
			case VCMDClass.rest:
			case VCMDClass.percussion:
				channel.next = channel.noteLength - 1;
				doNote(song, channel, command);
				done = true;
				return true;
			case VCMDClass.special:
				doCommand(song, channel, command);
				break;
		}
		return false;
	}
	public void executeCommand(ubyte channel, const Command command) nothrow pure @safe {
		bool _;
		executeCommand(state.channels[channel], state, command, _);
	}

	// $07F9 + $0625
	private bool doCycle(ref SongState st) nothrow pure @safe {
		foreach (ref channel; st.channels) {
			if (--channel.next >= 0) {
				doKeySweepVibratoChecks(channel);
			} else {
				if (!execute(channel.parser, channel, st)) {
					return false;
				}
			}
			// $0B84
			if (channel.note.cycles == 0) {
				size_t length;
				if (!channel.parser.empty) {
					const command = channel.parser.sequenceData[0];
					if (command.special == VCMD.pitchSlideToNote) {
						doCommand(st, channel, command);
						channel.parser.popCommand(*currentSong);
					}
				}
			}
		}

		st.tempo.slide();
		st.volume.slide();

		foreach (ref channel; st.channels) {
			if (channel.parser.sequenceData == null) {
				continue;
			}

			// @ 0C40
			channel.volume.slide();

			// @ 0C4D
			int tphase = 0;
			if (channel.tremoloRange) {
				if (channel.tremoloStartCounter == channel.tremoloStart) {
					if (channel.tremoloPhase >= 0x80 && channel.tremoloRange == 0xFF) {
						channel.tremoloPhase = 0x80;
					} else {
						channel.tremoloPhase += channel.tremoloSpeed;
					}
					tphase = channel.tremoloPhase;
				} else {
					channel.tremoloStartCounter++;
				}
			}
			calcTotalVolume(st, channel, cast(byte) tphase);

			// 0C79
			channel.panning.slide();

			// 0C86: volume stuff
			calcVolume2(channel, channel.panning.current);
		}
		return true;
	}

	private int subCycleCalc(const SongState st, int delta) nothrow pure @safe {
		if (delta < 0x8000) {
			return st.cycleTimer * delta >> 8;
		} else {
			return -(st.cycleTimer * (0x10000 - delta) >> 8);
		}
	}

	private void doSubCycle(ref SongState st) nothrow pure @safe {
		foreach (ref channel; st.channels) {
			if (channel.parser.sequenceData == null) {
				continue;
			}
			// $0DD0

			bool changed = false;
			if (channel.tremoloRange && channel.tremoloStartCounter == channel.tremoloStart) {
				int p = channel.tremoloPhase + subCycleCalc(st, channel.tremoloSpeed);
				changed = true;
				calcTotalVolume(st, channel, cast(byte) p);
			}
			int pan = channel.panning.current;
			if (channel.panning.cycles) {
				pan += subCycleCalc(st, channel.panning.delta);
				changed = true;
			}
			if (changed) {
				calcVolume2(channel, pan);
			}

			changed = false;
			int note = channel.note.current; // $0BBC
			if (channel.note.cycles && channel.currentPortStartCounter == 0) {
				note += subCycleCalc(st, channel.note.delta);
				changed = true;
			}
			if (channel.currentVibratoRange && channel.vibratoStartCounter == channel.vibratoStart) {
				int p = channel.vibratoPhase + subCycleCalc(st, channel.vibratoSpeed);
				note += calcVibratoDisp(channel, p);
				changed = true;
			}
			if (changed) {
				setFrequency(channel, note);
			}
		}
	}

	private bool doTimer() nothrow pure @safe {
		state.cycleTimer += state.tempo.current >> 8;
		if (state.cycleTimer >= 256) {
			state.cycleTimer -= 256;
			while (!doCycle(state)) {
				loadPattern();
				if (!songPlaying) {
					return false;
				}
			}
			if (onTimerTicksLeft > 0) {
				onTimerTicksLeft--;
			} else {
				if (onTimerTick !is null) {
					onTimerTick(&this);
					onTimerTick = null;
				}
			}
		} else {
			doSubCycle(state);
		}
		return true;
	}

	/// Initialize or reset the player state
	void initialize() nothrow pure @safe {
		state = state.init;

		if (currentSong) {
			state.percussionBase = cast(ubyte)currentSong.percussionBase;
			if (currentSong.order.length) {
				loadPattern();
			} else {
				songPlaying = false;
			}
			state.tempo.current = currentSong.defaultTempo << 8;
			foreach (idx, channel; state.channels) {
				// disable any channels that are disabled by default
				channel.enabled ^= !(currentSong.defaultEnabledChannels() & (1 << idx));
			}
			state.enchantedReadahead = currentSong.defaultEnchantedReadahead;
		}
	}
	this(int sampleRate) nothrow pure @safe {
		mixrate = sampleRate;
	}

	/// Start playing music
	void play() @safe pure nothrow {
		songPlaying = true;
	}
	void stop() @safe pure nothrow {
		songPlaying = false;
	}
	void loadSong(const Song song) @safe pure nothrow {
		if (songPlaying) {
			stop();
		}
		currentSong = &[song][0];
		initialize();
	}
	/// Sets the playback speed. Default value is NSPCPlayer.defaultSpeed.
	public void setSpeed(ushort rate) @safe nothrow pure {
		timerSpeed = rate;
	}
	/// Enable or disable song looping
	public void looping(bool enabled) @safe nothrow pure {
		loopEnabled = enabled;
	}
	/// Enable or disable a song channel
	public void setChannelEnabled(ubyte channel, bool enabled) @safe nothrow pure {
		state.channels[channel].enabled = enabled;
	}
	bool isPlaying() const pure @safe nothrow {
		return songPlaying;
	}
	public void fade(ubyte ticks, ubyte targetVolume) @safe nothrow pure {
		backupState.volume = state.volume;
		makeSlider(state.volume, ticks, targetVolume);
	}
	public void tempo(ubyte tempo) @safe nothrow pure {
		backupState.tempo = state.tempo;
		state.tempo.current = cast(ushort)(tempo << 8);
	}
	public void restoreTempo() @safe nothrow pure {
		state.tempo = backupState.tempo;
	}
	public ubyte tempo() @safe nothrow pure {
		return state.tempo.current >> 8;
	}
	public void volume(ubyte volume) @safe nothrow pure {
		backupState.volume = state.volume;
		state.volume.current = cast(ushort)(volume << 8);
	}
	public void restoreVolume() @safe nothrow pure {
		state.volume = backupState.volume;
	}
	public ubyte volume() @safe nothrow pure {
		return state.volume.current >> 8;
	}
	public void setChannelVolume(ubyte channel, ubyte volume) @safe nothrow pure {
		if (channel < state.channels.length) {
			backupState.channels[channel].volume = state.channels[channel].volume;
			state.channels[channel].volume.current = cast(ushort)(volume << 8);
		}
	}
	public void restoreChannelVolume(ubyte channel) @safe nothrow pure {
		if (channel < state.channels.length) {
			state.channels[channel].volume = backupState.channels[channel].volume;
		}
	}
	public ubyte getChannelVolume(ubyte channel) @safe nothrow pure {
		if (channel < state.channels.length) {
			return state.channels[channel].volume.current >> 8;
		}
		return 0;
	}
	public void transpose(ubyte transpose) @safe nothrow pure {
		backupState.transpose = state.transpose;
		state.transpose = transpose;
	}
	public void restoreTranspose() @safe nothrow pure {
		state.transpose = backupState.transpose;
	}
	public void addTimer(size_t ticks, typeof(onTimerTick) func) @safe nothrow pure {
		onTimerTicksLeft = ticks;
		onTimerTick = func;
	}
}

private bool inRange(T)(T val, T lower, T upper) {
	return ((val >= lower) && (val <= upper));
}
