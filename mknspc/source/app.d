import std;
import std.experimental.logger;
import nspcplay;

enum Mode {
	undefined,
	spc
}

int main(string[] args) {
	(cast()sharedLog).logLevel = LogLevel.trace;
	enum validArgs = ["spc", "packs"];
	if (args.length == 1) {
		stderr.writefln!"Missing argument - valid options are %-('%s', %)"(validArgs);
		return 1;
	}
	const(ubyte)[] finished;
	string filename;
	switch (args[1].toLower) {
		case "spc":
			finished = buildNSPCFromSPC(args[0] ~ args[2 .. $], filename);
			break;
		case "packs":
			finished = buildNSPCFromPackfiles(args[0] ~ args[2 .. $], filename);
			break;
		default:
			stderr.writefln!"Invalid argument - valid options are %-('%s', %)"(validArgs);
			return 1;
	}
	if (finished == []) {
		return 1;
	}
	const loadedSong = loadNSPCFile(finished);
	File(filename, "w").rawWrite(finished);
	return 0;
}

const(ubyte)[] buildNSPCFromSPC(string[] args, out string filename) {
	NSPCFileHeader header;
	bool autodetect;
	void handleIntegers(string opt, string value) {
		ushort val;
		if (value.startsWith("0x")) {
			val = value[2 .. $].to!ushort(16);
		} else {
			val = value.to!ushort(10);
		}
		switch (opt) {
			case "s|songaddress":
				header.songBase = val;
				break;
			case "a|sampleaddress":
				header.sampleBase = val;
				break;
			case "i|instrumentaddress":
				header.instrumentBase = val;
				break;
			case "addmusick-custominstruments":
				header.extra.customInstruments = val;
				break;
			case "prototype-percussionbase":
			case "addmusick-percussionbase":
				header.extra.percussionBase = val;
				break;
			default:
				throw new Exception("Unknown option "~opt);
		}
	}
	auto helpInfo = getopt(args,
		"d|autodetect", "Try autodetecting some addresses", &autodetect,
		"o|output", "Filename to write to (defaults to filename.nspc)", &filename,
		"s|songaddress", "Address of song data", &handleIntegers,
		"a|sampleaddress", "Address of sample data", &handleIntegers,
		"i|instrumentaddress", "Address of instrument data", &handleIntegers,
		"prototype-percussionbase|addmusick-percussionbase", "Percussion base id (prototype, addmusick variants)", &handleIntegers,
		"addmusick-custominstruments", "Custom instrument address (addmusick variant)", &handleIntegers,
		"v|variant", "NSPC variant to use", &header.variant,
	);
	if (helpInfo.helpWanted || (args.length == 1)) {
		defaultGetoptPrinter(format!"NSPC creation tool (SPC conversion)\nUsage: %s spc <filename.spc>"(args[0]), helpInfo.options);
		return [];
	}
	if (!filename) {
		filename = args[1].baseName.withExtension(".nspc").text;
	}
	auto spcFile = cast(ubyte[])read(args[1]);
	if (autodetect) {
		const sampleDirectory = spcFile[0x1015D];
		infof("Using auto-detected sample directory: %04X", sampleDirectory << 8);
		header.sampleBase = sampleDirectory << 8;
	}
	if (autodetect) {
		if (spcFile.isAMK) {
			infof("Detected AddMusicK song");
			header.variant = nspcplay.Variant.addmusick;
			const songTableAddress = spcFile.find(amkPreTable)[amkPreTable.length .. $];
			const tableAddr = (cast(const(ushort)[])(songTableAddress[0 .. 2]))[0] + 2 + 0x100 + 18;
			infof("Detected song table: %04X", tableAddr - 0x100);
			header.songBase = (cast(const(ushort)[])spcFile[tableAddr .. tableAddr + 2])[0];
			header.instrumentBase = 0x1844;
			infof("Detected song address: %04X", header.songBase);
			const songStartData = spcFile[header.songBase + 0x100 .. $];
			ushort customInstrumentBase = 0;
			while(songStartData[customInstrumentBase .. customInstrumentBase + 2] != [0xFF, 0x00]) {
				customInstrumentBase += 2;
			}
			header.extra.customInstruments = cast(ushort)((cast(const(ushort)[])songStartData[customInstrumentBase + 2 .. customInstrumentBase  + 4])[0] + 6);
			infof("Detected custom instruments: %04X", header.extra.customInstruments);
		}
	}
	Appender!(const(ubyte)[]) buf;
	buf ~= HeaderBytes(header).raw[];
	buf.append!ushort(65535);
	buf.append!ushort(0);
	buf ~= spcFile[0x100 .. 0x100FF];
	buf.append!ushort(0);
	return buf.data;
}

union HeaderBytes {
	NSPCFileHeader header;
	ubyte[NSPCFileHeader.sizeof] raw;
}

const(ubyte)[] buildNSPCFromPackfiles(string[] args, out string filename) {
	NSPCFileHeader header;
	void handleIntegers(string opt, string value) {
		ushort val;
		if (value.startsWith("0x")) {
			val = value[2 .. $].to!ushort(16);
		} else {
			val = value.to!ushort(10);
		}
		switch (opt) {
			case "s|songaddress":
				header.songBase = val;
				break;
			case "a|sampleaddress":
				header.sampleBase = val;
				break;
			case "i|instrumentaddress":
				header.instrumentBase = val;
				break;
			default:
				throw new Exception("Unknown option "~opt);
		}
	}
	auto helpInfo = getopt(args,
		"o|output", "Filename to write to (defaults to filename.nspc)", &filename,
		"s|songaddress", "Address of song data", &handleIntegers,
		"a|sampleaddress", "Address of sample data", &handleIntegers,
		"i|instrumentaddress", "Address of instrument data", &handleIntegers,
		"v|variant", "NSPC variant to use", &header.variant,
	);
	if (helpInfo.helpWanted || (args.length == 1)) {
		defaultGetoptPrinter(format!"NSPC creation tool (Packfile conversion)\nUsage: %s spc <filename.bin> [filename.bin ...]"(args[0]), helpInfo.options);
		return [];
	}
	if (!filename) {
		filename = args[1].baseName.withExtension(".nspc").text;
	}
	Appender!(const(ubyte)[]) buf;
	buf ~= HeaderBytes(header).raw[];
	foreach(file; args[1 .. $]) {
		auto packFile = cast(ubyte[])read(file);
		size_t offset;
		while(true) {
			if (offset >= packFile.length) {
				break;
			}
			auto size = (cast(ushort[])(packFile[offset .. offset + 2]))[0];
			if (size == 0) {
				break;
			}
			auto spcOffset = (cast(ushort[])(packFile[offset + 2 .. offset + 4]))[0];
			infof("Song subpack: $%04X, %04X bytes", spcOffset, size);
			buf ~= packFile[offset .. offset + size + 4];
			offset += size + 4;
		}
	}
	buf.append!ushort(0);
	return buf.data;
}

bool inRange(T)(T val, T lower, T upper) {
	return (val >= lower) && (val < upper);
}

enum amkPreTable = [0xFA, 0x8F, 0x02, 0x6B, 0x8F, 0x02, 0x0C, 0xAE, 0x1C, 0xFD, 0xF6];

bool isAMK(const ubyte[] data) @safe pure {
	return data[0x500 .. 0x510] == [0x20, 0xCD, 0xCF, 0xBD, 0xE8, 0x00, 0x8D, 0x00, 0xD6, 0x00, 0x01, 0xFE, 0xFB, 0xD6, 0x00, 0x02];
}
