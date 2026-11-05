#import <AVFoundation/AVFoundation.h>
#import <AppKit/AppKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudioKit/CoreAudioKit.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <CoreAudio/CoreAudio.h>

#include "OmniAudio.h"
#include "OmniEngine.h"

#include <util/platform.h>
#include <util/util_uint64.h>

#include <mach/mach_time.h>
#include <math.h>
#include <stdatomic.h>

/*
 * The mixer, in three parts:
 *
 *   Taps     One "omni_app_audio" source per app channel, plus the system one, each
 *            reading a Core Audio process tap. Taps mute what they read, so an app
 *            is heard only through the monitor mix below.
 *   Monitor  One output unit. Every channel's audio (after the mic plugins, before
 *            the stream fader) lands in a ring buffer, and the output callback sums
 *            the rings at each channel's monitor level. The stream level is the OBS
 *            source volume, so the two mixes are independent.
 *   Plugins  STACKS and Muze run as OBS filters on the mic. Each is loaded by its
 *            component ID only when turned on: nothing scans the plugin folders.
 */

#define MAX_CH OMNI_MIXER_MAX_CHANNELS
/* App channels are OBS output channels 8.. (0-5 are the scene, desktop and mic). */
#define APP_OUTPUT_BASE 8

static uint64_t host_to_ns(uint64_t host)
{
	static mach_timebase_info_data_t tb;
	if (!tb.denom)
		mach_timebase_info(&tb);
	return util_mul_div64(host, tb.numer, tb.denom);
}

/* ------------------------------------------------------------------------- */
/* Monitor mix */

/* 48 kHz frames. The output reads TARGET behind the writer; if a channel's clock
 * runs ahead and the fill passes MAX_FILL it skips back to TARGET. */
#define RING_FRAMES 16384
#define PRIME_FRAMES 960
#define TARGET_FRAMES 1024
#define MAX_FILL 4800

struct ring {
	_Atomic bool active;
	_Atomic bool flush;
	_Atomic float gain; /* monitor level, 0 when muted */
	_Atomic float peak[2];
	_Atomic float last; /* loudest side of the most recent packet, linear */
	_Atomic uint64_t write_pos;
	_Atomic uint64_t read_pos;
	/* Output thread only. */
	float cur_gain;
	bool primed;
	float buf[2][RING_FRAMES];
};

static struct ring rings[MAX_CH];

static struct {
	AudioUnit unit;
	char uid[256];
} monitor;

static void store_peak(_Atomic float *p, float v)
{
	if (v > atomic_load_explicit(p, memory_order_relaxed))
		atomic_store_explicit(p, v, memory_order_relaxed);
}

/* Tempo tracking for the followed music channel. The audio thread turns each
 * 256-sample hop into an onset value (rises in low, full and high band energy);
 * omni_music_tempo finds the beat period in the last ~11 s of them. */
#define TEMPO_HOP 256
#define TEMPO_LEN 2048

static struct {
	_Atomic int channel;
	_Atomic bool reset;
	float acc[3];
	int fill;
	float low, mid; /* one-pole lowpass states */
	float prev[3];
	float env[TEMPO_LEN];
	_Atomic uint32_t written;
} tempo = {.channel = -1};

static void tempo_feed(const float *l, const float *r, uint32_t frames)
{
	if (atomic_exchange_explicit(&tempo.reset, false, memory_order_acquire)) {
		tempo.fill = 0;
		atomic_store_explicit(&tempo.written, 0, memory_order_release);
	}
	const float a_low = 0.0194f; /* ~150 Hz: kick and bass */
	const float a_mid = 0.2300f; /* ~2 kHz: what's above is hats and snare snap */
	for (uint32_t i = 0; i < frames; i++) {
		float x = 0.5f * (l[i] + r[i]);
		tempo.low += a_low * (x - tempo.low);
		tempo.mid += a_mid * (x - tempo.mid);
		float high = x - tempo.mid;
		tempo.acc[0] += tempo.low * tempo.low;
		tempo.acc[1] += x * x;
		tempo.acc[2] += high * high;
		if (++tempo.fill < TEMPO_HOP)
			continue;
		float onset = 0;
		for (int b = 0; b < 3; b++) {
			float e = logf(tempo.acc[b] + 1e-7f);
			onset += fmaxf(0, e - tempo.prev[b]);
			tempo.prev[b] = e;
			tempo.acc[b] = 0;
		}
		tempo.fill = 0;
		uint32_t w = atomic_load_explicit(&tempo.written, memory_order_relaxed);
		tempo.env[w % TEMPO_LEN] = onset;
		atomic_store_explicit(&tempo.written, w + 1, memory_order_release);
	}
}

/* OBS calls this with each channel's audio after its filters, before its volume. */
static void on_channel_audio(void *param, obs_source_t *source, const struct audio_data *audio, bool muted)
{
	UNUSED_PARAMETER(source);
	UNUSED_PARAMETER(muted);
	struct ring *r = param;
	const float *l = (const float *)audio->data[0];
	const float *rr = audio->data[1] ? (const float *)audio->data[1] : l;
	uint32_t frames = audio->frames;
	if (!l || !frames)
		return;
	if (r - rings == atomic_load_explicit(&tempo.channel, memory_order_relaxed))
		tempo_feed(l, rr, frames);

	float pl = 0, pr = 0;
	for (uint32_t i = 0; i < frames; i++) {
		pl = fmaxf(pl, fabsf(l[i]));
		pr = fmaxf(pr, fabsf(rr[i]));
	}
	store_peak(&r->peak[0], pl);
	store_peak(&r->peak[1], pr);
	atomic_store_explicit(&r->last, fmaxf(pl, pr), memory_order_relaxed);

	if (!atomic_load_explicit(&r->active, memory_order_acquire))
		return;
	uint64_t w = atomic_load_explicit(&r->write_pos, memory_order_relaxed);
	uint64_t rd = atomic_load_explicit(&r->read_pos, memory_order_acquire);
	if (w - rd + frames > RING_FRAMES)
		return; /* output stalled; drop rather than overwrite what it's reading */
	for (uint32_t i = 0; i < frames; i++) {
		size_t at = (size_t)((w + i) % RING_FRAMES);
		r->buf[0][at] = l[i];
		r->buf[1][at] = rr[i];
	}
	atomic_store_explicit(&r->write_pos, w + frames, memory_order_release);
}

