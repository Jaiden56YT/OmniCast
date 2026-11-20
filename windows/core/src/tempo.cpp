// Tempo tracking for "Muze follows the music": listens to the followed music
// channel and estimates its BPM, the same algorithm as OmniCast for Mac.
//
// Feed (libobs's audio thread, the channel's capture callback: after its
// filters, before its level): a three-band onset envelope (lows ~150 Hz for
// kick and bass, everything, and highs above ~2 kHz for hats and snare),
// one value per 256 samples (187.5 a second), ~11 s kept.
//
// Estimate (the app, every 2 s): autocorrelation of the smoothed envelope,
// scored with a 4-beat comb (rejects dembow's 4/3 pulse) and a prior centred
// on 120 BPM (breaks half/double ties), searched over 60-190 BPM, with a
// parabolic refinement. Validated on the Mac at 90/100/128/140 BPM drums,
// 91/96 BPM dembow and a ~155 BPM song.
#include "internal.h"

#include <atomic>
#include <cmath>
#include <vector>

namespace oc {

static constexpr int HOP = 256, LEN = 2048;

struct Tracker {
	obs_source_t *source = nullptr; // not owned
	float low = 0, mid = 0;
	double acc[3] = {}, prev[3] = {};
	int fill = 0;
	float env[LEN] = {};
	std::atomic<uint64_t> written{0};
	std::atomic<bool> reset{false};
};

static Tracker tracker;

static void on_audio(void *, obs_source_t *, const struct audio_data *audio, bool)
{
	Tracker &t = tracker;
	if (!audio || !audio->data[0])
		return;
	if (t.reset.exchange(false)) {
		t.fill = 0;
		t.written = 0;
	}
	const float *l = (const float *)audio->data[0];
	const float *r = audio->data[1] ? (const float *)audio->data[1] : l;
	for (uint32_t i = 0; i < audio->frames; i++) {
		float x = 0.5f * (l[i] + r[i]);
		t.low += 0.0194f * (x - t.low);
		t.mid += 0.2300f * (x - t.mid);
		float high = x - t.mid;
		t.acc[0] += (double)t.low * t.low;
		t.acc[1] += (double)x * x;
		t.acc[2] += (double)high * high;
		if (++t.fill < HOP)
			continue;
		t.fill = 0;
		double onset = 0;
		for (int b = 0; b < 3; b++) {
			double v = std::log(t.acc[b] + 1e-7);
			double d = v - t.prev[b];
			if (d > 0)
				onset += d;
			t.prev[b] = v;
			t.acc[b] = 0;
		}
		uint64_t w = t.written.load(std::memory_order_relaxed);
		t.env[w % LEN] = (float)onset;
		t.written.store(w + 1, std::memory_order_release);
	}
}

void tempo_listen(obs_source_t *source)
{
	if (tracker.source)
		obs_source_remove_audio_capture_callback(tracker.source, on_audio, nullptr);
	tracker.source = source;
	tracker.reset = true;
	if (source)
		obs_source_add_audio_capture_callback(source, on_audio, nullptr);
}

} // namespace oc

using namespace oc;

OC_API void oc_music_tempo_reset(void)
{
	tracker.reset = true;
}

// BPM (0 when there isn't enough to go on yet) and how clearly it stands out.
OC_API double oc_music_tempo(double *confidence)
{
	if (confidence)
		*confidence = 0;
	uint64_t written = tracker.written.load(std::memory_order_acquire);
	int n = (int)(written < LEN ? written : LEN);
	if (n < 600) // ~3.2 s
		return 0;
	std::vector<double> raw(n), e(n);
	double mean = 0;
	for (int i = 0; i < n; i++) {
		raw[i] = tracker.env[(written - n + i) % LEN];
		mean += raw[i];
	}
	mean /= n;
	// Smooth [1,2,3,2,1]: fixes periods that aren't a whole number of hops.
	static const double K[5] = {1, 2, 3, 2, 1};
	for (int i = 0; i < n; i++) {
		double s = 0, w = 0;
		for (int k = -2; k <= 2; k++)
			if (i + k >= 0 && i + k < n) {
				s += K[k + 2] * raw[i + k];
				w += K[k + 2];
			}
		e[i] = s / w - mean;
	}
	double energy = 0;
	for (double v : e)
		energy += v * v;
	if (energy < 1e-6)
		return 0;

	const double rate = 48000.0 / HOP;
	const int lo = (int)std::floor(rate * 60 / 190), hi = (int)std::ceil(rate * 60 / 60);
	const int max_lag = n / 2 < 1024 ? n / 2 : 1023;
	std::vector<double> ac(max_lag + 2, 0.0);
	for (int lag = lo; lag <= max_lag; lag++) {
		double s = 0;
		for (int i = lag; i < n; i++)
			s += e[i] * e[i - lag];
		ac[lag] = s / (n - lag);
	}
	static const double W[4] = {1.0, 0.8, 0.6, 0.5};
	int best = 0;
	double best_score = 0, total = 0;
	int count = 0;
	for (int lag = lo; lag <= hi && lag < n / 2; lag++) {
		double bpm = rate * 60 / lag;
		double octave = std::log2(bpm / 120);
		double prior = std::exp(-0.5 * octave * octave / 0.8);
		double score = 0, used = 0;
		for (int k = 1; k <= 4 && k * lag <= max_lag; k++) {
			score += W[k - 1] * ac[k * lag];
			used += W[k - 1];
		}
		if (used <= 0)
			continue;
		score = score / used * prior;
		total += score;
		count++;
		if (score > best_score) {
			best_score = score;
			best = lag;
		}
	}
	if (best <= 0 || best_score <= 0)
		return 0;
	double lag = best;
	if (best > lo && best < hi && best + 1 <= max_lag) {
		double a = ac[best - 1], b = ac[best], c = ac[best + 1];
		double d = a - 2 * b + c;
		if (std::fabs(d) > 1e-12)
			lag = best + 0.5 * (a - c) / d;
	}
	if (confidence)
		*confidence = best_score / (std::fabs(total / count) + 1e-9);
	return rate * 60 / lag;
}
