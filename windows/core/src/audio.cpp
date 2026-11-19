// Mixer channels: gain, mute and peak meters.
//
// Meter callbacks run on libobs's audio thread, so they only touch atomics:
// no locks, no allocations. The app reads (and resets) the peaks ~30 times a
// second with oc_audio_levels.
#include "internal.h"

#include <cmath>
#include <limits>

namespace oc {

struct Channel {
	obs_source_t *source = nullptr; // not owned
	obs_volmeter_t *meter = nullptr;
	std::atomic<float> peak[2];
	float gain = 1.0f;
	bool muted = false;
};

static Channel channels[OC_CH_COUNT];
static const float SILENT = -std::numeric_limits<float>::infinity();

static void store_max(std::atomic<float> &a, float v)
{
	float cur = a.load(std::memory_order_relaxed);
	while (v > cur && !a.compare_exchange_weak(cur, v, std::memory_order_relaxed)) {
	}
}

static void on_levels(void *param, const float magnitude[MAX_AUDIO_CHANNELS], const float peak[MAX_AUDIO_CHANNELS],
		      const float input_peak[MAX_AUDIO_CHANNELS])
{
	(void)magnitude;
	(void)input_peak;
	Channel *ch = (Channel *)param;
	store_max(ch->peak[0], peak[0]);
	store_max(ch->peak[1], peak[1]);
}

static void apply(Channel &ch)
{
	if (!ch.source)
		return;
	obs_source_set_volume(ch.source, ch.gain);
	obs_source_set_muted(ch.source, ch.muted);
}

void audio_attach(int channel, obs_source_t *source)
{
	if (channel < 0 || channel >= OC_CH_COUNT)
		return;
	Channel &ch = channels[channel];
	if (ch.meter) {
		obs_volmeter_remove_callback(ch.meter, on_levels, &ch);
		obs_volmeter_destroy(ch.meter);
		ch.meter = nullptr;
	}
	ch.source = source;
	ch.peak[0] = SILENT;
	ch.peak[1] = SILENT;
	if (!source)
		return;
	// Peak meter, before the fader, like the Mac app.
	ch.meter = obs_volmeter_create(OBS_FADER_LOG);
	obs_volmeter_set_peak_meter_type(ch.meter, SAMPLE_PEAK_METER);
	obs_volmeter_attach_source(ch.meter, source);
	obs_volmeter_add_callback(ch.meter, on_levels, &ch);
	apply(ch);
}

void audio_detach_all()
{
	for (int i = 0; i < OC_CH_COUNT; i++)
		audio_attach(i, nullptr);
}

} // namespace oc

using namespace oc;

OC_API void oc_audio_set(int32_t channel, float gain, int32_t muted)
{
	if (channel < 0 || channel >= OC_CH_COUNT)
		return;
	Channel &ch = channels[channel];
	ch.gain = gain < 0 ? 0 : gain;
	ch.muted = muted != 0;
	apply(ch);
}

OC_API void oc_audio_levels(int32_t channel, float *left_db, float *right_db)
{
	float l = SILENT, r = SILENT;
	if (channel >= 0 && channel < OC_CH_COUNT) {
		l = channels[channel].peak[0].exchange(SILENT, std::memory_order_relaxed);
		r = channels[channel].peak[1].exchange(SILENT, std::memory_order_relaxed);
	}
	if (left_db)
		*left_db = l;
	if (right_db)
		*right_db = r;
}

OC_API int32_t oc_audio_present(int32_t channel)
{
	return channel >= 0 && channel < OC_CH_COUNT && channels[channel].source ? 1 : 0;
}