static OSStatus monitor_render(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts, UInt32 bus,
			       UInt32 frames, AudioBufferList *io)
{
	UNUSED_PARAMETER(ref);
	UNUSED_PARAMETER(ts);
	UNUSED_PARAMETER(bus);
	float *out[2] = {io->mBuffers[0].mData, io->mNumberBuffers > 1 ? io->mBuffers[1].mData : NULL};
	for (UInt32 b = 0; b < io->mNumberBuffers; b++)
		memset(io->mBuffers[b].mData, 0, io->mBuffers[b].mDataByteSize);
	bool silent = true;

	for (int c = 0; c < MAX_CH; c++) {
		struct ring *r = &rings[c];
		if (!atomic_load_explicit(&r->active, memory_order_acquire))
			continue;
		uint64_t w = atomic_load_explicit(&r->write_pos, memory_order_acquire);
		uint64_t rd = atomic_load_explicit(&r->read_pos, memory_order_relaxed);
		if (atomic_exchange_explicit(&r->flush, false, memory_order_relaxed)) {
			rd = w;
			r->primed = false;
			r->cur_gain = 0;
		}
		uint64_t avail = w - rd;
		if (!r->primed) {
			if (avail < PRIME_FRAMES) {
				atomic_store_explicit(&r->read_pos, rd, memory_order_release);
				continue;
			}
			r->primed = true;
		}
		if (avail > MAX_FILL) {
			rd = w - TARGET_FRAMES;
			avail = TARGET_FRAMES;
		}
		UInt32 n = avail < frames ? (UInt32)avail : frames;
		float target = atomic_load_explicit(&r->gain, memory_order_relaxed);
		float g = r->cur_gain, step = (target - g) / (float)(n ? n : 1);
		if (g > 0 || target > 0) {
			silent = false;
			for (UInt32 i = 0; i < n; i++, g += step) {
				size_t at = (size_t)((rd + i) % RING_FRAMES);
				out[0][i] += r->buf[0][at] * g;
				if (out[1])
					out[1][i] += r->buf[1][at] * g;
			}
		}
		r->cur_gain = target;
		atomic_store_explicit(&r->read_pos, rd + n, memory_order_release);
		if (n < frames)
			r->primed = false; /* underrun: wait for a little buffer again */
	}
	if (silent)
		*flags |= kAudioUnitRenderAction_OutputIsSilence;
	return noErr;
}

static AudioDeviceID device_for_uid(const char *uid)
{
	CFStringRef s = CFStringCreateWithCString(NULL, uid, kCFStringEncodingUTF8);
	AudioDeviceID dev = kAudioObjectUnknown;
	AudioObjectPropertyAddress a = {kAudioHardwarePropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal,
					kAudioObjectPropertyElementMain};
	UInt32 size = sizeof(dev);
	AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, sizeof(s), &s, &size, &dev);
	CFRelease(s);
	return dev;
}

static void monitor_stop(void)
{
	if (!monitor.unit)
		return;
	AudioOutputUnitStop(monitor.unit);
	AudioUnitUninitialize(monitor.unit);
	AudioComponentInstanceDispose(monitor.unit);
	monitor.unit = NULL;
}

/* "" follows the system default output (the DefaultOutput unit tracks changes by
 * itself); a UID pins one device. */
static void monitor_start(void)
{
	monitor_stop();
	bool follow_default = monitor.uid[0] == 0;
	AudioDeviceID dev = kAudioObjectUnknown;
	if (!follow_default) {
		dev = device_for_uid(monitor.uid);
		if (dev == kAudioObjectUnknown) {
			blog(LOG_WARNING, "[OmniCast] Monitor device %s is gone, using the default output", monitor.uid);
			follow_default = true;
		}
	}

	AudioComponentDescription desc = {
		.componentType = kAudioUnitType_Output,
		.componentSubType = follow_default ? kAudioUnitSubType_DefaultOutput : kAudioUnitSubType_HALOutput,
		.componentManufacturer = kAudioUnitManufacturer_Apple,
	};
	AudioComponent comp = AudioComponentFindNext(NULL, &desc);
	if (!comp || AudioComponentInstanceNew(comp, &monitor.unit) != noErr) {
		monitor.unit = NULL;
		return;
	}
	if (!follow_default)
		AudioUnitSetProperty(monitor.unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
				     &dev, sizeof(dev));

	/* OBS's own format; the output unit converts to the device's rate. */
	AudioStreamBasicDescription fmt = {
		.mSampleRate = 48000,
		.mFormatID = kAudioFormatLinearPCM,
		.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
		.mBytesPerPacket = sizeof(float),
		.mFramesPerPacket = 1,
		.mBytesPerFrame = sizeof(float),
		.mChannelsPerFrame = 2,
		.mBitsPerChannel = 32,
	};
	AURenderCallbackStruct cb = {.inputProc = monitor_render};
	OSStatus st = AudioUnitSetProperty(monitor.unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
					   &fmt, sizeof(fmt));
	if (st == noErr)
		st = AudioUnitSetProperty(monitor.unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input,
					  0, &cb, sizeof(cb));
	if (st == noErr)
		st = AudioUnitInitialize(monitor.unit);
	if (st == noErr)
		st = AudioOutputUnitStart(monitor.unit);
	if (st != noErr) {
		blog(LOG_WARNING, "[OmniCast] Monitor output failed to start (%d)", (int)st);
		monitor_stop();
		return;
	}
	for (int c = 0; c < MAX_CH; c++)
		atomic_store(&rings[c].flush, true);
}

int omni_monitor_devices(omni_audio_device *out, int max)
{
	AudioObjectPropertyAddress a = {kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal,
					kAudioObjectPropertyElementMain};
	UInt32 size = 0;
	if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, NULL, &size) != noErr)
		return 0;
	UInt32 count = size / sizeof(AudioDeviceID);
	AudioDeviceID *ids = calloc(count, sizeof(AudioDeviceID));
	AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, ids);

	int n = 0;
	for (UInt32 i = 0; i < count && n < max; i++) {
		AudioObjectPropertyAddress streams = {kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput,
						      kAudioObjectPropertyElementMain};
		UInt32 ssize = 0;
		if (AudioObjectGetPropertyDataSize(ids[i], &streams, 0, NULL, &ssize) != noErr || ssize == 0)
			continue;
		CFStringRef uid = NULL, name = NULL;
		UInt32 len = sizeof(CFStringRef);
		AudioObjectPropertyAddress pu = {kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal,
						 kAudioObjectPropertyElementMain};
		AudioObjectPropertyAddress pn = {kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal,
						 kAudioObjectPropertyElementMain};
		AudioObjectGetPropertyData(ids[i], &pu, 0, NULL, &len, &uid);
		len = sizeof(CFStringRef);
		AudioObjectGetPropertyData(ids[i], &pn, 0, NULL, &len, &name);
		if (uid && name) {
			CFStringGetCString(uid, out[n].uid, sizeof(out[n].uid), kCFStringEncodingUTF8);
			CFStringGetCString(name, out[n].name, sizeof(out[n].name), kCFStringEncodingUTF8);
			n++;
		}
		if (uid)
			CFRelease(uid);
		if (name)
			CFRelease(name);
	}
	free(ids);
	return n;
}

void omni_monitor_set_device(const char *uid)
{
	if (strcmp(uid, monitor.uid) == 0 && monitor.unit)
		return;
	snprintf(monitor.uid, sizeof(monitor.uid), "%s", uid);
	monitor_start();
}

/* ------------------------------------------------------------------------- */
/* Process taps
 *
 * All tap bookkeeping happens on tap_queue. A tap is rebuilt whenever the set of
 * processes it covers changes, e.g. when an app starts its audio helper. */

#define MAX_PROCS 64

struct tap {
	obs_source_t *source;
	char bundle[256]; /* "" for the system tap */
	bool system;
	AudioObjectID procs[MAX_PROCS];
	size_t nprocs;
	bool built;
	AudioObjectID tap_id;
	AudioObjectID agg_id;
	AudioDeviceIOProcID io;
	AudioStreamBasicDescription fmt;
};

