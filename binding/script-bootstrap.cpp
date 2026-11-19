// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

/*
 ** script-bootstrap.cpp
 **
 ** Loads engine-bundled preload/postload Ruby scripts and cheat
 ** dispatch in a fixed order. See script-bootstrap.h.
 */

#include "script-bootstrap.h"

#include "config.h"
#include "sharedstate.h"
#include "eventthread.h"
#include "app_bridge.h"
#include "binding-util.h"

#include "util/debugwriter.h"
#include "util/sdl-util.h"
#include "util/util.h"
#include "filesystem/filesystem.h"

#include <cassert>
#include <chrono>
#include <cctype>
#include <string>
#include <vector>

extern "C" {
#include <ruby.h>
#if RAPI_FULL <= 187
/* NODE and RUBY_EVENT_RAISE live in node.h on 1.8. */
#include <node.h>
#endif
}

namespace mkxp {
namespace ScriptBootstrap {

static VALUE g_topSelf = Qnil;

void setEvalReceiver(void *self) {
    g_topSelf = (VALUE)self;
    rb_gc_register_address(&g_topSelf);
}

struct EvalArg {
    VALUE string;
    VALUE filename;
};

static VALUE evalHelper(EvalArg *arg) {
    VALUE argv[] = {arg->string, Qnil, arg->filename};
    return rb_funcall2(g_topSelf, rb_intern("eval"), ARRAY_SIZE(argv), argv);
}

void evalRubyString(void *string, void *filename, int *state) {
    EvalArg arg = {(VALUE)string, (VALUE)filename};
    rb_protect((VALUE(*)(VALUE))evalHelper, (VALUE)&arg, state);
}

static void runBundledScript(const char *subdir, const char *name, const char *logTag) {
    mkxp_debugLog(logTag, "script-bootstrap.cpp",
                  (std::string("loading ") + name).c_str());
    try {
        std::string script = mkxp_fs::contentsOfAssetAsString(
            (std::string(subdir) + "/" + name).c_str(), "rb");
        if (script.empty()) {
            mkxp_debugLog(logTag, "script-bootstrap.cpp",
                          (std::string("EMPTY content for ") + name).c_str());
            return;
        }
        VALUE scriptStr = rb_utf8_str_new_cstr(script.c_str());
        VALUE fname = rb_utf8_str_new_cstr(name);
        int state = 0;
        evalRubyString((void *)scriptStr, (void *)fname, &state);
        if (state) {
#if RAPI_FULL > 187
            VALUE exc = rb_errinfo();
#else
            VALUE exc = rb_gv_get("$!");
#endif
            if (exc != Qnil) {
                VALUE excClass = rb_class_name(rb_class_of(exc));
                VALUE excMsg = rb_funcall(exc, rb_intern("message"), 0);
                std::string detail = std::string("FAILED ") + name + ": "
                                   + StringValueCStr(excClass) + ": "
                                   + StringValueCStr(excMsg);
                mkxp_debugLog(logTag, "script-bootstrap.cpp", detail.c_str());
                Debug() << "Error in engine" << subdir << name;
                rb_set_errinfo(Qnil);
            }
        } else {
            mkxp_debugLog(logTag, "script-bootstrap.cpp",
                          (std::string("OK ") + name).c_str());
        }
    } catch (...) {
        mkxp_debugLog(logTag, "script-bootstrap.cpp",
                      (std::string("CXX EXC ") + name).c_str());
        Debug() << "Failed to load engine" << subdir << name;
    }
}

// All Ruby handles below belong to this binding's VM and are accessed under
// its GVL. The host has no Ruby pointers and cannot enter the VM to poll.
static VALUE telemetryProc = Qnil;
static VALUE telemetryThread = Qnil;
static uint64_t telemetryTicket = 0;
static bool telemetryBusy = false;
static bool installingTelemetry = false;
using TelemetryClock = std::chrono::steady_clock;
static TelemetryClock::time_point nextSample;

void clearTelemetryProducer() {
    telemetryProc = telemetryThread = Qnil;
    telemetryTicket = 0;
}

RB_METHOD(registerTelemetry) {
    RB_UNUSED_PARAM;
    if (!installingTelemetry || !telemetryTicket || !rb_block_given_p())
        return Qfalse;
    telemetryProc = rb_block_proc();
    telemetryThread = rb_thread_current();
    return Qtrue;
}

static VALUE installTelemetry(VALUE) {
    VALUE system = rb_const_get(rb_cObject, rb_intern("System"));
    if (!RB_TYPE_P(system, T_MODULE))
        return Qnil;
    static bool rooted = false;
    if (!rooted) {
        rb_gc_register_address(&telemetryProc);
        rb_gc_register_address(&telemetryThread);
        rooted = true;
    }
    _rb_define_module_function(system, "__register_essentials_telemetry", registerTelemetry);
    runBundledScript("Postload", "essentials_telemetry", "TELEMETRY");
    return Qnil;
}

void loadTelemetryProducer() {
    clearTelemetryProducer();
    if (shState->rtData().config.rgssVersion != 1)
        return;
    telemetryTicket = mkxp_telemetryTicket();
    if (!telemetryTicket)
        return;
    VALUE previousError = rb_errinfo();
    int state = 0;
    installingTelemetry = true;
    rb_protect(installTelemetry, Qnil, &state);
    installingTelemetry = false;
    if (state) {
        clearTelemetryProducer();
        rb_set_errinfo(previousError);
    }
}

static VALUE callTelemetry(VALUE proc) {
    static ID call = rb_intern("call");
    return rb_funcall(proc, call, 0);
}

void sampleTelemetry() {
    if (NIL_P(telemetryProc) || telemetryBusy)
        return;
    if (mkxp_telemetryTicket() != telemetryTicket) {
        clearTelemetryProducer();
        return;
    }
    if (TelemetryClock::now() < nextSample || rb_thread_current() != telemetryThread)
        return;

    // Ruby getters may yield or enter Graphics.update themselves. Retain
    // the original receiver ticket and stamp completion to avoid bursts.
    telemetryBusy = true;
    const uint64_t ticket = telemetryTicket;
    VALUE previousError = rb_errinfo();
    int state = 0;
    VALUE snapshot = rb_protect(callTelemetry, telemetryProc, &state);
    if (state || snapshot == Qfalse) {
        clearTelemetryProducer();
        if (state)
            rb_set_errinfo(previousError);
    } else if (RB_TYPE_P(snapshot, T_STRING)) {
        mkxp_publishTelemetry(ticket, RSTRING_PTR(snapshot), RSTRING_LEN(snapshot));
    }
    nextSample = TelemetryClock::now() + std::chrono::milliseconds(500);
    telemetryBusy = false;
}

/* --- Raise tracing ---
 * A C event hook feeds MKXPRaiseTrace (scripts/preload/raise_trace.rb).
 * RUBY_EVENT_RAISE is the mechanism behind TracePoint(:raise) and
 * exists on every VM we merge, so 1.8 and 1.9 get the same coverage
 * as 3.1 - including VM-internal raises (a NoMethodError from a typo)
 * that never pass through Kernel#raise. Those are exactly the errors
 * a game's blanket `rescue` hides.
 *
 * A Ruby-level Kernel#raise wrapper would be both narrower (explicit
 * raises only) and invasive (games alias raise themselves), so the
 * hook stays in C and the script only stores and formats. */
static bool g_raiseHookInstalled = false;
static __thread int g_inRaiseHook = 0;

static VALUE recordRaiseBody(VALUE excArg) {
    VALUE mod = rb_const_get(rb_cObject, rb_intern("MKXPRaiseTrace"));
    return rb_funcall(mod, rb_intern("record_exception"), 1, excArg);
}

#if RAPI_FULL <= 187
static void raiseEventHook(rb_event_t, NODE *, VALUE, ID, VALUE)
#else
static void raiseEventHook(rb_event_flag_t, VALUE, VALUE, ID, VALUE)
#endif
{
    /* Recording calls Ruby, which can raise and re-enter the hook. */
    if (g_inRaiseHook)
        return;
    if (!rb_const_defined(rb_cObject, rb_intern("MKXPRaiseTrace")))
        return;

#if RAPI_FULL > 187
    VALUE exc = rb_errinfo();
#else
    VALUE exc = rb_gv_get("$!");
#endif
    if (NIL_P(exc))
        return;

    g_inRaiseHook = 1;
    int state = 0;
    rb_protect(recordRaiseBody, exc, &state);
    /* The game's raise is still in flight. Restore its exception
     * unconditionally so a failed recording cannot swallow or
     * replace what the game is raising. */
    rb_set_errinfo(exc);
    g_inRaiseHook = 0;
}

static void installRaiseHook() {
    /* loadEnginePreloads runs once per game session, but the VM
     * outlives a session on iOS. A second registration would record
     * every raise twice. */
    if (g_raiseHookInstalled)
        return;

#if RAPI_FULL <= 187
    rb_add_event_hook(raiseEventHook, RUBY_EVENT_RAISE);
#else
    rb_add_event_hook(raiseEventHook, RUBY_EVENT_RAISE, Qnil);
#endif
    g_raiseHookInstalled = true;
}

// Expose the host launcher's identity to game scripts (see
// mkxp_setLauncherIdentity in app_bridge.h): `$userAgent` carries the
// name verbatim. `$<name> = true` follows the JoiPlay `$joiplay`
// detection convention and is only defined when the name is a valid
// Ruby identifier.
void setLauncherIdentityGlobals() {
    const std::string identity(mkxp_getLauncherIdentity());
    if (identity.empty())
        return;

    rb_gv_set("$userAgent", rb_utf8_str_new_cstr(identity.c_str()));
    VALUE version = rb_utf8_str_new_cstr(mkxp_getLauncherVersion());
    rb_str_freeze(version);
    rb_gv_set("$userAgentVersion", version);

    bool validIdentifier = std::isalpha((unsigned char)identity[0])
                        || identity[0] == '_';
    for (size_t i = 1; validIdentifier && i < identity.size(); ++i)
        validIdentifier = std::isalnum((unsigned char)identity[i])
                       || identity[i] == '_';
    if (validIdentifier)
        rb_gv_set(("$" + identity).c_str(), Qtrue);
}

void loadRpgModule(int rgssVersion) {
    static const char *const modules[] = {"rpg_xp", "rpg_vx", "rpg_vxace"};
    assert(rgssVersion >= 1 && rgssVersion <= 3);
    runBundledScript("Preload", modules[rgssVersion - 1], "PRELOAD");
}

void loadEnginePreloads() {
    /* Raise tracing records rescued-and-dropped exceptions for the
     * end-of-session RAISETRACE dump (binding-mri.cpp). Load it
     * first so later preloads and all game scripts are covered, and
     * only under debug logs so normal play pays no tracing cost. */
    if (mkxp_debugLogEnabled()) {
        runBundledScript("Preload", "raise_trace", "PRELOAD");
        installRaiseHook();
    }

    const char *enginePreloads[] = {
        "save_repair",
        "windows_fs",
        "platform_compat",
        "pokemon_compat",
        "win32_wrap",
#if RUBY_API_VERSION_MAJOR > 1 || \
    (RUBY_API_VERSION_MAJOR == 1 && RUBY_API_VERSION_MINOR >= 9)
        "win32_wrap_encoding",
#endif
        "mkxp_wrap",
        "http_compat",
        "net_http_compat",
        "script_folder_split",
        nullptr
    };

    for (int p = 0; enginePreloads[p]; ++p)
        runBundledScript("Preload", enginePreloads[p], "PRELOAD");
}

static void runConfigScriptFromDisk(const std::string &filename, bool showDialogOnMissing) {
    std::string scriptData;
    if (!readFileSDL(filename.c_str(), scriptData)) {
        if (showDialogOnMissing)
            shState->eThread().showMessageBox(
                (std::string("Unable to open '") + filename + "'").c_str());
        else
            Debug() << "Unable to open '" << filename << "'";
        return;
    }
    evalRubyString(
        (void *)mkxp_str_new(scriptData.c_str(), scriptData.size()),
        (void *)mkxp_str_new(filename.c_str(), filename.size()),
        nullptr);
}

void runConfigScript(const std::string &path, bool showDialogOnMissing) {
    runConfigScriptFromDisk(path, showDialogOnMissing);
}

void loadConfigPreloadScripts(const Config &conf) {
    for (std::vector<std::string>::const_iterator i = conf.preloadScripts.begin();
         i != conf.preloadScripts.end(); ++i)
    {
        if (shState->rtData().rqTerm)
            break;
        runConfigScriptFromDisk(*i, false);
    }
}

void loadConfigPostloadScripts(const Config &conf) {
    for (std::vector<std::string>::const_iterator i = conf.postloadScripts.begin();
         i != conf.postloadScripts.end(); ++i)
    {
        if (shState->rtData().rqTerm)
            break;
        runConfigScriptFromDisk(*i, true);
    }
}

void loadEnginePostloadsBeforeMain() {
    if (!mkxp_getPostloadEnabled())
        return;

    const char *enginePostloads[] = {
        "bool_coerce_compat",
        "rgss_plugin_stubs",
        "pokemon_input",
        "pokemon_online_stubs",
        "pokemon_tilemap_fix",
        "pokemon_graphics_compat",
        "pokemon_delta_compat",
        "essentials_using_compat",
        "nilclass_safe_stubs",
        "pokemon_windowskin_fix",
        "hmode7_shim",
        "audio_file_name_repair",
        nullptr
    };

    for (int p = 0; enginePostloads[p]; ++p)
        runBundledScript("Postload", enginePostloads[p], "POSTLOAD");
}

void loadCheatPostload() {
    int cheatRgssVer = shState->rtData().config.rgssVersion;
    bool isPE = rb_const_defined(rb_cObject, rb_intern("GameData")) ||
                rb_const_defined(rb_cObject, rb_intern("PBItems"));

    const char *cheatScript = nullptr;
    if (isPE) {
        cheatScript = "cheat_pe19";
    } else if (cheatRgssVer == 1) {
        cheatScript = "cheat_rpgmxp";
    } else if (cheatRgssVer == 2) {
        cheatScript = "cheat_rpgmvx";
    } else if (cheatRgssVer >= 3) {
        cheatScript = "cheat_rpgmvxace";
    }

    if (!cheatScript)
        return;

    runBundledScript("Postload", cheatScript, "POSTLOAD");
}

} // namespace ScriptBootstrap
} // namespace mkxp
