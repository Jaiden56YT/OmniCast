#pragma once

/* Internal to OmniEngine: the audio mixer behind the omni_mixer_* / omni_monitor_* /
 * omni_plugin_* API in OmniEngine.h. */

#include <obs.h>

/* Registers the app-audio source and the mic filters. Call after the OBS modules load. */
void omni_audio_register(void);

/* Core Audio process taps need macOS 14.2. Without them there are no app channels
 * and system audio falls back to ScreenCaptureKit. */
bool omni_audio_taps_supported(void);

/* System audio from a process tap: everything except OmniCast and the apps that have
 * their own channel. */
obs_source_t *omni_audio_create_system_source(const char *name);

/* Wires the mic and system sources into the mixer and starts the monitor output.
 * Plugin state is kept under config_dir. */
void omni_audio_start(const char *config_dir, obs_source_t *mic, obs_source_t *system);
/* Saves plugin state, unloads the plugins, removes the app channels and stops the
 * monitor. The mic and system sources stay with the caller. */
void omni_audio_stop(void);

/* Gives an existing source (e.g. a capture card) a mixer channel: its stream level
 * is the source's own volume and its audio also goes to the monitor mix. The
 * source stays with the caller. Returns the channel, or -1 when all are taken. */
int omni_audio_attach_source(obs_source_t *src);
/* Takes a channel given by omni_audio_attach_source back out of the mixer. */
void omni_audio_detach_source(int channel);