static dispatch_queue_t tap_queue;
static struct tap *taps[MAX_CH + 1];
static bool listening;

bool omni_audio_taps_supported(void)
{
	if (@available(macOS 14.2, *))
		return true;
	return false;
}

bool omni_mixer_apps_supported(void)
{
	return omni_audio_taps_supported();
}

static NSString *process_bundle(AudioObjectID p)
{
	AudioObjectPropertyAddress a = {kAudioProcessPropertyBundleID, kAudioObjectPropertyScopeGlobal,
					kAudioObjectPropertyElementMain};
	CFStringRef s = NULL;
	UInt32 size = sizeof(s);
	if (AudioObjectGetPropertyData(p, &a, 0, NULL, &size, &s) != noErr || !s)
		return nil;
	return CFBridgingRelease(s);
}

static pid_t process_pid(AudioObjectID p)
{
	AudioObjectPropertyAddress a = {kAudioProcessPropertyPID, kAudioObjectPropertyScopeGlobal,
					kAudioObjectPropertyElementMain};
	pid_t pid = -1;
	UInt32 size = sizeof(pid);
	AudioObjectGetPropertyData(p, &a, 0, NULL, &size, &pid);
	return pid;
}

/* An app's audio often plays from a helper: com.google.Chrome.helper, Discord's
 * and Spotify's helpers and so on share the app's bundle ID as a prefix. A few
 * browsers play from a process with an unrelated ID. */
static bool bundle_matches(NSString *proc, NSString *app)
{
	if (!proc)
		return false;
	if ([proc isEqualToString:app] || [proc hasPrefix:[app stringByAppendingString:@"."]])
		return true;
	if ([app isEqualToString:@"com.apple.Safari"])
		return [proc hasPrefix:@"com.apple.WebKit"];
	if ([app isEqualToString:@"org.mozilla.firefox"])
		return [proc isEqualToString:@"org.mozilla.plugincontainer"];
	return false;
}

static void tap_teardown(struct tap *t)
{
	if (!t->built)
		return;
	AudioDeviceStop(t->agg_id, t->io);
	AudioDeviceDestroyIOProcID(t->agg_id, t->io);
	AudioHardwareDestroyAggregateDevice(t->agg_id);
	if (@available(macOS 14.2, *))
		AudioHardwareDestroyProcessTap(t->tap_id);
	t->built = false;
	t->nprocs = 0;
}

static void tap_output(struct tap *t, const AudioBufferList *in, const AudioTimeStamp *when)
{
	if (!in || in->mNumberBuffers == 0)
		return;
	uint32_t ch = t->fmt.mChannelsPerFrame ? t->fmt.mChannelsPerFrame : 2;
	bool planar = t->fmt.mFormatFlags & kAudioFormatFlagIsNonInterleaved;
	/* The tap is the aggregate device's last input stream. */
	struct obs_source_audio a = {
		.speakers = ch == 1 ? SPEAKERS_MONO : SPEAKERS_STEREO,
		.format = planar ? AUDIO_FORMAT_FLOAT_PLANAR : AUDIO_FORMAT_FLOAT,
		.samples_per_sec = (uint32_t)t->fmt.mSampleRate,
		.timestamp = (when->mFlags & kAudioTimeStampHostTimeValid) ? host_to_ns(when->mHostTime)
									     : os_gettime_ns(),
	};
	if (planar) {
		if (in->mNumberBuffers < ch)
			return;
		for (uint32_t c = 0; c < ch && c < 2; c++)
			a.data[c] = in->mBuffers[in->mNumberBuffers - ch + c].mData;
		a.frames = in->mBuffers[in->mNumberBuffers - 1].mDataByteSize / sizeof(float);
	} else {
		const AudioBuffer *b = &in->mBuffers[in->mNumberBuffers - 1];
		if (b->mNumberChannels != ch)
			return;
		a.data[0] = b->mData;
		a.frames = b->mDataByteSize / (sizeof(float) * ch);
	}
	if (a.frames && a.data[0])
		obs_source_output_audio(t->source, &a);
}

API_AVAILABLE(macos(14.2))
static void tap_build(struct tap *t, const AudioObjectID *procs, size_t n)
{
	tap_teardown(t);
	if (!t->system && n == 0)
		return; /* the app isn't playing anything yet */

	NSMutableArray<NSNumber *> *list = [NSMutableArray arrayWithCapacity:n];
	for (size_t i = 0; i < n; i++)
		[list addObject:@(procs[i])];
	CATapDescription *d = t->system ? [[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:list]
					: [[CATapDescription alloc] initStereoMixdownOfProcesses:list];
	d.name = t->system ? @"OmniCast System" : [NSString stringWithFormat:@"OmniCast %s", t->bundle];
	d.privateTap = YES;
	d.muteBehavior = CATapMutedWhenTapped;

	OSStatus st = AudioHardwareCreateProcessTap(d, &t->tap_id);
	if (st != noErr) {
		blog(LOG_WARNING, "[OmniCast] Process tap for %s failed (%d)", t->system ? "system" : t->bundle,
		     (int)st);
		return;
	}
	AudioObjectPropertyAddress fa = {kAudioTapPropertyFormat, kAudioObjectPropertyScopeGlobal,
					 kAudioObjectPropertyElementMain};
	UInt32 size = sizeof(t->fmt);
	AudioObjectGetPropertyData(t->tap_id, &fa, 0, NULL, &size, &t->fmt);

	NSDictionary *agg = @{
		@kAudioAggregateDeviceNameKey: d.name,
		@kAudioAggregateDeviceUIDKey: [NSUUID UUID].UUIDString,
		@kAudioAggregateDeviceIsPrivateKey: @YES,
		@kAudioAggregateDeviceIsStackedKey: @NO,
		@kAudioAggregateDeviceTapAutoStartKey: @YES,
		@kAudioAggregateDeviceTapListKey: @[@{
			@kAudioSubTapUIDKey: d.UUID.UUIDString,
			@kAudioSubTapDriftCompensationKey: @YES,
		}],
	};
	st = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)agg, &t->agg_id);
	if (st != noErr) {
		AudioHardwareDestroyProcessTap(t->tap_id);
		blog(LOG_WARNING, "[OmniCast] Tap device for %s failed (%d)", t->system ? "system" : t->bundle,
		     (int)st);
		return;
	}
	st = AudioDeviceCreateIOProcIDWithBlock(&t->io, t->agg_id, NULL,
						^(const AudioTimeStamp *now, const AudioBufferList *in,
						  const AudioTimeStamp *in_time, AudioBufferList *out,
						  const AudioTimeStamp *out_time) {
							UNUSED_PARAMETER(now);
							UNUSED_PARAMETER(out);
							UNUSED_PARAMETER(out_time);
							tap_output(t, in, in_time);
						});
	if (st == noErr)
		st = AudioDeviceStart(t->agg_id, t->io);
	if (st != noErr) {
		if (t->io)
			AudioDeviceDestroyIOProcID(t->agg_id, t->io);
		AudioHardwareDestroyAggregateDevice(t->agg_id);
		AudioHardwareDestroyProcessTap(t->tap_id);
		blog(LOG_WARNING, "[OmniCast] Tap for %s didn't start (%d)", t->system ? "system" : t->bundle, (int)st);
		return;
	}
	t->built = true;
	memcpy(t->procs, procs, n * sizeof(*procs));
	t->nprocs = n;
	blog(LOG_INFO, "[OmniCast] Tapping %s: %zu process(es), %.0f Hz", t->system ? "system audio" : t->bundle, n,
	     t->fmt.mSampleRate);
}

