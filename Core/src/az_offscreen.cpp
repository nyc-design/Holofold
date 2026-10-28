// Offscreen presentation and stereo output for Apple Vision Pro. The Vulkan presenter copies
// each frame into an exported image ring (video_core/offscreen_output.h); the app reads the
// newest one as an MTLTexture. Licensed under GPLv2 or any later version.

#include "az_internal.h"
#include "video_core/offscreen_output.h"

extern "C" void az_set_offscreen_output(bool enabled) {
    VideoCore::Offscreen::Get().requested = enabled;
}

extern "C" bool az_offscreen_acquire(AZOffscreenFrame* out) {
    if (!out) {
        return false;
    }
    const auto frame = VideoCore::Offscreen::Acquire();
    if (frame.slot < 0 || !frame.texture) {
        if (frame.slot >= 0) {
            VideoCore::Offscreen::Release(frame.slot);
        }
        return false;
    }
    out->texture = frame.texture;
    out->slot = frame.slot;
    out->frame = frame.frame;
    out->generation = frame.generation;
    out->width = static_cast<int>(frame.width);
    out->height = static_cast<int>(frame.height);
    return true;
}

extern "C" void az_offscreen_release(int slot) {
    VideoCore::Offscreen::Release(slot);
}

extern "C" void az_set_stereo(bool enabled, int depth_percent) {
    AzIOS::Config::SetStereoOverride(enabled, depth_percent);
}
