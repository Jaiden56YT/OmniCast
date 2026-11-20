// A lock-free stereo float ring: one writer thread, one reader thread.
#pragma once

#include <atomic>
#include <cstddef>
#include <vector>

namespace oc {

class Ring {
public:
	static constexpr size_t CH = 2;

	void reset(size_t frames)
	{
		buf_.assign(frames * CH, 0.0f);
		cap_ = frames;
		w_ = r_ = 0;
	}
	size_t capacity() const { return cap_; }
	size_t available() const { return w_.load(std::memory_order_acquire) - r_.load(std::memory_order_acquire); }

	// Interleaved stereo in. When full, the newest frames are dropped (the
	// reader stalled); nothing already queued is overwritten.
	void push(const float *src, size_t frames)
	{
		size_t w = w_.load(std::memory_order_relaxed), r = r_.load(std::memory_order_acquire);
		if (frames > cap_ - (w - r))
			frames = cap_ - (w - r);
		for (size_t i = 0; i < frames; i++) {
			size_t at = ((w + i) % cap_) * CH;
			buf_[at] = src[i * CH];
			buf_[at + 1] = src[i * CH + 1];
		}
		w_.store(w + frames, std::memory_order_release);
	}

	// Planar (left, right) in; right may be null for mono.
	void push_planar(const float *l, const float *r_in, size_t frames)
	{
		size_t w = w_.load(std::memory_order_relaxed), r = r_.load(std::memory_order_acquire);
		if (frames > cap_ - (w - r))
			frames = cap_ - (w - r);
		for (size_t i = 0; i < frames; i++) {
			size_t at = ((w + i) % cap_) * CH;
			buf_[at] = l[i];
			buf_[at + 1] = r_in ? r_in[i] : l[i];
		}
		w_.store(w + frames, std::memory_order_release);
	}

	size_t pop(float *dst, size_t frames)
	{
		size_t r = r_.load(std::memory_order_relaxed), n = available();
		if (frames > n)
			frames = n;
		for (size_t i = 0; i < frames; i++) {
			size_t at = ((r + i) % cap_) * CH;
			dst[i * CH] = buf_[at];
			dst[i * CH + 1] = buf_[at + 1];
		}
		r_.store(r + frames, std::memory_order_release);
		return frames;
	}

	// Adds frames * gain (ramping from g0 to g1) into dst; returns frames read.
	size_t mix_into(float *dst, size_t frames, float g0, float g1)
	{
		size_t r = r_.load(std::memory_order_relaxed), n = available();
		if (frames > n)
			frames = n;
		float step = frames ? (g1 - g0) / (float)frames : 0;
		for (size_t i = 0; i < frames; i++) {
			size_t at = ((r + i) % cap_) * CH;
			float g = g0 + step * (float)i;
			dst[i * CH] += buf_[at] * g;
			dst[i * CH + 1] += buf_[at + 1] * g;
		}
		r_.store(r + frames, std::memory_order_release);
		return frames;
	}

	void skip(size_t frames) { r_.fetch_add(frames, std::memory_order_acq_rel); }
	void clear() { r_.store(w_.load(std::memory_order_acquire), std::memory_order_release); }

private:
	std::vector<float> buf_;
	size_t cap_ = 0;
	std::atomic<size_t> w_{0}, r_{0};
};

} // namespace oc