static int cmp_obj(const void *a, const void *b)
{
	AudioObjectID x = *(const AudioObjectID *)a, y = *(const AudioObjectID *)b;
	return x < y ? -1 : x > y;
}

/* Works out which processes each tap covers and rebuilds the taps whose set changed.
 * App channels claim their processes in channel order; the system tap gets every
 * process nobody claimed, minus OmniCast itself (whose monitor output would
 * otherwise feed back into it). */
static void taps_refresh(void)
{
	if (@available(macOS 14.2, *)) {
		AudioObjectPropertyAddress a = {kAudioHardwarePropertyProcessObjectList,
						kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
		UInt32 size = 0;
		AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, NULL, &size);
		UInt32 count = size / sizeof(AudioObjectID);
		AudioObjectID *all = calloc(count ? count : 1, sizeof(AudioObjectID));
		AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, all);
		count = size / sizeof(AudioObjectID);

		NSMutableArray *bundles = [NSMutableArray arrayWithCapacity:count];
		bool *claimed = calloc(count ? count : 1, sizeof(bool));
		pid_t self_pid = getpid();
		for (UInt32 i = 0; i < count; i++) {
			[bundles addObject:process_bundle(all[i]) ?: [NSNull null]];
			if (process_pid(all[i]) == self_pid)
				claimed[i] = true;
		}

		AudioObjectID want[MAX_PROCS];
		for (int k = 0; k <= MAX_CH; k++) {
			struct tap *t = taps[k];
			if (!t || t->system)
				continue;
			NSString *app = @(t->bundle);
			size_t n = 0;
			for (UInt32 i = 0; i < count && n < MAX_PROCS; i++) {
				id b = bundles[i];
				if (!claimed[i] && b != [NSNull null] && bundle_matches(b, app)) {
					claimed[i] = true;
					want[n++] = all[i];
				}
			}
			qsort(want, n, sizeof(*want), cmp_obj);
			if (n != t->nprocs || memcmp(want, t->procs, n * sizeof(*want)) != 0 || (n && !t->built))
				tap_build(t, want, n);
		}

		for (int k = 0; k <= MAX_CH; k++) {
			struct tap *t = taps[k];
			if (!t || !t->system)
				continue;
			size_t n = 0;
			for (UInt32 i = 0; i < count && n < MAX_PROCS; i++)
				if (claimed[i])
					want[n++] = all[i];
			qsort(want, n, sizeof(*want), cmp_obj);
			if (!t->built || n != t->nprocs || memcmp(want, t->procs, n * sizeof(*want)) != 0)
				tap_build(t, want, n);
		}
		free(claimed);
		free(all);
	}
}

static void taps_listen(void)
{
	if (listening)
		return;
	listening = true;
	AudioObjectPropertyAddress a = {kAudioHardwarePropertyProcessObjectList, kAudioObjectPropertyScopeGlobal,
					kAudioObjectPropertyElementMain};
	AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &a, tap_queue,
					    ^(UInt32 n, const AudioObjectPropertyAddress *addrs) {
						    UNUSED_PARAMETER(n);
						    UNUSED_PARAMETER(addrs);
						    taps_refresh();
					    });
}

static const char *app_audio_name(void *unused)
{
	UNUSED_PARAMETER(unused);
	return "App Audio";
}

static void *app_audio_create(obs_data_t *settings, obs_source_t *source)
{
	struct tap *t = bzalloc(sizeof(*t));
	t->source = source;
	t->system = obs_data_get_bool(settings, "system");
	snprintf(t->bundle, sizeof(t->bundle), "%s", obs_data_get_string(settings, "bundle_id"));
	dispatch_async(tap_queue, ^{
		for (int k = 0; k <= MAX_CH; k++) {
			if (!taps[k]) {
				taps[k] = t;
				break;
			}
		}
		taps_listen();
		taps_refresh();
	});
	return t;
}

static void app_audio_destroy(void *data)
{
	struct tap *t = data;
	dispatch_sync(tap_queue, ^{
		tap_teardown(t);
		for (int k = 0; k <= MAX_CH; k++)
			if (taps[k] == t)
				taps[k] = NULL;
		/* The system tap stops excluding this app's processes. */
		taps_refresh();
	});
	bfree(t);
}

obs_source_t *omni_audio_create_system_source(const char *name)
{
	obs_data_t *s = obs_data_create();
	obs_data_set_bool(s, "system", true);
	obs_source_t *src = obs_source_create("omni_app_audio", name, s, NULL);
	obs_data_release(s);
	return src;
}

/* ------------------------------------------------------------------------- */
/* Mic input select: copies the chosen input of a two-input interface to both sides. */

static _Atomic int mic_input = OMNI_MIC_INPUT_1;

static const char *mic_input_name(void *unused)
{
	UNUSED_PARAMETER(unused);
	return "Mic Input";
}

static void *mic_input_create(obs_data_t *settings, obs_source_t *source)
{
	UNUSED_PARAMETER(settings);
	return source;
}

static void mic_input_destroy(void *data)
{
	UNUSED_PARAMETER(data);
}

static struct obs_audio_data *mic_input_filter(void *data, struct obs_audio_data *audio)
{
	UNUSED_PARAMETER(data);
	int input = atomic_load_explicit(&mic_input, memory_order_relaxed);
	float *l = (float *)audio->data[0], *r = (float *)audio->data[1];
	if (!l || !r || input == OMNI_MIC_STEREO)
		return audio;
	if (input == OMNI_MIC_INPUT_1)
		memcpy(r, l, audio->frames * sizeof(float));
	else
		memcpy(l, r, audio->frames * sizeof(float));
	return audio;
}

void omni_mic_set_input(omni_mic_input input)
{
	atomic_store(&mic_input, (int)input);
}

/* ------------------------------------------------------------------------- */
/* Audio Unit host */

#define AU_MAX_FRAMES 4096

/* Not a mic plugin: runs on the music channel and publishes its key to Muze. */
#define PLUGIN_AUTO_KEY OMNI_PLUGIN_COUNT

static const struct {
	const char *name;
	OSType type, subtype, manufacturer;
} plugin_ids[OMNI_PLUGIN_COUNT + 1] = {
	[OMNI_PLUGIN_STACKS] = {"STACKS", 'aufx', 'Aio1', 'Shnc'},
	[OMNI_PLUGIN_MUZE] = {"Muze", 'aumf', 'Vx02', 'Voxo'},
	[PLUGIN_AUTO_KEY] = {"Muze Auto Key", 'aufx', 'Mzak', 'Voxo'},
};

/* Tempo given to plugins as the host's (Muze's synced harmony, delay, LFOs). */
static _Atomic double host_tempo = 120.0;

