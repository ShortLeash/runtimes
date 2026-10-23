// Checks an installed llama.cpp with its common library, linked only from
// its lib/llama-link.json, the way Short Leash's chat shim links it:
//
//   1. loads a tiny model on the CPU and generates a few tokens;
//   2. renders a chat template with a tool through common_chat_templates_apply,
//      with thinking off;
//   3. parses a tool call in that template's format with common_chat_parse.
//
//   llama_smoke <module dir or -> model.gguf template.jinja
//
// The module directory is where a dynamic-backend build keeps its ggml
// backends; a static build passes "-". Prints "llama-smoke ok" at the end.

#include "chat.h"
#include "common.h"
#include "llama.h"

#include <cstdio>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

// Warnings and errors only: a model load logs every tensor otherwise.
static void quiet(ggml_log_level level, const char * text, void *) {
    if (level >= GGML_LOG_LEVEL_WARN) {
        fputs(text, stderr);
    }
}

static int fail(const char * what) {
    fprintf(stderr, "llama-smoke: %s\n", what);
    return 1;
}

int main(int argc, char ** argv) {
    if (argc != 4) {
        fprintf(stderr, "usage: %s <module dir or -> model.gguf template.jinja\n", argv[0]);
        return 2;
    }
    if (strcmp(argv[1], "-") != 0) {
        ggml_backend_load_all_from_path(argv[1]);
    } else {
        ggml_backend_load_all();
    }
    for (size_t i = 0; i < ggml_backend_dev_count(); i++) {
        ggml_backend_dev_t dev = ggml_backend_dev_get(i);
        fprintf(stderr, "device %s (%s)\n", ggml_backend_dev_name(dev), ggml_backend_dev_description(dev));
    }
    llama_log_set(quiet, nullptr);
    llama_backend_init();

    // 1. Generate on the CPU, with nothing offloaded to a GPU.
    ggml_backend_dev_t cpu[] = { ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU), nullptr };
    if (!cpu[0]) {
        return fail("no CPU backend");
    }
    llama_model_params mp = llama_model_default_params();
    mp.devices = cpu;
    mp.n_gpu_layers = 0;
    llama_model * model = llama_model_load_from_file(argv[2], mp);
    if (!model) {
        return fail("the model didn't load");
    }
    const llama_vocab * vocab = llama_model_get_vocab(model);
    llama_context_params cp = llama_context_default_params();
    cp.n_ctx = 256;
    cp.n_batch = 256;
    cp.offload_kqv = false;
    llama_context * ctx = llama_init_from_model(model, cp);
    if (!ctx) {
        return fail("no context");
    }
    const std::string prompt = "Once upon a time";
    std::vector<llama_token> tokens(64);
    int n = llama_tokenize(vocab, prompt.c_str(), (int) prompt.size(), tokens.data(), (int) tokens.size(), true, false);
    if (n <= 0) {
        return fail("tokenize failed");
    }
    tokens.resize(n);
    llama_sampler * smpl = llama_sampler_chain_init(llama_sampler_chain_default_params());
    llama_sampler_chain_add(smpl, llama_sampler_init_greedy());
    llama_batch batch = llama_batch_get_one(tokens.data(), (int) tokens.size());
    std::string text;
    for (int i = 0; i < 16; i++) {
        if (llama_decode(ctx, batch) != 0) {
            return fail("decode failed");
        }
        llama_token tok = llama_sampler_sample(smpl, ctx, -1);
        if (llama_vocab_is_eog(vocab, tok)) {
            break;
        }
        char piece[64];
        int len = llama_token_to_piece(vocab, tok, piece, sizeof(piece), 0, true);
        if (len > 0) {
            text.append(piece, len);
        }
        static llama_token next;
        next = tok;
        batch = llama_batch_get_one(&next, 1);
    }
    printf("generated: %s\n", text.c_str());
    if (text.empty()) {
        return fail("generated nothing");
    }

    // 2. Render the template with a tool, thinking off.
    std::ifstream in(argv[3]);
    std::stringstream src;
    src << in.rdbuf();
    if (src.str().empty()) {
        return fail("empty template");
    }
    auto tmpls = common_chat_templates_init(model, src.str(), "", "<|im_end|>");
    common_chat_templates_inputs inputs;
    common_chat_msg user;
    user.role = "user";
    user.content = "Show me the logs for shop.test";
    inputs.messages = { user };
    inputs.tools = { { "get_logs", "Recent log lines of a site",
                       R"({"type":"object","properties":{"site":{"type":"string"}},"required":["site"]})" } };
    inputs.enable_thinking = false;
    common_chat_params params = common_chat_templates_apply(tmpls.get(), inputs);
    printf("format: %s\n", common_chat_format_name(params.format));
    if (params.prompt.find("get_logs") == std::string::npos || params.prompt.find("shop.test") == std::string::npos) {
        return fail("the rendered prompt lost the tool or the message");
    }

    // 3. Parse a tool call in the template's own format.
    common_chat_parser_params pp(params);
    pp.parser.load(params.parser);
    const std::string reply =
        "<tool_call>\n<function=get_logs>\n<parameter=site>\nshop.test\n</parameter>\n</function>\n</tool_call>";
    common_chat_msg msg = common_chat_parse(reply, false, pp);
    if (msg.tool_calls.size() != 1 || msg.tool_calls[0].name != "get_logs" ||
        msg.tool_calls[0].arguments.find("shop.test") == std::string::npos) {
        return fail("the tool call didn't parse");
    }
    printf("tool call: %s %s\n", msg.tool_calls[0].name.c_str(), msg.tool_calls[0].arguments.c_str());

    llama_sampler_free(smpl);
    llama_free(ctx);
    llama_model_free(model);
    llama_backend_free();
    printf("llama-smoke ok\n");
    return 0;
}
