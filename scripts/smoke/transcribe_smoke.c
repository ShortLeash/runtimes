/* Transcribes one 16 kHz mono WAV on the CPU with an installed
 * transcribe.cpp, linked only from its lib/transcribe-link.json, the way the
 * transcribe-cpp-sys crate links it. Prints each device the build registers
 * (so a Vulkan module that loads shows up), then the transcript.
 *
 *   transcribe_smoke <module dir or -> model.gguf audio.wav
 *
 * The module directory is where a dynamic-backend build keeps its ggml
 * backends; a static build passes "-". dr_wav.h comes from transcribe.cpp's
 * examples. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <transcribe.h>

#define DR_WAV_IMPLEMENTATION
#include "dr_wav.h"

int main(int argc, char ** argv) {
    if (argc != 4) {
        fprintf(stderr, "usage: %s <module dir or -> model.gguf audio.wav\n", argv[0]);
        return 2;
    }
    if (strcmp(argv[1], "-") != 0) {
        transcribe_status st = transcribe_init_backends(argv[1]);
        if (st != TRANSCRIBE_OK) {
            fprintf(stderr, "init_backends(%s): %s\n", argv[1], transcribe_status_string(st));
            return 1;
        }
    }
    int n = transcribe_device_count();
    for (int i = 0; i < n; i++) {
        struct transcribe_device_info dev;
        transcribe_device_info_init(&dev);
        if (transcribe_device_get_info(transcribe_device_get(i), &dev) == TRANSCRIBE_OK) {
            fprintf(stderr, "device %s (%s)\n", dev.name, dev.kind);
        }
    }

    unsigned int channels = 0, rate = 0;
    drwav_uint64 frames = 0;
    float * pcm = drwav_open_file_and_read_pcm_frames_f32(argv[3], &channels, &rate, &frames, NULL);
    if (pcm == NULL || channels != 1 || rate != 16000) {
        fprintf(stderr, "%s: need a 16 kHz mono WAV\n", argv[3]);
        return 1;
    }

    struct transcribe_model_load_params load;
    transcribe_model_load_params_init(&load);
    load.backend = TRANSCRIBE_BACKEND_CPU;
    struct transcribe_session * session = NULL;
    transcribe_status st = transcribe_open(argv[2], &load, NULL, &session);
    if (st != TRANSCRIBE_OK) {
        fprintf(stderr, "open %s: %s\n", argv[2], transcribe_status_string(st));
        return 1;
    }
    fprintf(stderr, "backend %s\n", transcribe_model_backend(transcribe_get_model(session)));
    st = transcribe_run(session, pcm, (int) frames, NULL);
    if (st != TRANSCRIBE_OK) {
        fprintf(stderr, "run: %s\n", transcribe_status_string(st));
        return 1;
    }
    printf("%s\n", transcribe_full_text(session));
    transcribe_close(session);
    drwav_free(pcm, NULL);
    return 0;
}