struct au_host {
	omni_plugin which;
	_Atomic int refs; /* the filter, plus the load while it's pending */
	_Atomic bool ready;
	bool show_when_ready;
	bool warned; /* render failure logged once */
	void *au;     /* AUAudioUnit, retained */
	void *render; /* AURenderBlock, retained */
	void *pull;   /* AURenderPullInputBlock, retained */
	void *window; /* NSWindow, retained, main thread only */
	AudioBufferList *out;
	/* Input for the pull block, set before each render. */
	float *in[2];
	uint32_t in_offset;
	double sample_time;
	double beats; /* host beat position, advanced at host_tempo */
	float out_buf[2][AU_MAX_FRAMES];
};

static char state_dir[1024];
static obs_source_t *mic_source;
static obs_source_t *mic_input_source;
static obs_source_t *plugin_filters[OMNI_PLUGIN_COUNT];

static NSString *state_path(omni_plugin p)
{
	return [NSString stringWithFormat:@"%s/%s.plist", state_dir, plugin_ids[p].name];
}

static void au_host_release(struct au_host *h)
{
	if (atomic_fetch_sub(&h->refs, 1) != 1)
		return;
	/* Disposing an Audio Unit tears down its UI too (Muze's is WebKit), which
	 * must happen on the main thread. libobs destroys filters on its own task
	 * thread; AudioToolbox then tries to hop to the main thread, times out while
	 * the main thread waits on that same destruction (at quit), disposes here
	 * anyway, and WebKit crashes. So the last release always goes to the main
	 * queue. Nothing renders through h any more, so h itself can go now. */
	void *au = h->au, *render = h->render, *pull = h->pull;
	free(h->out);
	bfree(h);
	dispatch_async(dispatch_get_main_queue(), ^{
		AUAudioUnit *unit = CFBridgingRelease(au);
		[unit deallocateRenderResources];
		if (render)
			CFRelease(render);
		if (pull)
			CFRelease(pull);
	});
}

static void au_save_state(struct au_host *h)
{
	if (!atomic_load(&h->ready))
		return;
	AUAudioUnit *au = (__bridge AUAudioUnit *)h->au;
	NSDictionary *state = au.fullState;
	if (!state)
		return;
	NSData *data = [NSPropertyListSerialization dataWithPropertyList:state
								  format:NSPropertyListBinaryFormat_v1_0
								 options:0
								   error:nil];
	[data writeToFile:state_path(h->which) atomically:YES];
}

static void au_show_editor(struct au_host *h)
{
	if (h->window) {
		NSWindow *w = (__bridge NSWindow *)h->window;
		[w makeKeyAndOrderFront:nil];
		[NSApp activateIgnoringOtherApps:YES];
		return;
	}
	AUAudioUnit *au = (__bridge AUAudioUnit *)h->au;
	atomic_fetch_add(&h->refs, 1);
	[au requestViewControllerWithCompletionHandler:^(AUViewControllerBase *vc) {
		dispatch_async(dispatch_get_main_queue(), ^{
			if (vc && !h->window && atomic_load(&h->refs) > 1) {
				NSSize size = vc.preferredContentSize;
				if (size.width < 1 || size.height < 1)
					size = vc.view.frame.size;
				NSWindow *w = [[NSWindow alloc]
					initWithContentRect:NSMakeRect(0, 0, MAX(size.width, 200), MAX(size.height, 100))
						  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
							    NSWindowStyleMaskMiniaturizable
						    backing:NSBackingStoreBuffered
						      defer:NO];
				w.title = @(plugin_ids[h->which].name);
				w.releasedWhenClosed = NO;
				w.contentViewController = vc;
				[w center];
				/* Settings changed in the window are saved when it closes. */
				[[NSNotificationCenter defaultCenter]
					addObserverForName:NSWindowWillCloseNotification
						    object:w
						     queue:NSOperationQueue.mainQueue
						usingBlock:^(NSNotification *note) {
							UNUSED_PARAMETER(note);
							au_save_state(h);
						}];
				h->window = (void *)CFBridgingRetain(w);
				[w makeKeyAndOrderFront:nil];
				[NSApp activateIgnoringOtherApps:YES];
			} else if (!vc) {
				blog(LOG_WARNING, "[OmniCast] %s has no editor window", plugin_ids[h->which].name);
			}
			au_host_release(h);
		});
	}];
}

static void au_close_editor(struct au_host *h)
{
	if (!h->window)
		return;
	NSWindow *w = CFBridgingRelease(h->window);
	h->window = NULL;
	[[NSNotificationCenter defaultCenter] removeObserver:w];
	[w close];
}

/* Runs on the instantiation completion thread. */
static void au_configure(struct au_host *h, AUAudioUnit *au)
{
	const char *name = plugin_ids[h->which].name;
	AVAudioFormat *fmt = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2];
	NSError *err = nil;
	if (au.inputBusses.count < 1 || au.outputBusses.count < 1 || ![au.inputBusses[0] setFormat:fmt error:&err] ||
	    ![au.outputBusses[0] setFormat:fmt error:&err]) {
		blog(LOG_WARNING, "[OmniCast] %s doesn't take 48 kHz stereo: %s", name,
		     err.localizedDescription.UTF8String ?: "no audio bus");
		return;
	}
	au.maximumFramesToRender = AU_MAX_FRAMES;
	/* A bridged v2 Audio Unit's input bus starts disabled: without this its render
	 * never pulls the mic, so effects output silence (Apple's own units return
	 * kAudioUnitErr_NoConnection) and the mic went quiet as soon as one loaded. */
	au.inputBusses[0].enabled = YES;
	au.outputBusses[0].enabled = YES;
	if (h->which == OMNI_PLUGIN_MUZE) {
		/* Play as a host whose transport is running at host_tempo in 4/4, so Muze's
		 * tempo-synced effects follow the music's BPM. Called on the audio thread. */
		au.musicalContextBlock = ^BOOL(double *tempo, double *numerator, NSInteger *denominator, double *beat,
					      NSInteger *offset_to_next_beat, double *downbeat) {
			double bpm = atomic_load_explicit(&host_tempo, memory_order_relaxed);
			if (tempo)
				*tempo = bpm;
			if (numerator)
				*numerator = 4;
			if (denominator)
				*denominator = 4;
			if (beat)
				*beat = h->beats;
			if (offset_to_next_beat)
				*offset_to_next_beat = (NSInteger)((ceil(h->beats) - h->beats) * 60.0 / bpm * 48000.0);
			if (downbeat)
				*downbeat = floor(h->beats / 4) * 4;
			return YES;
		};
		au.transportStateBlock = ^BOOL(AUHostTransportStateFlags *flags, double *sample, double *cycle_start,
					      double *cycle_end) {
			if (flags)
				*flags = AUHostTransportStateMoving;
			if (sample)
				*sample = h->sample_time;
			if (cycle_start)
				*cycle_start = 0;
			if (cycle_end)
				*cycle_end = 0;
			return YES;
		};
	}

	NSData *saved = [NSData dataWithContentsOfFile:state_path(h->which)];
	if (saved) {
		NSDictionary *state = [NSPropertyListSerialization propertyListWithData:saved
										options:NSPropertyListImmutable
										 format:nil
										  error:nil];
		if ([state isKindOfClass:[NSDictionary class]])
			au.fullState = state;
	}
	if (![au allocateRenderResourcesAndReturnError:&err]) {
		blog(LOG_WARNING, "[OmniCast] %s failed to start: %s", name, err.localizedDescription.UTF8String);
		return;
	}

	h->out = calloc(1, offsetof(AudioBufferList, mBuffers) + 2 * sizeof(AudioBuffer));
	AURenderPullInputBlock pull = ^AUAudioUnitStatus(AudioUnitRenderActionFlags *flags,
							 const AudioTimeStamp *ts, AUAudioFrameCount frames,
							 NSInteger bus, AudioBufferList *input) {
		UNUSED_PARAMETER(flags);
		UNUSED_PARAMETER(ts);
		UNUSED_PARAMETER(bus);
		for (UInt32 b = 0; b < input->mNumberBuffers; b++) {
			float *src = h->in[b < 2 ? b : 1] + h->in_offset;
			if (input->mBuffers[b].mData)
				memcpy(input->mBuffers[b].mData, src, frames * sizeof(float));
			else
				input->mBuffers[b].mData = src;
			input->mBuffers[b].mDataByteSize = frames * sizeof(float);
		}
		return noErr;
	};
	h->pull = (void *)CFBridgingRetain(pull);
	h->render = (void *)CFBridgingRetain(au.renderBlock);
	h->au = (void *)CFBridgingRetain(au);
	atomic_store(&h->ready, true);
	blog(LOG_INFO, "[OmniCast] Loaded %s (latency %.1f ms)", name, au.latency * 1000);
}

static const char *au_filter_name(void *unused)
{
	UNUSED_PARAMETER(unused);
	return "Audio Unit";
}

static void *au_filter_create(obs_data_t *settings, obs_source_t *source)
{
	UNUSED_PARAMETER(source);
	struct au_host *h = bzalloc(sizeof(*h));
	h->which = (omni_plugin)obs_data_get_int(settings, "plugin");
	h->show_when_ready = obs_data_get_bool(settings, "show");
	atomic_store(&h->refs, 2);

	AudioComponentDescription desc = {
		.componentType = plugin_ids[h->which].type,
		.componentSubType = plugin_ids[h->which].subtype,
		.componentManufacturer = plugin_ids[h->which].manufacturer,
	};
	/* In-process: no XPC hop per buffer. The load runs off the main thread so a
	 * slow plugin (licence checks and such) can't freeze the window. */
	[AUAudioUnit instantiateWithComponentDescription:desc
						 options:kAudioComponentInstantiation_LoadInProcess
				       completionHandler:^(AUAudioUnit *au, NSError *err) {
					       if (au && atomic_load(&h->refs) > 1)
						       au_configure(h, au);
					       else if (!au)
						       blog(LOG_WARNING, "[OmniCast] Couldn't load %s: %s",
							    plugin_ids[h->which].name,
							    err.localizedDescription.UTF8String);
					       dispatch_async(dispatch_get_main_queue(), ^{
						       if (atomic_load(&h->ready) && h->show_when_ready &&
							   atomic_load(&h->refs) > 1)
							       au_show_editor(h);
						       au_host_release(h);
					       });
				       }];
	return h;
}

static void au_filter_destroy(void *data)
{
	au_host_release(data);
}

static struct obs_audio_data *au_filter_audio(void *data, struct obs_audio_data *audio)
{
	struct au_host *h = data;
	if (!atomic_load_explicit(&h->ready, memory_order_acquire) || !audio->data[0] || !audio->data[1])
		return audio;
	AURenderBlock render = (__bridge AURenderBlock)h->render;
	AURenderPullInputBlock pull = (__bridge AURenderPullInputBlock)h->pull;
	float *planes[2] = {(float *)audio->data[0], (float *)audio->data[1]};
	h->in[0] = planes[0];
	h->in[1] = planes[1];

	for (uint32_t done = 0; done < audio->frames;) {
		uint32_t n = audio->frames - done;
		if (n > AU_MAX_FRAMES)
			n = AU_MAX_FRAMES;
		h->in_offset = done;
		AudioBufferList *out = h->out;
		out->mNumberBuffers = 2;
		for (int c = 0; c < 2; c++) {
			out->mBuffers[c].mNumberChannels = 1;
			out->mBuffers[c].mData = h->out_buf[c];
			out->mBuffers[c].mDataByteSize = n * sizeof(float);
		}
		AudioTimeStamp ts = {
			.mSampleTime = h->sample_time,
			.mHostTime = mach_absolute_time(),
			.mFlags = kAudioTimeStampSampleTimeValid | kAudioTimeStampHostTimeValid,
		};
		AudioUnitRenderActionFlags flags = 0;
		AUAudioUnitStatus status = render(&flags, &ts, n, 0, out, pull);
		if (status == noErr) {
			for (int c = 0; c < 2; c++) {
				const float *src = out->mBuffers[c < (int)out->mNumberBuffers ? c : 0].mData;
				if (src && src != planes[c] + done)
					memcpy(planes[c] + done, src, n * sizeof(float));
			}
		} else if (!h->warned) {
			/* The mic passes through untouched rather than going silent. */
			h->warned = true;
			blog(LOG_WARNING, "[OmniCast] %s render failed (%d); passing the mic through",
			     plugin_ids[h->which].name, (int)status);
		}
		h->sample_time += n;
		h->beats += n / 48000.0 * atomic_load_explicit(&host_tempo, memory_order_relaxed) / 60.0;
		done += n;
	}
	return audio;
}

static void attach_mic_filters(void)
{
	if (!mic_source)
		return;
	for (int p = 0; p < OMNI_PLUGIN_COUNT; p++)
		if (plugin_filters[p])
			obs_source_filter_remove(mic_source, plugin_filters[p]);
	/* OBS runs filters in the order they were added. */
	for (int p = 0; p < OMNI_PLUGIN_COUNT; p++)
		if (plugin_filters[p])
			obs_source_filter_add(mic_source, plugin_filters[p]);
}

bool omni_plugin_installed(omni_plugin p)
{
	AudioComponentDescription desc = {
		.componentType = plugin_ids[p].type,
		.componentSubType = plugin_ids[p].subtype,
		.componentManufacturer = plugin_ids[p].manufacturer,
	};
	return AudioComponentFindNext(NULL, &desc) != NULL;
}

static void unload_plugin(omni_plugin p)
{
	obs_source_t *f = plugin_filters[p];
	if (!f)
		return;
	struct au_host *h = obs_obj_get_data(f);
	au_close_editor(h);
	au_save_state(h);
	obs_source_filter_remove(mic_source, f);
	plugin_filters[p] = NULL;
	obs_source_release(f);
}

static void load_plugin(omni_plugin p, bool show)
{
	if (plugin_filters[p] || !mic_source || !omni_plugin_installed(p))
		return;
	obs_data_t *s = obs_data_create();
	obs_data_set_int(s, "plugin", p);
	obs_data_set_bool(s, "show", show);
	plugin_filters[p] = obs_source_create_private("omni_au_filter", plugin_ids[p].name, s);
	obs_data_release(s);
	attach_mic_filters();
}

void omni_plugin_set_enabled(omni_plugin p, bool enabled)
{
	if (p < 0 || p >= OMNI_PLUGIN_COUNT)
		return;
	if (enabled)
		load_plugin(p, false);
	else
		unload_plugin(p);
}

void omni_plugin_show_editor(omni_plugin p)
{
	if (p < 0 || p >= OMNI_PLUGIN_COUNT)
		return;
	if (!plugin_filters[p]) {
		load_plugin(p, true);
		return;
	}
	struct au_host *h = obs_obj_get_data(plugin_filters[p]);
	if (atomic_load(&h->ready))
		au_show_editor(h);
	else
		h->show_when_ready = true;
}

/* ------------------------------------------------------------------------- */
/* Channels */

static obs_source_t *channels[MAX_CH];
static bool channel_owned[MAX_CH];
/* Muze Auto Key, on the channel music follow is listening to. */
static obs_source_t *key_filter;
static obs_source_t *key_target;

static void attach_channel(int c, obs_source_t *src)
{
	struct ring *r = &rings[c];
	atomic_store(&r->peak[0], 0.0f);
	atomic_store(&r->peak[1], 0.0f);
	atomic_store(&r->flush, true);
	atomic_store_explicit(&r->active, true, memory_order_release);
	channels[c] = src;
	obs_source_add_audio_capture_callback(src, on_channel_audio, r);
}

static void detach_channel(int c)
{
	if (!channels[c])
		return;
	obs_source_remove_audio_capture_callback(channels[c], on_channel_audio, &rings[c]);
	atomic_store_explicit(&rings[c].active, false, memory_order_release);
	channels[c] = NULL;
}

int omni_mixer_add_app(const char *bundle_id)
{
	if (!omni_audio_taps_supported() || !bundle_id || !*bundle_id)
		return -1;
	for (int c = OMNI_CHANNEL_SYSTEM + 1; c < MAX_CH; c++) {
		if (channels[c])
			continue;
		obs_data_t *s = obs_data_create();
		obs_data_set_string(s, "bundle_id", bundle_id);
		obs_source_t *src = obs_source_create("omni_app_audio", bundle_id, s, NULL);
		obs_data_release(s);
		if (!src)
			return -1;
		/* Mix 1 is the stream; mix 2 is the recording's desktop-audio track. */
		obs_source_set_audio_mixers(src, (1 << 0) | (1 << 1));
		obs_set_output_source(APP_OUTPUT_BASE + c, src);
		channel_owned[c] = true;
		attach_channel(c, src);
		return c;
	}
	return -1;
}

void omni_mixer_remove_app(int c)
{
	if (c <= OMNI_CHANNEL_SYSTEM || c >= MAX_CH || !channels[c] || !channel_owned[c])
		return;
	if (key_target == channels[c] || atomic_load(&tempo.channel) == c)
		omni_music_follow(-1);
	obs_source_t *src = channels[c];
	detach_channel(c);
	obs_set_output_source(APP_OUTPUT_BASE + c, NULL);
	channel_owned[c] = false;
	obs_source_release(src);
}

int omni_audio_attach_source(obs_source_t *src)
{
	if (!src)
		return -1;
	for (int c = OMNI_CHANNEL_SYSTEM + 1; c < MAX_CH; c++) {
		if (channels[c] == src)
			return c;
	}
	for (int c = OMNI_CHANNEL_SYSTEM + 1; c < MAX_CH; c++) {
		if (channels[c])
			continue;
		/* Not owned: omni_audio_stop detaches it, the caller releases it. */
		attach_channel(c, src);
		return c;
	}
	return -1;
}

void omni_audio_detach_source(int c)
{
	if (c <= OMNI_CHANNEL_SYSTEM || c >= MAX_CH || channel_owned[c])
		return;
	detach_channel(c);
}

void omni_music_follow(int c)
{
	if (key_filter && key_target)
		obs_source_filter_remove(key_target, key_filter);
	obs_source_release(key_filter);
	key_filter = NULL;
	key_target = NULL;
	atomic_store(&tempo.channel, -1);
	if (c <= OMNI_CHANNEL_SYSTEM || c >= MAX_CH || !channels[c])
		return;
	if (omni_music_auto_key_installed()) {
		obs_data_t *s = obs_data_create();
		obs_data_set_int(s, "plugin", PLUGIN_AUTO_KEY);
		key_filter = obs_source_create_private("omni_au_filter", "Muze Auto Key", s);
		obs_data_release(s);
		if (key_filter) {
			key_target = channels[c];
			obs_source_filter_add(key_target, key_filter);
		}
	}
	omni_music_tempo_reset();
	atomic_store(&tempo.channel, c);
}

bool omni_music_auto_key_installed(void)
{
	AudioComponentDescription desc = {
		.componentType = plugin_ids[PLUGIN_AUTO_KEY].type,
		.componentSubType = plugin_ids[PLUGIN_AUTO_KEY].subtype,
		.componentManufacturer = plugin_ids[PLUGIN_AUTO_KEY].manufacturer,
	};
	return AudioComponentFindNext(NULL, &desc) != NULL;
}

void omni_music_tempo_reset(void)
{
	atomic_store_explicit(&tempo.reset, true, memory_order_release);
}

/* Beat period by autocorrelation of the onset envelope, 60-190 BPM, scored as a
 * comb over the period's multiples, with a gentle preference around 120 so
 * half/double tempo don't win on a near tie. Checked against 90/100/128/140 BPM
 * drums, 91/96 BPM dembow and a ~155 BPM song. */
double omni_music_tempo(double *confidence)
{
	*confidence = 0;
	uint32_t written = atomic_load_explicit(&tempo.written, memory_order_acquire);
	int n = written < TEMPO_LEN ? (int)written : TEMPO_LEN;
	if (n < 600) /* ~3 s */
		return 0;
	static float e[TEMPO_LEN];
	double mean = 0;
	for (int i = 0; i < n; i++) {
		e[i] = tempo.env[(written - (uint32_t)n + (uint32_t)i) % TEMPO_LEN];
		mean += e[i];
	}
	mean /= n;
	/* Smooth over +-2 hops: a beat period that isn't a whole number of hops would
	 * otherwise half-miss its own onsets and lose to a longer period that is
	 * (a ~155 BPM song read as 77.6 without this). */
	static float smooth[TEMPO_LEN];
	static const float kernel[5] = {1, 2, 3, 2, 1};
	for (int i = 0; i < n; i++) {
		float acc = 0, weight = 0;
		for (int j = -2; j <= 2; j++) {
			if (i + j >= 0 && i + j < n) {
				acc += kernel[j + 2] * e[i + j];
				weight += kernel[j + 2];
			}
		}
		smooth[i] = acc / weight;
	}
	memcpy(e, smooth, sizeof(float) * (size_t)n);
	double energy = 0;
	for (int i = 0; i < n; i++) {
		e[i] -= (float)mean;
		energy += e[i] * e[i];
	}
	if (energy < 1e-6)
		return 0;

	const double rate = 48000.0 / TEMPO_HOP;
	int lo = (int)floor(rate * 60 / 190), hi = (int)ceil(rate * 60 / 60);
	static double ac[1024];
	int max_lag = n / 2 < 1024 ? n / 2 : 1023;
	for (int lag = lo; lag <= max_lag; lag++) {
		double sum = 0;
		for (int i = lag; i < n; i++)
			sum += e[i] * e[i - lag];
		ac[lag] = sum / (n - lag);
	}
	int best = 0;
	double best_score = 0, total = 0;
	int count = 0;
	for (int lag = lo; lag <= hi && lag < n / 2; lag++) {
		double bpm = rate * 60 / lag;
		double octave = log2(bpm / 120.0);
		double prior = exp(-0.5 * octave * octave / 0.8);
		/* Comb: the true beat repeats at 1, 2, 3 and 4 beats; a fake pulse from
		 * syncopation (dembow's off-beat snares read as 4/3 of the tempo, ~121
		 * for a 91 BPM reggaeton song) doesn't line up at the multiples. */
		static const double weight[4] = {1.0, 0.8, 0.6, 0.5};
		double score = 0, used = 0;
		for (int k = 1; k <= 4 && k * lag <= max_lag; k++) {
			score += weight[k - 1] * ac[k * lag];
			used += weight[k - 1];
		}
		score = score / used * prior;
		total += score;
		count++;
		if (score > best_score) {
			best_score = score;
			best = lag;
		}
	}
	if (!best || best_score <= 0)
		return 0;
	/* Parabolic refinement between neighbouring lags. */
	double lag = best;
	if (best > lo && best < hi) {
		double a = ac[best - 1], b = ac[best], c = ac[best + 1];
		double denom = a - 2 * b + c;
		if (fabs(denom) > 1e-12)
			lag = best + 0.5 * (a - c) / denom;
	}
	*confidence = best_score / (fabs(total / count) + 1e-9);
	return rate * 60 / lag;
}

void omni_music_set_tempo(double bpm)
{
	if (bpm >= 40 && bpm <= 300)
		atomic_store_explicit(&host_tempo, bpm, memory_order_relaxed);
}

bool omni_music_muze_key(char *out, size_t len)
{
	if (!out || !len)
		return false;
	out[0] = 0;
	obs_source_t *f = plugin_filters[OMNI_PLUGIN_MUZE];
	struct au_host *h = f ? obs_obj_get_data(f) : NULL;
	if (!h || !atomic_load(&h->ready))
		return false;
	AUAudioUnit *au = (__bridge AUAudioUnit *)h->au;
	AUParameter *key = nil, *scale = nil;
	for (AUParameter *p in au.parameterTree.allParameters) {
		if ([p.displayName isEqualToString:@"Auto-Tune Key"])
			key = p;
		else if ([p.displayName isEqualToString:@"Auto-Tune Scale"])
			scale = p;
	}
	if (!key || !scale || !key.valueStrings || !scale.valueStrings)
		return false;
	NSUInteger k = (NSUInteger)key.value, sc = (NSUInteger)scale.value;
	if (k >= key.valueStrings.count || sc >= scale.valueStrings.count)
		return false;
	snprintf(out, len, "%s %s", key.valueStrings[k].UTF8String, scale.valueStrings[sc].UTF8String);
	return true;
}

void omni_mixer_levels(int c, float *left_db, float *right_db)
{
	*left_db = *right_db = -INFINITY;
	if (c < 0 || c >= MAX_CH || !channels[c])
		return;
	float l = atomic_exchange_explicit(&rings[c].peak[0], 0.0f, memory_order_relaxed);
	float r = atomic_exchange_explicit(&rings[c].peak[1], 0.0f, memory_order_relaxed);
	*left_db = l > 0 ? 20 * log10f(l) : -INFINITY;
	*right_db = r > 0 ? 20 * log10f(r) : -INFINITY;
}

float omni_mixer_level(int c)
{
	if (c < 0 || c >= MAX_CH || !channels[c])
		return -INFINITY;
	float v = atomic_load_explicit(&rings[c].last, memory_order_relaxed);
	return v > 0 ? 20 * log10f(v) : -INFINITY;
}

void omni_mixer_set_stream(int c, float mul, bool muted)
{
	if (c < 0 || c >= MAX_CH || !channels[c])
		return;
	obs_source_set_volume(channels[c], mul);
	obs_source_set_muted(channels[c], muted);
}

void omni_mixer_set_monitor(int c, float mul, bool muted)
{
	if (c < 0 || c >= MAX_CH)
		return;
	atomic_store_explicit(&rings[c].gain, muted ? 0.0f : mul, memory_order_relaxed);
}

/* ------------------------------------------------------------------------- */
/* Lifetime */

void omni_audio_register(void)
{
	if (!tap_queue)
		tap_queue = dispatch_queue_create("OmniCast taps", DISPATCH_QUEUE_SERIAL);

	struct obs_source_info app = {
		.id = "omni_app_audio",
		.type = OBS_SOURCE_TYPE_INPUT,
		.output_flags = OBS_SOURCE_AUDIO | OBS_SOURCE_DO_NOT_DUPLICATE,
		.get_name = app_audio_name,
		.create = app_audio_create,
		.destroy = app_audio_destroy,
	};
	if (omni_audio_taps_supported())
		obs_register_source(&app);

	struct obs_source_info input = {
		.id = "omni_mic_input",
		.type = OBS_SOURCE_TYPE_FILTER,
		.output_flags = OBS_SOURCE_AUDIO,
		.get_name = mic_input_name,
		.create = mic_input_create,
		.destroy = mic_input_destroy,
		.filter_audio = mic_input_filter,
	};
	obs_register_source(&input);

	struct obs_source_info au = {
		.id = "omni_au_filter",
		.type = OBS_SOURCE_TYPE_FILTER,
		.output_flags = OBS_SOURCE_AUDIO,
		.get_name = au_filter_name,
		.create = au_filter_create,
		.destroy = au_filter_destroy,
		.filter_audio = au_filter_audio,
	};
	obs_register_source(&au);
}

void omni_audio_start(const char *config_dir, obs_source_t *mic, obs_source_t *system)
{
	snprintf(state_dir, sizeof(state_dir), "%s/audio-units", config_dir);
	os_mkdirs(state_dir);

	mic_source = mic;
	if (mic) {
		mic_input_source = obs_source_create_private("omni_mic_input", "Mic Input", NULL);
		obs_source_filter_add(mic, mic_input_source);
		attach_channel(OMNI_CHANNEL_MIC, mic);
	}
	if (system)
		attach_channel(OMNI_CHANNEL_SYSTEM, system);
	monitor_start();
}

void omni_audio_stop(void)
{
	omni_music_follow(-1);
	for (int p = 0; p < OMNI_PLUGIN_COUNT; p++)
		unload_plugin((omni_plugin)p);
	if (mic_input_source) {
		obs_source_filter_remove(mic_source, mic_input_source);
		obs_source_release(mic_input_source);
		mic_input_source = NULL;
	}
	for (int c = MAX_CH - 1; c >= 0; c--) {
		if (channel_owned[c])
			omni_mixer_remove_app(c);
		else
			detach_channel(c);
	}
	mic_source = NULL;
	monitor_stop();
}
